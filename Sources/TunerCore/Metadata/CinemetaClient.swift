import Foundation

/// Stremio's public Cinemeta catalogue (IMDb-based, English, no key). Search, then fetch the full meta of
/// the best match. Artwork comes from metahub.space (poster/background/logo by IMDb id).
struct CinemetaClient: Sendable {
    static let base = "https://v3-cinemeta.strem.io"

    let fetch: MetadataFetch

    struct SearchResult: Sendable {
        var id: String
        var name: String
        var releaseInfo: String?
        var poster: String?
        var background: String?
    }

    /// nil = no acceptable match. Throws on network/server errors.
    func lookup(_ query: TitleMatcher.Query, kind: MediaMetadata.Kind) async throws -> MediaMetadata? {
        // Cinemeta only knows (English) IMDb titles: a query without any Latin letters can't match.
        guard Self.isSearchable(query.title) else { return nil }
        var results = try await search(query.title, kind: kind)
        var best = Self.bestMatch(query, results, kind: kind)
        if best == nil, let literal = query.literalTitle {
            results = try await search(literal, kind: kind)
            best = Self.bestMatch(query, results, kind: kind)
        }
        guard let best else { return nil }
        let match = results[best.index]
        MetadataService.log.info("Cinemeta: '\(query.title, privacy: .public)' (\(query.year.map(String.init) ?? "-", privacy: .public)) → \(match.name, privacy: .public) [\(match.id, privacy: .public)] score \(best.score, format: .fixed(precision: 2))")
        guard let meta = try await self.meta(id: match.id, kind: kind), let md = Self.map(meta, kind: kind) else {
            // The search hit is trustworthy even when its full meta is missing: keep title and artwork.
            return Self.map(match, kind: kind)
        }
        // Ids missing from Cinemeta's own catalogue redirect to a live IMDb proxy whose record can differ from
        // the search hit (renamed "Untitled Project", other year): re-check the match against the full meta.
        let years = TitleMatcher.parseYearRange(meta.string("releaseInfo") ?? meta.string("year"))
        let verified = TitleMatcher.Candidate(titles: [md.title], year: years.start, endYear: years.end)
        guard TitleMatcher.score(query, verified, kind: kind) >= TitleMatcher.acceptScore else {
            MetadataService.log.info("Cinemeta: rejected \(match.id, privacy: .public) — meta says '\(md.title, privacy: .public)' (\(md.year ?? "-", privacy: .public))")
            return nil
        }
        return md
    }

    func search(_ title: String, kind: MediaMetadata.Kind) async throws -> [SearchResult] {
        let url = "\(Self.base)/catalog/\(kind.cinemetaType)/top/search=\(title.urlPathEncoded).json"
        return Self.parseSearch(try await fetch(url, [:]))
    }

    func meta(id: String, kind: MediaMetadata.Kind) async throws -> JSONObject? {
        let url = "\(Self.base)/meta/\(kind.cinemetaType)/\(id.urlPathEncoded).json"
        do {
            return try await fetch(url, [:]).object("meta")
        } catch let error where MetadataHTTP.isNotFound(error) {
            return nil
        }
    }

    // MARK: - Parsing (pure; unit-tested with captured responses)

    static func parseSearch(_ json: JSONObject) -> [SearchResult] {
        json.objects("metas").compactMap { m in
            guard let id = m.string("imdb_id") ?? m.string("id"), let name = m.string("name") else { return nil }
            return SearchResult(id: id, name: name, releaseInfo: m.string("releaseInfo") ?? m.string("year"),
                                poster: m.string("poster"), background: m.string("background"))
        }
    }

    /// Minimal metadata from a search hit (when `/meta` has nothing for it).
    static func map(_ result: SearchResult, kind: MediaMetadata.Kind, fetchedAt: Date = Date()) -> MediaMetadata {
        var md = MediaMetadata(kind: kind, source: "Cinemeta", title: result.name, fetchedAt: fetchedAt)
        md.imdbId = result.id.hasPrefix("tt") ? result.id : nil
        md.year = MetadataFormat.displayYear(result.releaseInfo, kind: kind)
        md.posterURL = upgradedPoster(result.poster)
        md.backdropURL = result.background
        return md
    }

