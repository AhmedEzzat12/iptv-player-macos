import Foundation

public struct XtreamAccount: Sendable, Hashable {
    public var status: String?
    public var expiresAt: Date?
    public var activeConnections: Int?
    public var maxConnections: Int?
    public var isTrial: Bool
    /// Server clock minus UTC, used to express timeshift start times in the panel's local time.
    public var serverTimeOffset: TimeInterval
    public var epgURLCandidates: [String]
}

/// Client for the Xtream Codes `player_api.php` API.
public struct XtreamClient: Sendable {
    public let base: String
    public let username: String
    public let password: String
    public let http: HTTPClient

    public init(base: String, username: String, password: String, userAgent: String? = nil) {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        if !b.lowercased().hasPrefix("http") { b = "http://" + b }
        self.base = b
        self.username = username
        self.password = password
        self.http = HTTPClient(userAgent: userAgent, timeout: 60)
    }

    public init(source: Source) {
        self.init(base: source.baseURL, username: source.username ?? "", password: source.password ?? "", userAgent: source.userAgent)
    }

    // MARK: - API

    func apiURL(_ action: String? = nil, _ params: [String: String] = [:]) -> String {
        var s = "\(base)/player_api.php?username=\(username.urlQueryEncoded)&password=\(password.urlQueryEncoded)"
        if let action { s += "&action=\(action)" }
        for (k, v) in params.sorted(by: { $0.key < $1.key }) { s += "&\(k)=\(v.urlQueryEncoded)" }
        return s
    }

    func call(_ action: String? = nil, _ params: [String: String] = [:]) async throws -> Any {
        let json = try await http.json(from: apiURL(action, params))
        if let obj = JSONObject(json) {
            if let user = obj.object("user_info"), user.int("auth") == 0 {
                throw HTTPError.authFailed("Xtream login failed — check username and password")
            }
            if action != nil, let message = obj.string("error") ?? obj.string("message"), obj.raw.count <= 2 {
                throw HTTPError.authFailed(message)
            }
        }
        return json
    }

    public func authenticate() async throws -> XtreamAccount {
        let json = try await call()
        guard let obj = JSONObject(json), let user = obj.object("user_info") else {
            throw HTTPError.authFailed("Not an Xtream Codes server (missing user_info)")
        }
        guard user.int("auth") == 1 else {
            throw HTTPError.authFailed("Xtream login failed — check username and password")
        }
        if let status = user.string("status"), status.lowercased() != "active" {
            throw HTTPError.authFailed("Account status: \(status)")
        }
        let server = obj.object("server_info")
        var offset: TimeInterval = 0
        if let server, let timeNow = server.string("time_now"), let ts = server.double("timestamp_now") {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            if let asUTC = f.date(from: timeNow) {
                offset = asUTC.timeIntervalSince1970 - ts
                // Round to the nearest quarter hour; panels report a few seconds of skew.
                offset = (offset / 900).rounded() * 900
            }
        }
        return XtreamAccount(
            status: user.string("status"),
            expiresAt: user.date("exp_date"),
            activeConnections: user.int("active_cons"),
            maxConnections: user.int("max_connections"),
            isTrial: user.bool("is_trial"),
            serverTimeOffset: offset,
            epgURLCandidates: epgURLCandidates(serverInfo: server)
        )
    }

    func epgURLCandidates(serverInfo: JSONObject?) -> [String] {
        let query = "xmltv.php?username=\(username.urlQueryEncoded)&password=\(password.urlQueryEncoded)"
        var urls = ["\(base)/\(query)"]
        if let info = serverInfo, let host = info.string("url") {
            let proto = info.string("server_protocol") ?? "http"
            let port = proto == "https" ? (info.string("https_port") ?? "443") : (info.string("port") ?? "80")
            let standard = (proto == "https" && port == "443") || (proto == "http" && port == "80")
            let candidate = "\(proto)://\(host)\(standard ? "" : ":\(port)")/\(query)"
            if !urls.contains(candidate) { urls.append(candidate) }
        }
        return urls
    }

    // MARK: Live

    public func liveCategories(sourceId: String) async throws -> [Category] {
        LenientJSON.objects(try await call("get_live_categories")).enumerated().compactMap { index, c in
            guard let id = c.string("category_id") else { return nil }
            return Category(id: "\(sourceId)_\(id)", sourceId: sourceId, kind: .live, name: c.string("category_name") ?? "Category \(id)", providerOrder: index)
        }
    }

