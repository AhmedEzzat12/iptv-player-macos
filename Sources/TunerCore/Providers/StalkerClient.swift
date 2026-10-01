import CryptoKit
import Foundation

/// Opaque playback locator for Stalker items, resolved through `create_link` at play time
/// (portal links are tokenised and expire, so they are never stored).
public enum StalkerLocator: Codable, Sendable, Hashable {
    case channel(cmd: String)
    case vod(cmd: String)
    case episode(cmd: String, series: Int?)

    static let prefix = "stalker:"

    public var encoded: String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return Self.prefix + data.base64EncodedString()
    }

    public static func decode(_ string: String) -> StalkerLocator? {
        guard string.hasPrefix(prefix), let data = Data(base64Encoded: String(string.dropFirst(prefix.count))) else { return nil }
        return try? JSONDecoder().decode(StalkerLocator.self, from: data)
    }
}

public struct StalkerEPGEntry: Sendable {
    public var channelId: String
    public var start: Date
    public var stop: Date
    public var title: String
    public var desc: String?
}

/// Client for Stalker/Ministra middleware portals (MAG set-top-box emulation).
public actor StalkerClient {
    public static let magUserAgent = "Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 (KHTML, like Gecko) MAG200 stbapp ver: 2 rev: 250 Safari/533.3"
    static let firmwareVersion = "ImageDescription: 0.2.18-r23-250; ImageDate: Wed Aug 29 10:49:53 EEST 2018; PORTAL version: 5.6.2; API Version: JS API version: 343; STB API version: 146; Player Engine version: 0x58c"

    public let portalURL: String
    public let mac: String
    let http: HTTPClient
    let identity: Identity

    private var endpoint: String?
    private var token: String?
    private var tokenIssuedAt: Date?
    private var tokenTask: Task<Void, Error>?

    struct Identity {
        let sn: String
        let deviceId: String
        let signature: String
        let hwVersion2: String

        init(mac: String) {
            func hex<D: Digest>(_ d: D) -> String { d.map { String(format: "%02x", $0) }.joined() }
            let m = Data(mac.utf8)
            sn = String(hex(Insecure.MD5.hash(data: m)).prefix(13)).uppercased()
            deviceId = hex(SHA256.hash(data: m)).uppercased()
            signature = hex(SHA256.hash(data: Data((mac + sn + deviceId + deviceId).utf8))).uppercased()
            hwVersion2 = hex(Insecure.SHA1.hash(data: m))
        }
    }

    public init(portalURL: String, mac: String) {
        var u = portalURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !u.lowercased().hasPrefix("http") { u = "http://" + u }
        self.portalURL = u
        self.mac = mac.trimmingCharacters(in: .whitespaces).uppercased()
        self.http = HTTPClient(userAgent: Self.magUserAgent, timeout: 60)
        self.identity = Identity(mac: self.mac)
    }

    public init(source: Source) {
        self.init(portalURL: source.url, mac: source.mac ?? "")
    }

    // MARK: - Endpoint discovery

    nonisolated func candidateEndpoints() -> [String] {
        guard let comps = URLComponents(string: portalURL), let scheme = comps.scheme, let host = comps.host else { return [portalURL] }
        let origin = "\(scheme)://\(host)\(comps.port.map { ":\($0)" } ?? "")"
        var path = comps.path
        while path.hasSuffix("/") { path.removeLast() }
        var list: [String] = []
        if path.hasSuffix(".php") {
            list.append(origin + path)
        } else if path.hasSuffix("/c") {
            let prefix = String(path.dropLast(2))
            list.append(origin + prefix + "/portal.php")
            list.append(origin + prefix + "/server/load.php")
        } else if path.contains("stalker_portal") {
            let root = path.components(separatedBy: "stalker_portal").first ?? ""
            list.append(origin + root + "stalker_portal/server/load.php")
        } else if !path.isEmpty {
            list.append(origin + path + "/portal.php")
            list.append(origin + path + "/server/load.php")
        }
        for fallback in ["/stalker_portal/server/load.php", "/portal.php", "/c/portal.php"] where !list.contains(origin + fallback) {
            list.append(origin + fallback)
        }
        return list
    }

    func headers(endpoint: String, includeToken: Bool = true) -> [String: String] {
        let origin = URLComponents(string: endpoint).map { "\($0.scheme ?? "http")://\($0.host ?? "")\($0.port.map { ":\($0)" } ?? "")" } ?? portalURL
        var cookie = "mac=\(mac.urlQueryEncoded); stb_lang=en; timezone=\(TimeZone.current.identifier.urlQueryEncoded)"
        var h = [
            "Referer": origin + "/stalker_portal/c/index.html",
            "Accept-Language": "en-US,en;q=0.5",
            "Pragma": "no-cache",
            "X-User-Agent": "Model: MAG250; Link: WiFi",
        ]
        if includeToken, let token {
            h["Authorization"] = "Bearer \(token)"
            cookie += "; token=\(token)"
        }
        h["Cookie"] = cookie
        return h
    }

    func url(_ endpoint: String, type: String, action: String, _ params: [String: String]) -> String {
        var s = "\(endpoint)?type=\(type)&action=\(action)&JsHttpRequest=1-xml"
        for (k, v) in params.sorted(by: { $0.key < $1.key }) { s += "&\(k)=\(v.urlQueryEncoded)" }
        return s
    }

    // MARK: - Requests

    /// Performs a portal call and returns the unwrapped `js` payload.
    func call(_ type: String, _ action: String, _ params: [String: String] = [:], authenticated: Bool = true) async throws -> Any {
        if authenticated { try await ensureToken() }
        guard let endpoint else { throw HTTPError.authFailed("Portal not reachable") }
        do {
            return try await raw(endpoint, type, action, params, includeToken: authenticated)
        } catch HTTPError.status(let code, _) where authenticated && (code == 401 || code == 403) {
            invalidateToken()
            try await ensureToken()
            return try await raw(endpoint, type, action, params, includeToken: true)
        } catch HTTPError.invalidJSON(_) where authenticated {
            invalidateToken()
            try await ensureToken()
            return try await raw(endpoint, type, action, params, includeToken: true)
        }
    }

    func raw(_ endpoint: String, _ type: String, _ action: String, _ params: [String: String], includeToken: Bool) async throws -> Any {
        let json = try await http.json(from: url(endpoint, type: type, action: action, params), headers: headers(endpoint: endpoint, includeToken: includeToken))
        if let obj = json as? [String: Any] {
            if let js = obj["js"] { return js }
            if let data = obj["data"] { return data }
        }
        return json
    }

    func invalidateToken() {
        token = nil
        tokenIssuedAt = nil
    }

    func ensureToken() async throws {
        if token != nil, let issued = tokenIssuedAt, Date().timeIntervalSince(issued) < 3600 { return }
        if let tokenTask { return try await tokenTask.value }
        let task = Task { try await self.authenticate() }
        tokenTask = task
        defer { tokenTask = nil }
        try await task.value
    }

    private func authenticate() async throws {
        var lastError: Error = HTTPError.authFailed("Portal handshake failed")
        let candidates = endpoint.map { [$0] } ?? candidateEndpoints()
        for candidate in candidates {
            do {
                let js = try await raw(candidate, "stb", "handshake", ["token": "", "prehash": "0"], includeToken: false)
                guard let t = JSONObject(js)?.string("token") else { throw HTTPError.authFailed("Portal returned no token") }
                endpoint = candidate
                token = t
                tokenIssuedAt = Date()
                try? await profile()
                return
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func profile() async throws {
        guard let endpoint else { return }
        let metrics = "{\"mac\":\"\(mac)\",\"sn\":\"\(identity.sn)\",\"type\":\"STB\",\"model\":\"MAG250\",\"uid\":\"\",\"random\":\"\(Self.randomHex(20))\"}"
        let params: [String: String] = [
            "hd": "1", "ver": Self.firmwareVersion, "num_banks": "2", "sn": identity.sn, "stb_type": "MAG250",
            "client_type": "STB", "image_version": "218", "video_out": "hdmi", "device_id": identity.deviceId,
            "device_id2": identity.deviceId, "signature": identity.signature, "auth_second_step": "1",
            "hw_version": "1.7-BD-00", "not_valid_token": "0", "metrics": metrics, "hw_version_2": identity.hwVersion2,
            "timestamp": String(Int(Date().timeIntervalSince1970)), "api_signature": "262", "prehash": "",
        ]
        let js = try await raw(endpoint, "stb", "get_profile", params, includeToken: true)
        if let newToken = JSONObject(js)?.string("token") { token = newToken }
    }

    static func randomHex(_ bytes: Int) -> String {
        (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    // MARK: - Account

    public func expiryDate() async -> Date? {
        guard let js = try? await call("account_info", "get_main_info"), let obj = JSONObject(js) else { return nil }
        // Portals put the expiry in odd fields; "phone" is the most common.
        for key in ["phone", "end_date", "expire_billing_date", "tariff_expired_date"] {
            if let s = obj.string(key), let d = Self.parseLooseDate(s) { return d }
        }
        return nil
    }

    static func parseLooseDate(_ s: String) -> Date? {
        let formats = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd", "MMMM d, yyyy, h:mm a", "dd.MM.yyyy", "MM/dd/yyyy"]
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in formats {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        if let ts = Double(s), ts > 1_000_000_000 { return Date(timeIntervalSince1970: ts) }
        return nil
    }

    // MARK: - Live

    public func liveCategories(sourceId: String) async throws -> [Category] {
        let genres = LenientJSON.objects(try await call("itv", "get_genres", ["include_censored": "1", "censored": "1"]))
        return genres.enumerated().compactMap { index, g in
            guard let id = g.string("id"), id != "*" else { return nil }
            return Category(id: "\(sourceId)_\(id)", sourceId: sourceId, kind: .live, name: g.string("title") ?? "Genre \(id)", providerOrder: index)
        }
    }

    public func channels(sourceId: String) async throws -> [Channel] {
        let js = try await call("itv", "get_all_channels", ["include_censored": "1", "censored": "1"])
        let list = LenientJSON.objects(JSONObject(js)?["data"] ?? js)
        return list.enumerated().compactMap { index, c in
            guard let id = c.string("id") else { return nil }
            let cmd = c.string("cmd") ?? ""
            let archive = c.bool("tv_archive") || (c.int("tv_archive_duration") ?? 0) > 0
            let genre = c.string("tv_genre_id") ?? c.string("genre_id")
            return Channel(
                id: "\(sourceId)_\(id)",
                sourceId: sourceId,
                categoryId: genre.map { "\(sourceId)_\($0)" },
                name: c.string("name") ?? "Channel \(id)",
                number: c.int("number"),
                providerOrder: index,
                logoURL: absolute(c.string("logo")),
                tvgId: c.string("xmltv_id"),
                streamURL: StalkerLocator.channel(cmd: cmd).encoded,
                providerStreamId: id,
                catchupType: archive ? .stalker : nil,
                catchupDays: archive ? max(1, (c.int("tv_archive_duration") ?? 168) / 24) : nil,
                isAdult: c.bool("censored") || c.bool("lock")
            )
        }
    }

    // MARK: - VOD

    public func vodCategories(sourceId: String, kind: CategoryKind) async throws -> [Category] {
        let type = kind == .series ? "series" : "vod"
        let list = LenientJSON.objects(try await call(type, "get_categories", ["sortby": "number"]))
        let prefix = kind == .series ? "series" : "vod"
        return list.enumerated().compactMap { index, c in
            guard let id = c.string("id"), id != "*" else { return nil }
            return Category(id: "\(sourceId)_\(prefix)_\(id)", sourceId: sourceId, kind: kind, name: c.string("title") ?? "Category \(id)", providerOrder: index)
        }
    }

    /// Loads every page of a VOD/series category (portals page 14 items at a time).
    public func items(sourceId: String, kind: CategoryKind, categoryRawId: String, maxPages: Int = 200) async throws -> (movies: [Movie], series: [Series]) {
        let type = kind == .series ? "series" : "vod"
        var query = ["category": categoryRawId, "sortby": "added", "include_censored": "1", "censored": "1"]
        if kind == .series { query.merge(["movie_id": "0", "season_id": "0", "episode_id": "0"]) { $1 } }
        let params = query

        let first = try await page(type: type, params: params, number: 1)
        var all = first.items
        let pages = min(maxPages, Int((Double(first.total) / Double(first.perPage)).rounded(.up)))
        if pages > 1 {
            var results: [Int: [JSONObject]] = [:]
            try await withThrowingTaskGroup(of: (Int, [JSONObject]).self) { group in
                var next = 2
                var inFlight = 0
                while next <= pages || inFlight > 0 {
                    while inFlight < 4, next <= pages {
                        let number = next
                        group.addTask { (number, try await self.page(type: type, params: params, number: number).items) }
                        next += 1
                        inFlight += 1
                    }
                    if let (number, items) = try await group.next() {
                        results[number] = items
                        inFlight -= 1
                    }
                }
            }
            for number in results.keys.sorted() { all += results[number] ?? [] }
        }

        var movies: [Movie] = []
        var series: [Series] = []
        let catId = "\(sourceId)_\(kind == .series ? "series" : "vod")_\(categoryRawId)"
        for (index, item) in all.enumerated() {
            guard let id = item.string("id") else { continue }
            let isSeries = kind == .series || item.bool("is_series")
            let name = item.string("name") ?? item.string("o_name") ?? "Untitled \(id)"
            let poster = absolute(item.string("screenshot_uri") ?? item.string("cover_big"))
            let rating = item.double("rating_imdb") ?? item.double("rating_kinopoisk")
            if isSeries {
                var s = Series(id: "\(sourceId)_series_\(id)", sourceId: sourceId, categoryId: catId, name: name, providerId: id, streamURL: StalkerLocator.vod(cmd: item.string("cmd") ?? "").encoded, providerOrder: index)
                s.coverURL = poster
                s.plot = item.string("description")
                s.year = item.string("year")
                s.genre = item.string("genres_str")
                s.cast = item.string("actors")
                s.director = item.string("director")
                s.rating = rating.flatMap { $0 > 0 ? $0 : nil }
                s.addedAt = Self.parseLooseDate(item.string("added") ?? "")
                series.append(s)
            } else {
                var m = Movie(id: "\(sourceId)_vod_\(id)", sourceId: sourceId, categoryId: catId, name: name, providerId: id, streamURL: StalkerLocator.vod(cmd: item.string("cmd") ?? "").encoded, providerOrder: index)
                m.posterURL = poster
                m.plot = item.string("description")
                m.year = item.string("year")
                m.genre = item.string("genres_str")
                m.cast = item.string("actors")
                m.director = item.string("director")
                m.rating = rating.flatMap { $0 > 0 ? $0 : nil }
                m.durationSeconds = item.int("time").map { $0 * 60 }
                m.addedAt = Self.parseLooseDate(item.string("added") ?? "")
                movies.append(m)
            }
        }
        return (movies, series)
    }

    func page(type: String, params: [String: String], number: Int) async throws -> (items: [JSONObject], total: Int, perPage: Int) {
        var q = params
        q["p"] = String(number)
        let js = try await call(type, "get_ordered_list", q)
        let obj = JSONObject(js)
        let items = LenientJSON.objects(obj?["data"] ?? js)
        return (items, obj?.int("total_items") ?? items.count, max(1, obj?.int("max_page_items") ?? 14))
    }

    public func episodes(series: Series) async throws -> [Episode] {
        let base = ["movie_id": series.providerId, "season_id": "0", "episode_id": "0"]
        var seasons = LenientJSON.objects(JSONObject(try await call("series", "get_ordered_list", base))?["data"])
        if seasons.isEmpty {
            seasons = LenientJSON.objects(JSONObject(try await call("vod", "get_ordered_list", base))?["data"])
        }
        var result: [Episode] = []
        for (seasonIndex, season) in seasons.enumerated() {
            let seasonNumber = season.int("season_number") ?? Self.seasonNumber(in: season.string("name")) ?? (seasonIndex + 1)
            let cmd = season.string("cmd") ?? ""
            let numbers = season.array("series").compactMap { ($0 as? NSNumber)?.intValue ?? Int(($0 as? String) ?? "") }
            if !numbers.isEmpty {
                for n in numbers {
                    var ep = Episode(id: "\(series.sourceId)_ep_\(series.providerId)_\(seasonNumber)_\(n)", seriesId: series.id, sourceId: series.sourceId, season: seasonNumber, number: n, title: "Episode \(n)", providerId: "\(n)", streamURL: StalkerLocator.episode(cmd: cmd, series: n).encoded)
                    ep.imageURL = absolute(season.string("screenshot_uri"))
                    result.append(ep)
                }
            } else if let seasonId = season.string("id") {
                let eps = LenientJSON.objects(JSONObject(try await call("series", "get_ordered_list", ["movie_id": series.providerId, "season_id": seasonId, "episode_id": "0"]))?["data"])
                for (i, e) in eps.enumerated() {
                    guard let eid = e.string("id") else { continue }
                    let n = e.int("series_number") ?? e.int("episode_number") ?? (i + 1)
                    var ep = Episode(id: "\(series.sourceId)_ep_\(eid)", seriesId: series.id, sourceId: series.sourceId, season: seasonNumber, number: n, title: e.string("name") ?? "Episode \(n)", providerId: eid, streamURL: StalkerLocator.episode(cmd: e.string("cmd") ?? cmd, series: nil).encoded)
                    ep.plot = e.string("description")
                    ep.imageURL = absolute(e.string("screenshot_uri"))
                    result.append(ep)
                }
            }
        }
        return result.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
    }

    static func seasonNumber(in name: String?) -> Int? {
        guard let name, let r = name.range(of: #"(?i)season\s*(\d+)"#, options: .regularExpression) else { return nil }
        return Int(name[r].filter(\.isNumber))
    }

    // MARK: - Playback

    /// Resolves a locator to a playable URL via `create_link`.
    public func resolve(_ locator: StalkerLocator) async throws -> String {
        switch locator {
        case .channel(let cmd):
            return try await createLink(type: "itv", cmd: cmd, extra: [:])
        case .vod(let cmd):
            return try await createLink(type: "vod", cmd: cmd, extra: [:])
        case .episode(let cmd, let series):
            return try await createLink(type: "vod", cmd: cmd, extra: series.map { ["series": String($0)] } ?? [:])
        }
    }

    /// Archive playback for a past programme.
    public func catchupURL(channelId: String, cmd: String, start: Date, end: Date) async throws -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd:HH-mm"
        let minutes = max(1, Int(end.timeIntervalSince(start) / 60))
        let direct = sanitize(cmd)
        if direct.contains("/play/"), direct.contains("live.php") {
            return direct.replacingOccurrences(of: "live.php", with: "timeshift.php") + "&start=\(f.string(from: start))&duration=\(minutes)"
        }
        let variants = [cmd, "\(cmd)_", "ffrt http://localhost/ch/\(channelId)_", "ffrt http://localhost/ch/\(channelId)", "http://localhost/ch/\(channelId)_"]
        var lastError: Error = HTTPError.emptyBody
        for variant in variants {
            do {
                let url = try await createLink(type: "tv_archive", cmd: variant, extra: [
                    "utc": String(Int(start.timeIntervalSince1970)), "lutc": String(Int(Date().timeIntervalSince1970)),
                    "ch_id": channelId, "start": f.string(from: start), "end": f.string(from: end),
                ])
                if !url.contains("19691231") { return url }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    func createLink(type: String, cmd: String, extra: [String: String]) async throws -> String {
        var params = ["cmd": cmd, "forced_storage": "undefined", "disable_ad": "0", "download": "0"]
        params.merge(extra) { $1 }
        let js = try await call(type, "create_link", params)
        let obj = JSONObject(js)
        let link = obj?.string("cmd") ?? obj?.string("url") ?? (js as? String) ?? ""
        let url = sanitize(link)
        guard !url.isEmpty, !url.hasPrefix("?"), !url.contains("load.php?token=") else {
            // Fallback: a cmd that is already a URL is often directly playable.
            let direct = sanitize(cmd)
            if direct.contains("://"), !direct.contains("localhost") { return direct }
            throw HTTPError.authFailed("The portal did not return a stream link")
        }
        return url
    }

    /// Strips `ffmpeg `/`ffrt ` prefixes and rewrites localhost/relative links to the portal origin.
    nonisolated func sanitize(_ cmd: String) -> String {
        var s = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["ffmpeg ", "ffrt ", "auto ", "ffrt2 ", "ffrt3 ", "ffrt4 "] where s.lowercased().hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        guard let portal = URLComponents(string: portalURL), let host = portal.host else { return s }
        if s.hasPrefix("/") { return "\(portal.scheme ?? "http")://\(host)\(portal.port.map { ":\($0)" } ?? "")\(s)" }
        if var comps = URLComponents(string: s), let h = comps.host, h == "localhost" || h == "127.0.0.1" || h.isEmpty {
            comps.host = host
            if comps.port == nil { comps.port = portal.port }
            return comps.string ?? s
        }
        return s.replacingOccurrences(of: "http://:", with: "http://\(host):")
    }

    nonisolated func absolute(_ url: String?) -> String? {
        guard let url = url?.nilIfEmpty else { return nil }
        if url.hasPrefix("http") { return url }
        guard let portal = URLComponents(string: portalURL), let host = portal.host else { return url }
        let origin = "\(portal.scheme ?? "http")://\(host)\(portal.port.map { ":\($0)" } ?? "")"
        return origin + (url.hasPrefix("/") ? url : "/" + url)
    }

    // MARK: - EPG

    public func epg(hours: Int = 72) async throws -> [StalkerEPGEntry] {
        let js = try await call("itv", "get_epg_info", ["period": String(hours)])
        let data = (JSONObject(js)?["data"] ?? js) as? [String: Any] ?? [:]
        var entries: [StalkerEPGEntry] = []
        for (channelId, value) in data {
            for p in LenientJSON.objects(value) {
                guard let start = p.date("start_timestamp"), let stop = p.date("stop_timestamp"), stop > start else { continue }
                entries.append(StalkerEPGEntry(channelId: channelId, start: start, stop: stop, title: p.string("name") ?? "", desc: p.string("descr")))
            }
        }
        return entries
    }
}
