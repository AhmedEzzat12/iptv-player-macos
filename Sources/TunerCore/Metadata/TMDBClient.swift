import Foundation

/// The Movie Database (api.themoviedb.org/3), used when the user supplies a key. Accepts a v3 API key
/// (`api_key=` query parameter) or a v4 read-access token (`Authorization: Bearer`).
struct TMDBClient: Sendable {
    static let base = "https://api.themoviedb.org/3"
    static let imageBase = "https://image.tmdb.org/t/p/"
    /// Upper bound on per-season requests for one series.
    static let maxSeasons = 30
    /// Concurrent season requests for one series.
    static let seasonConcurrency = 3

    enum Credential: Sendable, Equatable {
        case apiKey(String)
        case bearer(String)
    }

    let credential: Credential
    /// TMDB language, e.g. "en-US".
    let language: String
    let fetch: MetadataFetch

    init?(key: String?, language: String, fetch: @escaping MetadataFetch) {
        guard let credential = Self.credential(for: key) else { return nil }
        self.credential = credential
        self.language = Self.normalizedLanguage(language)
        self.fetch = fetch
    }

    /// v4 tokens are JWTs ("eyJ…", three dot-separated parts); anything else is sent as a v3 key.
    static func credential(for key: String?) -> Credential? {
        guard let k = key?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty else { return nil }
        if k.hasPrefix("eyJ") || k.split(separator: ".").count == 3 { return .bearer(k) }
        return .apiKey(k)
    }

    /// "en-US" / "en_US" / "zh-Hans-CN" / "fr" → "en-US" / "en-US" / "zh-CN" / "fr"; unusable input → "en-US".
    static func normalizedLanguage(_ s: String) -> String {
        let parts = s.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let first = parts.first, first.count == 2, first.allSatisfy(\.isLetter) else { return "en-US" }
        let lang = first.lowercased()
        if let region = parts.dropFirst().first(where: { $0.count == 2 && $0.allSatisfy(\.isLetter) }) {
            return "\(lang)-\(region.uppercased())"
        }
        return lang
    }

    var lang2: String { String(language.prefix(2)) }

    var headers: [String: String] {
        if case .bearer(let token) = credential { return ["Authorization": "Bearer \(token)"] }
        return [:]
    }

    func url(_ path: String, _ params: [(String, String)]) -> String {
        var items = params
        if case .apiKey(let key) = credential { items.append(("api_key", key)) }
        let query = items.map { "\($0.0)=\($0.1.urlQueryEncoded)" }.joined(separator: "&")
        return query.isEmpty ? Self.base + path : "\(Self.base)\(path)?\(query)"
    }

    func get(_ path: String, _ params: [(String, String)] = []) async throws -> JSONObject {
        try await fetch(url(path, params), headers)
    }

    /// Throws `HTTPError.status(401, …)` for a rejected key.
    func validate() async throws {
        _ = try await get("/configuration")
    }

    // MARK: - Lookup

    /// nil = no acceptable match. Throws on network/auth/server errors.
    func lookup(_ query: TitleMatcher.Query, kind: MediaMetadata.Kind, tmdbId: String? = nil) async throws -> MediaMetadata? {
        if let id = tmdbId?.trimmingCharacters(in: .whitespaces), let n = Int(id), n > 0 {
            do {
                if let md = try await details(id: id, kind: kind) { return md }
            } catch let error where MetadataHTTP.isNotFound(error) {
                // A stale provider id: fall back to searching.
            }
        }
        guard let id = try await searchBestId(query, kind: kind) else { return nil }
        return try await details(id: id, kind: kind)
    }

    struct SearchResult: Sendable {
        var id: String
        var title: String
        var originalTitle: String?
        var date: String?
    }