    public func liveStreams(sourceId: String) async throws -> [Channel] {
        LenientJSON.objects(try await call("get_live_streams")).enumerated().compactMap { index, s in
            guard let streamId = s.string("stream_id") else { return nil }
            let archive = s.int("tv_archive") ?? 0
            return Channel(
                id: "\(sourceId)_\(streamId)",
                sourceId: sourceId,
                categoryId: s.string("category_id").map { "\(sourceId)_\($0)" },
                name: s.string("name") ?? "Channel \(streamId)",
                number: s.int("num"),
                providerOrder: index,
                logoURL: s.string("stream_icon"),
                tvgId: s.string("epg_channel_id"),
                streamURL: "",
                providerStreamId: streamId,
                catchupType: archive > 0 ? .xtream : nil,
                catchupDays: archive > 0 ? (s.int("tv_archive_duration") ?? 7) : nil,
                isAdult: s.bool("is_adult")
            )
        }
    }

    // MARK: VOD

    public func vodCategories(sourceId: String) async throws -> [Category] {
        LenientJSON.objects(try await call("get_vod_categories")).enumerated().compactMap { index, c in
            guard let id = c.string("category_id") else { return nil }
            return Category(id: "\(sourceId)_vod_\(id)", sourceId: sourceId, kind: .movie, name: c.string("category_name") ?? "Category \(id)", providerOrder: index)
        }
    }

    public func vodStreams(sourceId: String) async throws -> [Movie] {
        LenientJSON.objects(try await call("get_vod_streams")).enumerated().compactMap { index, s in
            guard let id = s.string("stream_id") else { return nil }
            let rawName = s.string("name") ?? s.string("title") ?? "Untitled (\(id))"
            let split = TitleParser.splitYear(rawName)
            var m = Movie(id: "\(sourceId)_vod_\(id)", sourceId: sourceId, categoryId: s.string("category_id").map { "\(sourceId)_vod_\($0)" }, name: split.title, providerId: id, providerOrder: index)
            m.year = s.string("year") ?? split.year
            m.posterURL = s.string("stream_icon")
            m.containerExtension = s.string("container_extension")
            m.rating = s.double("rating").flatMap { $0 > 0 ? $0 : nil }
            m.addedAt = s.date("added")
            m.tmdbId = s.string("tmdb") ?? s.string("tmdb_id")
            m.trailer = s.string("youtube_trailer")
            m.plot = s.string("plot")
            m.genre = s.string("genre")
            return m
        }
    }

    public func vodInfo(movie: Movie) async throws -> VODDetails {
        let obj = JSONObject(try await call("get_vod_info", ["vod_id": movie.providerId]))
        var d = VODDetails()
        guard let obj else { return d }
        if let info = obj.object("info") {
            d.plot = info.string("plot") ?? info.string("description")
            d.cast = info.string("cast") ?? info.string("actors")
            d.director = info.string("director")
            d.genre = info.string("genre")
            d.releaseDate = info.string("releasedate") ?? info.string("release_date")
            d.rating = info.double("rating").flatMap { $0 > 0 ? $0 : nil }
            d.durationSeconds = info.int("duration_secs")
            d.posterURL = info.string("movie_image") ?? info.string("cover_big")
            d.backdropURL = Self.firstString(info["backdrop_path"])
            d.trailer = info.string("youtube_trailer")
            d.tmdbId = info.string("tmdb_id")
        }
        d.containerExtension = obj.object("movie_data")?.string("container_extension")
        return d
    }

    // MARK: Series

    public func seriesCategories(sourceId: String) async throws -> [Category] {
        LenientJSON.objects(try await call("get_series_categories")).enumerated().compactMap { index, c in
            guard let id = c.string("category_id") else { return nil }
            return Category(id: "\(sourceId)_series_\(id)", sourceId: sourceId, kind: .series, name: c.string("category_name") ?? "Category \(id)", providerOrder: index)
        }
    }

    public func series(sourceId: String) async throws -> [Series] {
        LenientJSON.objects(try await call("get_series")).enumerated().compactMap { index, s in
            guard let id = s.string("series_id") else { return nil }
            let rawName = s.string("name") ?? s.string("title") ?? "Untitled (\(id))"
            let split = TitleParser.splitYear(rawName)
            var r = Series(id: "\(sourceId)_series_\(id)", sourceId: sourceId, categoryId: s.string("category_id").map { "\(sourceId)_series_\($0)" }, name: split.title, providerId: id, providerOrder: index)
            r.year = s.string("year") ?? split.year
            r.coverURL = s.string("cover")
            r.backdropURL = Self.firstString(s["backdrop_path"])
            r.plot = s.string("plot")
            r.cast = s.string("cast")
            r.director = s.string("director")
            r.genre = s.string("genre")
            r.releaseDate = s.string("releaseDate") ?? s.string("release_date")
            r.rating = s.double("rating").flatMap { $0 > 0 ? $0 : nil }
            r.lastModified = s.date("last_modified")
            r.addedAt = r.lastModified
            r.trailer = s.string("youtube_trailer")
            return r
        }
    }

