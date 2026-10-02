import Foundation

/// A fully resolved stream ready for a playback engine.
public struct PlayableStream: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case live
        case catchup
        case vod
    }

    public var url: URL
    public var userAgent: String
    public var referrer: String?
    public var kind: Kind

    public init(url: URL, userAgent: String, referrer: String? = nil, kind: Kind) {
        self.url = url
        self.userAgent = userAgent
        self.referrer = referrer
        self.kind = kind
    }

    /// HTTP headers for engines that take a header dictionary.
    public var headers: [String: String] {
        var h = ["User-Agent": userAgent]
        if let referrer { h["Referer"] = referrer }
        return h
    }
}

public enum StreamError: LocalizedError {
    case missingSource
    case invalidURL(String)
    case catchupUnavailable

    public var errorDescription: String? {
        switch self {
        case .missingSource: "This item's playlist was removed"
        case .invalidURL(let s): "Invalid stream URL: \(s)"
        case .catchupUnavailable: "This channel has no archive for that programme"
        }
    }
}

/// Turns channels, programmes and VOD items into playable URLs (building Xtream URLs,
/// calling Stalker `create_link`, building catchup URLs).
public actor StreamResolver {
    let db: AppDatabase
    let sync: SyncService
    var xtreamOffsets: [String: TimeInterval] = [:]
    public var defaultUserAgent: String = HTTPClient.defaultUserAgent

    public init(db: AppDatabase, sync: SyncService) {
        self.db = db
        self.sync = sync
    }

    public func setDefaultUserAgent(_ ua: String?) {
        defaultUserAgent = ua?.nilIfEmpty ?? HTTPClient.defaultUserAgent
    }

    func source(_ id: String) async throws -> Source {
        guard let s = try await db.source(id: id) else { throw StreamError.missingSource }
        return s
    }

    func userAgent(channel: Channel? = nil, source: Source) -> String {
        channel?.userAgent?.nilIfEmpty ?? source.userAgent?.nilIfEmpty ?? (source.kind == .stalker ? StalkerClient.magUserAgent : defaultUserAgent)
    }

    func makeURL(_ s: String) throws -> URL {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let u = URL(string: trimmed), u.scheme != nil { return u }
        if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed), let u = URL(string: encoded), u.scheme != nil { return u }
        if trimmed.hasPrefix("/") { return URL(fileURLWithPath: trimmed) }
        throw StreamError.invalidURL(s)
    }

    // MARK: Live

    public func live(_ channel: Channel, format: XtreamClient.LiveFormat = .ts) async throws -> PlayableStream {
        let source = try await source(channel.sourceId)
        let ua = userAgent(channel: channel, source: source)
        switch source.kind {
        case .xtream:
            guard let id = channel.providerStreamId else { throw StreamError.invalidURL(channel.name) }
            return PlayableStream(url: try makeURL(XtreamClient(source: source).liveURL(streamId: id, format: format)), userAgent: ua, kind: .live)
        case .stalker:
            guard let locator = StalkerLocator.decode(channel.streamURL) else { throw StreamError.invalidURL(channel.streamURL) }
            let url = try await sync.stalkerClient(for: source).resolve(locator)
            return PlayableStream(url: try makeURL(url), userAgent: ua, kind: .live)
        case .m3u:
            var url = channel.streamURL
            // Xtream-style M3U links can be switched to HLS for AVFoundation.
            if format == .m3u8, channel.providerStreamId != nil, url.hasSuffix(".ts") {
                url = String(url.dropLast(3)) + ".m3u8"
            }
            return PlayableStream(url: try makeURL(url), userAgent: ua, referrer: channel.referrer, kind: .live)
        }
    }

    // MARK: Catchup

    public func catchup(_ channel: Channel, program: Program, paddingBefore: TimeInterval = 0, paddingAfter: TimeInterval = 0) async throws -> PlayableStream {
        guard let type = channel.catchupType else { throw StreamError.catchupUnavailable }
        let source = try await source(channel.sourceId)
        let ua = userAgent(channel: channel, source: source)
        let start = program.start.addingTimeInterval(-paddingBefore)
        let end = min(program.end.addingTimeInterval(paddingAfter), Date())
        let end2 = end > start ? end : program.end
        let minutes = Int((end2.timeIntervalSince(start) / 60).rounded(.up))

        switch (source.kind, type) {
        case (.stalker, _):
            let client = await sync.stalkerClient(for: source)
            let cmd: String
            if case .channel(let c)? = StalkerLocator.decode(channel.streamURL) { cmd = c } else { cmd = "" }
            let url = try await client.catchupURL(channelId: channel.providerStreamId ?? "", cmd: cmd, start: start, end: end2)
            return PlayableStream(url: try makeURL(url), userAgent: ua, kind: .catchup)

        case (.xtream, _):
            guard let id = channel.providerStreamId else { throw StreamError.catchupUnavailable }
            let client = XtreamClient(source: source)
            let offset = await serverOffset(client, key: source.id)
            let url = client.timeshiftURL(streamId: id, start: start, durationMinutes: minutes, serverTimeOffset: offset)
            return PlayableStream(url: try makeURL(url), userAgent: ua, kind: .catchup)

        case (.m3u, _):
            if channel.catchupSource == nil, let xc = Self.xtreamParts(channel.streamURL) {
                // Xtream-panel M3U: use the panel's timeshift endpoint.
                let client = XtreamClient(base: xc.base, username: xc.user, password: xc.pass, userAgent: ua)
                let offset = await serverOffset(client, key: xc.base + xc.user)
                let url = client.timeshiftURL(streamId: xc.id, start: start, durationMinutes: minutes, serverTimeOffset: offset)
                return PlayableStream(url: try makeURL(url), userAgent: ua, referrer: channel.referrer, kind: .catchup)
            }
            let url = CatchupURLBuilder.m3u(channelURL: channel.streamURL, type: type, template: channel.catchupSource,
                                            tvgId: channel.tvgId, start: start, end: end2)
            return PlayableStream(url: try makeURL(url), userAgent: ua, referrer: channel.referrer, kind: .catchup)
        }
    }

    func serverOffset(_ client: XtreamClient, key: String) async -> TimeInterval {
        if let cached = xtreamOffsets[key] { return cached }
        let offset = (try? await client.authenticate().serverTimeOffset) ?? 0
        xtreamOffsets[key] = offset
        return offset
    }

    /// `http://host:port/live/user/pass/123.ts` → parts.
    static func xtreamParts(_ url: String) -> (base: String, user: String, pass: String, id: String)? {
        guard let comps = URLComponents(string: url), let scheme = comps.scheme, let host = comps.host else { return nil }
        var parts = comps.path.split(separator: "/").map(String.init)
        if parts.first == "live" { parts.removeFirst() }
        guard parts.count == 3 else { return nil }
        let id = parts[2].prefix { $0.isNumber }
        guard !id.isEmpty else { return nil }
        return ("\(scheme)://\(host)\(comps.port.map { ":\($0)" } ?? "")", parts[0], parts[1], String(id))
    }

    // MARK: VOD

    /// A completed download of the movie/episode, played from this Mac: works offline and uses no provider connection
    /// (and no source, so it plays even after its playlist is removed). A completed download whose file has gone is
    /// marked failed ("File was moved or deleted") and the title streams instead.
    func downloadedFile(mediaId: String) async -> PlayableStream? {
        guard let file = await db.completedDownloadFile(mediaId: mediaId) else { return nil }
        return PlayableStream(url: file, userAgent: HTTPClient.defaultUserAgent, kind: .vod)
    }

    public func movie(_ movie: Movie) async throws -> PlayableStream {
        if let local = await downloadedFile(mediaId: movie.id) { return local }
        let source = try await source(movie.sourceId)
        let ua = userAgent(source: source)
        switch source.kind {
        case .xtream:
            return PlayableStream(url: try makeURL(XtreamClient(source: source).movieURL(streamId: movie.providerId, ext: movie.containerExtension)), userAgent: ua, kind: .vod)
        case .stalker:
            guard let locator = StalkerLocator.decode(movie.streamURL) else { throw StreamError.invalidURL(movie.streamURL) }
            let url = try await sync.stalkerClient(for: source).resolve(locator)
            return PlayableStream(url: try makeURL(url), userAgent: ua, kind: .vod)
        case .m3u:
            return PlayableStream(url: try makeURL(movie.streamURL), userAgent: ua, kind: .vod)
        }
    }

    public func episode(_ episode: Episode) async throws -> PlayableStream {
        if let local = await downloadedFile(mediaId: episode.id) { return local }
        let source = try await source(episode.sourceId)
        let ua = userAgent(source: source)
        switch source.kind {
        case .xtream:
            return PlayableStream(url: try makeURL(XtreamClient(source: source).episodeURL(episodeId: episode.providerId, ext: episode.containerExtension)), userAgent: ua, kind: .vod)
        case .stalker:
            guard let locator = StalkerLocator.decode(episode.streamURL) else { throw StreamError.invalidURL(episode.streamURL) }
            let url = try await sync.stalkerClient(for: source).resolve(locator)
            return PlayableStream(url: try makeURL(url), userAgent: ua, kind: .vod)
        case .m3u:
            return PlayableStream(url: try makeURL(episode.streamURL), userAgent: ua, kind: .vod)
        }
    }
}