    /// Searches in the title's own script language (Arabic names → "ar"), the UI language and English, so the
    /// returned localized/original titles can be compared with the IPTV name.
    func searchBestId(_ query: TitleMatcher.Query, kind: MediaMetadata.Kind) async throws -> String? {
        var languages: [String] = []
        for lang in [Self.scriptLanguage(of: query.title), language, "en-US"].compactMap({ $0 })
        where !languages.contains(where: { $0.prefix(2) == lang.prefix(2) }) {
            languages.append(lang)
        }
        for (i, lang) in languages.enumerated() {
            // Full set of attempts in the first language; just the plain title in the others (keeps misses cheap).
            var attempts: [(String, Int?)] = [(query.title, nil)]
            if i == 0, let year = query.year { attempts.append((query.title, year)) }
            if i == 0, let literal = query.literalTitle { attempts.append((literal, query.literalYear)) }
            for (title, year) in attempts {
                let results = try await search(title, year: year, kind: kind, language: lang)
                if let best = Self.bestMatch(query, results, kind: kind) {
                    let match = results[best.index]
                    MetadataService.log.info("TMDB: '\(query.title, privacy: .public)' (\(query.year.map(String.init) ?? "-", privacy: .public)) → \(match.title, privacy: .public) [\(match.id, privacy: .public)] score \(best.score, format: .fixed(precision: 2))")
                    return match.id
                }
            }
        }
        return nil
    }

    func search(_ title: String, year: Int?, kind: MediaMetadata.Kind, language: String) async throws -> [SearchResult] {
        var params = [("query", title), ("include_adult", "false"), ("language", language), ("page", "1")]
        if let year { params.append((kind == .movie ? "year" : "first_air_date_year", String(year))) }
        let json = try await get(kind == .movie ? "/search/movie" : "/search/tv", params)
        return Self.parseSearch(json, kind: kind)
    }

    func details(id: String, kind: MediaMetadata.Kind) async throws -> MediaMetadata? {
        var append = ["credits", "videos", "images", "external_ids"]
        if lang2 != "en" { append.append("translations") }
        let languages = Self.orderedUnique([lang2, "en"]).joined(separator: ",") + ",null"
        let params = [
            ("language", language),
            ("append_to_response", append.joined(separator: ",")),
            ("include_image_language", languages),
            ("include_video_language", languages),
        ]
        switch kind {
        case .movie:
            let json = try await get("/movie/\(id.urlPathEncoded)", params)
            return Self.mapMovie(json, language: language)
        case .series:
            let json = try await get("/tv/\(id.urlPathEncoded)", params)
            let seasons = try await seasons(tvId: id, numbers: Self.seasonNumbers(json))
            return Self.mapSeries(json, seasons: seasons, language: language)
        }
    }

    /// Season documents (episode titles, overviews, stills), a few at a time. Individual failures are
    /// tolerated; if every season fails the error is rethrown so the lookup is retried later.
    func seasons(tvId: String, numbers: [Int]) async throws -> [JSONObject] {
        guard !numbers.isEmpty else { return [] }
        let results = await withTaskGroup(of: (Int, Result<JSONObject, Error>).self) { group in
            var iterator = numbers.makeIterator()
            func add(_ n: Int) {
                group.addTask {
                    do { return (n, .success(try await self.get("/tv/\(tvId.urlPathEncoded)/season/\(n)", [("language", self.language)]))) }
                    catch { return (n, .failure(error)) }
                }
            }
            for _ in 0..<Self.seasonConcurrency {
                if let n = iterator.next() { add(n) }
            }
            var out: [Int: Result<JSONObject, Error>] = [:]
            while let (n, result) = await group.next() {
                out[n] = result
                if let next = iterator.next() { add(next) }
            }
            return out
        }
        let ok = numbers.compactMap { try? results[$0]?.get() }
        if ok.isEmpty, case .failure(let error)? = results[numbers[0]] { throw error }
        return ok
    }

    // MARK: - Mapping (pure; unit-tested with hand-written fixtures)