    public func seriesInfo(series: Series) async throws -> VODDetails {
        let obj = JSONObject(try await call("get_series_info", ["series_id": series.providerId]))
        var d = VODDetails()
        guard let obj else { return d }
        if let info = obj.object("info") {
            d.plot = info.string("plot")
            d.cast = info.string("cast")
            d.director = info.string("director")
            d.genre = info.string("genre")
            d.releaseDate = info.string("releaseDate") ?? info.string("release_date")
            d.rating = info.double("rating").flatMap { $0 > 0 ? $0 : nil }
            d.posterURL = info.string("cover")
            d.backdropURL = Self.firstString(info["backdrop_path"])
            d.trailer = info.string("youtube_trailer")
            d.tmdbId = info.string("tmdb") ?? info.string("tmdb_id")
        }

        // `episodes` is usually {"1": [...], "2": [...]} but some panels return [[...], [...]].
        var groups: [(Int, [JSONObject])] = []
        if let dict = obj["episodes"] as? [String: Any] {
            for (key, value) in dict {
                groups.append((Int(key) ?? 0, LenientJSON.objects(value)))
            }
        } else if let arr = obj["episodes"] as? [Any] {
            for (i, value) in arr.enumerated() {
                let eps = LenientJSON.objects(value)
                groups.append((eps.first?.int("season") ?? (i + 1), eps))
            }
        }
        for (seasonKey, eps) in groups {
            for (i, e) in eps.enumerated() {
                guard let epId = e.string("id") else { continue }
                let season = e.int("season") ?? seasonKey
                let number = e.int("episode_num") ?? (i + 1)
                var ep = Episode(
                    id: "\(series.sourceId)_ep_\(epId)",
                    seriesId: series.id,
                    sourceId: series.sourceId,
                    season: season,
                    number: number,
                    title: e.string("title") ?? "Episode \(number)",
                    providerId: epId
                )
                ep.containerExtension = e.string("container_extension")
                if let info = e.object("info") {
                    ep.plot = info.string("plot")
                    ep.imageURL = info.string("movie_image")
                    ep.durationSeconds = info.int("duration_secs")
                    ep.airDate = info.string("releasedate") ?? info.string("air_date")
                }
                d.episodes.append(ep)
            }
        }
        d.episodes.sort { ($0.season, $0.number) < ($1.season, $1.number) }
        return d
    }

    // MARK: - Playback URLs

    public enum LiveFormat: String, Sendable, CaseIterable {
        case ts
        case m3u8
    }

    public func liveURL(streamId: String, format: LiveFormat = .ts) -> String {
        "\(base)/live/\(username.urlPathEncoded)/\(password.urlPathEncoded)/\(streamId).\(format.rawValue)"
    }

    public func movieURL(streamId: String, ext: String?) -> String {
        "\(base)/movie/\(username.urlPathEncoded)/\(password.urlPathEncoded)/\(streamId).\(ext?.nilIfEmpty ?? "mp4")"
    }

    public func episodeURL(episodeId: String, ext: String?) -> String {
        "\(base)/series/\(username.urlPathEncoded)/\(password.urlPathEncoded)/\(episodeId).\(ext?.nilIfEmpty ?? "mp4")"
    }

    /// `/timeshift/{user}/{pass}/{minutes}/{YYYY-MM-DD:HH-MM}/{id}.ts`, start expressed in server-local time.
    public func timeshiftURL(streamId: String, start: Date, durationMinutes: Int, serverTimeOffset: TimeInterval) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd:HH-mm"
        let startString = f.string(from: start.addingTimeInterval(serverTimeOffset))
        return "\(base)/timeshift/\(username.urlPathEncoded)/\(password.urlPathEncoded)/\(max(1, durationMinutes))/\(startString)/\(streamId).ts"
    }

    // MARK: - Helpers

    static func firstString(_ any: Any?) -> String? {
        if let s = any as? String { return s.nilIfEmpty }
        if let arr = any as? [Any] { return arr.lazy.compactMap { ($0 as? String)?.nilIfEmpty }.first }
        return nil
    }

    /// Extracts server/credentials from a pasted `get.php` or `player_api.php` link.
    public static func parseCredentials(from text: String) -> (base: String, username: String, password: String)? {
        guard let comps = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = comps.scheme, let host = comps.host,
              let user = comps.queryItems?.first(where: { $0.name == "username" })?.value,
              let pass = comps.queryItems?.first(where: { $0.name == "password" })?.value else { return nil }
        let port = comps.port.map { ":\($0)" } ?? ""
        return ("\(scheme)://\(host)\(port)", user, pass)
    }
}