    static func bestMatch(_ query: TitleMatcher.Query, _ results: [SearchResult], kind: MediaMetadata.Kind) -> (index: Int, score: Double)? {
        let candidates = results.map { r in
            let years = TitleMatcher.parseYearRange(r.releaseInfo)
            return TitleMatcher.Candidate(titles: [r.name], year: years.start, endYear: years.end)
        }
        return TitleMatcher.bestMatch(query, candidates, kind: kind)
    }

    static func isSearchable(_ title: String) -> Bool {
        let folded = title.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        let letters = folded.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        if letters.isEmpty { return folded.contains(where: \.isNumber) } // "1917", "2012"
        return letters.contains { $0.isASCII }
    }

    static func map(_ m: JSONObject, kind: MediaMetadata.Kind, fetchedAt: Date = Date()) -> MediaMetadata? {
        guard let name = m.string("name") else { return nil }
        var md = MediaMetadata(kind: kind, source: "Cinemeta", title: name, fetchedAt: fetchedAt)
        md.imdbId = [m.string("imdb_id"), m.string("id")].compactMap { $0 }.first { $0.hasPrefix("tt") }
        md.tmdbId = m.string("moviedb_id")
        md.year = MetadataFormat.displayYear(m.string("releaseInfo") ?? m.string("year") ?? m.string("released"), kind: kind)
        md.overview = m.string("description")
        md.posterURL = upgradedPoster(m.string("poster"))
        md.backdropURL = m.string("background")
        md.logoURL = m.string("logo")
        md.genres = m.stringList("genres")
        if md.genres.isEmpty { md.genres = m.stringList("genre") }
        md.runtimeMinutes = MetadataFormat.minutes(m.string("runtime"))
        md.rating = MetadataFormat.rating(m.double("imdbRating"))
        md.releaseDate = MetadataFormat.isoDay(m.string("released"))
        md.country = m.string("country")
        md.cast = m.stringList("cast").map { CastMember(name: $0) }
        md.directors = m.stringList("director")
        md.writers = m.stringList("writer")
        md.trailerYouTubeId = trailer(m)
        if kind == .series { md.episodes = episodes(m) }
        return md
    }

    /// metahub "small" posters are 300×450; "large" (780×1170, ~25 KB webp) stays sharp on Retina detail pages.
    /// Search hits sometimes carry IMDb's Amazon poster at 250 px wide ("…@._V1_SX250.jpg"); ask for 780.
    static func upgradedPoster(_ url: String?) -> String? {
        guard let url else { return nil }
        if url.contains("metahub.space/poster/") {
            return url.replacingOccurrences(of: "/poster/small/", with: "/poster/large/")
                .replacingOccurrences(of: "/poster/medium/", with: "/poster/large/")
        }
        if url.contains("media-amazon.com") {
            return url.replacingOccurrences(of: #"\._V1_[^/]*\.jpg$"#, with: "._V1_SX780.jpg", options: .regularExpression)
        }
        return url
    }

    static func trailer(_ m: JSONObject) -> String? {
        let trailers = m.objects("trailers")
        if let t = trailers.first(where: { $0.string("type")?.lowercased() == "trailer" }) ?? trailers.first,
           let id = t.string("source") {
            return id
        }
        return m.objects("trailerStreams").lazy.compactMap { $0.string("ytId") }.first
    }

    static func episodes(_ m: JSONObject) -> [EpisodeMetadata] {
        var seen = Set<String>()
        var out: [EpisodeMetadata] = []
        for v in m.objects("videos") {
            guard let season = v.int("season"), let number = v.int("episode") ?? v.int("number"),
                  seen.insert("\(season)x\(number)").inserted else { continue }
            out.append(EpisodeMetadata(
                season: season,
                episode: number,
                title: v.string("name") ?? v.string("title"),
                overview: v.string("overview") ?? v.string("description"),
                stillURL: v.string("thumbnail"),
                airDate: MetadataFormat.isoDay(v.string("firstAired") ?? v.string("released")),
                rating: MetadataFormat.rating(v.double("rating"))
            ))
        }
        return out.sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
    }
}

extension MediaMetadata.Kind {
    var cinemetaType: String { self == .movie ? "movie" : "series" }
}