    static func parseSearch(_ json: JSONObject, kind: MediaMetadata.Kind) -> [SearchResult] {
        json.objects("results").compactMap { r in
            guard let id = r.string("id") else { return nil }
            let title = kind == .movie ? r.string("title") : r.string("name")
            let original = kind == .movie ? r.string("original_title") : r.string("original_name")
            guard let display = title ?? original else { return nil }
            return SearchResult(id: id, title: display, originalTitle: original,
                                date: kind == .movie ? r.string("release_date") : r.string("first_air_date"))
        }
    }

    static func bestMatch(_ query: TitleMatcher.Query, _ results: [SearchResult], kind: MediaMetadata.Kind) -> (index: Int, score: Double)? {
        let candidates = results.map { r in
            TitleMatcher.Candidate(titles: [r.title] + (r.originalTitle.map { [$0] } ?? []),
                                   year: r.date.flatMap(TitleMatcher.parseYear), endYear: nil)
        }
        return TitleMatcher.bestMatch(query, candidates, kind: kind)
    }

    static func mapMovie(_ j: JSONObject, language: String, fetchedAt: Date = Date()) -> MediaMetadata? {
        guard let id = j.string("id"), let title = j.string("title") ?? j.string("original_title") else { return nil }
        let lang2 = String(normalizedLanguage(language).prefix(2))
        var md = MediaMetadata(kind: .movie, source: "TMDB", title: title, fetchedAt: fetchedAt)
        md.tmdbId = id
        md.imdbId = j.object("external_ids")?.string("imdb_id") ?? j.string("imdb_id")
        if let original = j.string("original_title"), original != title { md.originalTitle = original }
        md.releaseDate = MetadataFormat.isoDay(j.string("release_date"))
        md.year = md.releaseDate.map { String($0.prefix(4)) }
        md.overview = j.string("overview") ?? englishTranslation(j, "overview")
        md.tagline = j.string("tagline")
        fillArtwork(&md, j, lang2: lang2)
        md.genres = j.objects("genres").compactMap { $0.string("name") }
        md.runtimeMinutes = j.int("runtime").flatMap { $0 > 0 ? $0 : nil }
        md.rating = (j.int("vote_count") ?? 1) > 0 ? MetadataFormat.rating(j.double("vote_average")) : nil
        md.country = countries(j, language: language)
        let credits = j.object("credits")
        md.cast = cast(credits)
        let crew = credits?.objects("crew") ?? []
        md.directors = uniqueNames(crew.filter { $0.string("job") == "Director" })
        md.writers = Array(uniqueNames(crew.filter { $0.string("department") == "Writing" }).prefix(6))
        md.trailerYouTubeId = trailer(j.object("videos"), lang2: lang2)
        return md
    }

    static func mapSeries(_ j: JSONObject, seasons: [JSONObject], language: String, fetchedAt: Date = Date()) -> MediaMetadata? {
        guard let id = j.string("id"), let title = j.string("name") ?? j.string("original_name") else { return nil }
        let lang2 = String(normalizedLanguage(language).prefix(2))
        var md = MediaMetadata(kind: .series, source: "TMDB", title: title, fetchedAt: fetchedAt)
        md.tmdbId = id
        md.imdbId = j.object("external_ids")?.string("imdb_id")
        if let original = j.string("original_name"), original != title { md.originalTitle = original }
        md.releaseDate = MetadataFormat.isoDay(j.string("first_air_date"))
        if let start = md.releaseDate.map({ String($0.prefix(4)) }) {
            let ended = ["ended", "canceled", "cancelled"].contains(j.string("status")?.lowercased() ?? "")
            if ended, let end = j.string("last_air_date").map({ String($0.prefix(4)) }), end > start {
                md.year = "\(start)–\(end)"
            } else {
                md.year = start
            }
        }
        md.overview = j.string("overview") ?? englishTranslation(j, "overview")
        md.tagline = j.string("tagline")
        fillArtwork(&md, j, lang2: lang2)
        md.genres = j.objects("genres").compactMap { $0.string("name") }
        md.runtimeMinutes = j.array("episode_run_time").compactMap { ($0 as? NSNumber)?.intValue }.first { $0 > 0 }
            ?? j.object("last_episode_to_air")?.int("runtime").flatMap { $0 > 0 ? $0 : nil }
        md.rating = (j.int("vote_count") ?? 1) > 0 ? MetadataFormat.rating(j.double("vote_average")) : nil
        md.country = countries(j, language: language)
        md.cast = cast(j.object("credits"))
        // Like Cinemeta, series credit their creators as writers.
        md.writers = uniqueNames(j.objects("created_by"))
        md.trailerYouTubeId = trailer(j.object("videos"), lang2: lang2)
        md.episodes = episodes(seasons)
        return md
    }

    /// Regular seasons in order, then specials (season 0); empty seasons skipped; capped.
    static func seasonNumbers(_ j: JSONObject) -> [Int] {
        var numbers = j.objects("seasons").compactMap { s -> Int? in
            guard let n = s.int("season_number"), (s.int("episode_count") ?? 1) > 0 else { return nil }
            return n
        }
        if numbers.isEmpty, let count = j.int("number_of_seasons"), count > 0 {
            numbers = Array(1...min(count, maxSeasons))
        }
        let regular = orderedUnique(numbers.filter { $0 > 0 }.sorted())
        return Array((regular + (numbers.contains(0) ? [0] : [])).prefix(maxSeasons))
    }

    static func episodes(_ seasons: [JSONObject]) -> [EpisodeMetadata] {
        var seen = Set<String>()
        var out: [EpisodeMetadata] = []
        for s in seasons {
            for e in s.objects("episodes") {
                guard let season = e.int("season_number") ?? s.int("season_number"), let number = e.int("episode_number"),
                      seen.insert("\(season)x\(number)").inserted else { continue }
                out.append(EpisodeMetadata(
                    season: season,
                    episode: number,
                    title: e.string("name"),
                    overview: e.string("overview"),
                    stillURL: image(e.string("still_path"), "w300"),
                    airDate: MetadataFormat.isoDay(e.string("air_date")),
                    rating: (e.int("vote_count") ?? 1) > 0 ? MetadataFormat.rating(e.double("vote_average")) : nil
                ))
            }
        }
        return out.sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
    }

    static func image(_ path: String?, _ size: String) -> String? {
        guard let path, path.hasPrefix("/") else { return nil }
        return imageBase + size + path
    }

    /// Poster (w500), backdrop (w1280) and title logo (w500, UI language → English → language-neutral).
    static func fillArtwork(_ md: inout MediaMetadata, _ j: JSONObject, lang2: String) {
        let images = j.object("images")
        md.posterURL = image(j.string("poster_path"), "w500")
            ?? pick(images?.objects("posters") ?? [], lang2: lang2, allowNeutral: true).flatMap { image($0, "w500") }
        md.backdropURL = image(j.string("backdrop_path"), "w1280")
            ?? pick((images?.objects("backdrops") ?? []).filter { $0.string("iso_639_1") == nil }, lang2: lang2, allowNeutral: true)
                .flatMap { image($0, "w1280") }
        if var logo = pick(images?.objects("logos") ?? [], lang2: lang2, allowNeutral: true, preferPNG: true) {
            // TMDB serves a PNG rendition of every SVG logo under the same name.
            if logo.lowercased().hasSuffix(".svg") { logo = String(logo.dropLast(4)) + ".png" }
            md.logoURL = image(logo, "w500")
        }
    }

    /// Best image file path by language (UI language, English, then language-neutral), PNG, then votes.
    /// Images in other languages are never picked (a Japanese title logo on an English UI looks wrong).
    static func pick(_ images: [JSONObject], lang2: String, allowNeutral: Bool, preferPNG: Bool = false) -> String? {
        func rank(_ i: JSONObject) -> (Int, Int, Double) {
            let lang = i.string("iso_639_1")
            let langRank = lang == lang2 ? 0 : lang == "en" ? 1 : lang == nil ? 2 : 9
            let pngRank = preferPNG && !(i.string("file_path") ?? "").lowercased().hasSuffix(".png") ? 1 : 0
            return (langRank, pngRank, -(i.double("vote_average") ?? 0))
        }
        return images
            .filter { $0.string("file_path") != nil && rank($0).0 <= (allowNeutral ? 2 : 1) }
            .min { rank($0) < rank($1) }?
            .string("file_path")
    }

    /// YouTube trailer key: trailers before teasers, UI language before English, official first.
    static func trailer(_ videos: JSONObject?, lang2: String) -> String? {
        func rank(_ v: JSONObject) -> (Int, Int, Int) {
            let type = v.string("type")?.lowercased()
            let typeRank = type == "trailer" ? 0 : type == "teaser" ? 1 : 9
            let lang = v.string("iso_639_1")
            let langRank = lang == lang2 ? 0 : lang == "en" ? 1 : 2
            return (typeRank, langRank, v.bool("official") ? 0 : 1)
        }
        return (videos?.objects("results") ?? [])
            .filter { $0.string("site")?.lowercased() == "youtube" && $0.string("key") != nil && rank($0).0 < 9 }
            .min { rank($0) < rank($1) }?
            .string("key")
    }

    static func cast(_ credits: JSONObject?) -> [CastMember] {
        let members = (credits?.objects("cast") ?? []).enumerated()
            .sorted { ($0.element.int("order") ?? Int.max, $0.offset) < ($1.element.int("order") ?? Int.max, $1.offset) }
            .map(\.element)
        return members.prefix(20).compactMap { c in
            guard let name = c.string("name") else { return nil }
            return CastMember(name: name, character: c.string("character"), photoURL: image(c.string("profile_path"), "w185"))
        }
    }

    static func countries(_ j: JSONObject, language: String) -> String? {
        var codes = j.array("origin_country").compactMap { $0 as? String }
        if codes.isEmpty { codes = j.objects("production_countries").compactMap { $0.string("iso_3166_1") } }
        let locale = Locale(identifier: normalizedLanguage(language))
        let names = orderedUnique(codes).prefix(3).map { locale.localizedString(forRegionCode: $0) ?? $0 }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    /// Overview/tagline from the English translation when the UI-language text is missing.
    static func englishTranslation(_ j: JSONObject, _ field: String) -> String? {
        let translations = j.object("translations")?.objects("translations") ?? []
        let english = translations.filter { $0.string("iso_639_1") == "en" }
        let best = english.first { $0.string("iso_3166_1") == "US" } ?? english.first
        return best?.object("data")?.string(field)
    }

    static func uniqueNames(_ people: [JSONObject]) -> [String] {
        orderedUnique(people.compactMap { $0.string("name") })
    }

    static func orderedUnique<T: Hashable>(_ items: [T]) -> [T] {
        var seen = Set<T>()
        return items.filter { seen.insert($0).inserted }
    }

    /// TMDB language for a non-Latin title's script (an Arabic name is best matched against Arabic titles).
    static func scriptLanguage(of title: String) -> String? {
        for scalar in title.unicodeScalars where scalar.properties.isAlphabetic && !scalar.isASCII {
            switch scalar.value {
            case 0x0600...0x06FF, 0x0750...0x077F, 0xFB50...0xFDFF, 0xFE70...0xFEFF: return "ar-SA"
            case 0x0400...0x04FF: return "ru-RU"
            case 0x0590...0x05FF: return "he-IL"
            case 0x0370...0x03FF: return "el-GR"
            case 0x0900...0x097F: return "hi-IN"
            case 0x0E00...0x0E7F: return "th-TH"
            case 0x3040...0x30FF: return "ja-JP"
            case 0xAC00...0xD7AF, 0x1100...0x11FF: return "ko-KR"
            case 0x4E00...0x9FFF: return "zh-CN"
            default: continue
            }
        }
        return nil
    }
}
