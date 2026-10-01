import Foundation

/// Result of parsing an extended M3U playlist.
public struct M3UPlaylist: Sendable {
    public var epgURLs: [String] = []
    public var categories: [Category] = []
    public var channels: [Channel] = []
    public var movieCategories: [Category] = []
    public var movies: [Movie] = []
    public var seriesCategories: [Category] = []
    public var series: [Series] = []
    public var episodes: [Episode] = []
}

/// Byte-level extended-M3U parser.
///
/// Compared with ynotv it additionally:
/// - keeps commas inside quoted attributes and titles (`#EXTINF:-1 tvg-name="A, B",News, Weather`)
/// - honours `#EXTVLCOPT:http-user-agent=` / `http-referrer=` and `#EXTGRP:`
/// - accepts any URL scheme (udp, rtp, rtsp…) instead of silently dropping the entry
/// - splits comma-separated `url-tvg` lists
/// - routes Xtream-style `/movie/` and `/series/` entries into the VOD library
public enum M3UParser {
    public static func parse(_ data: Data, sourceId: String) -> M3UPlaylist {
        let bytes = [UInt8](data)
        var builder = Builder(sourceId: sourceId)

        var pending: PendingEntry?
        var vlcUserAgent: String?
        var vlcReferrer: String?
        var extGroup: String?

        var i = 0
        let n = bytes.count
        // UTF-8 BOM
        if n >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { i = 3 }

        while i < n {
            var lineEnd = i
            while lineEnd < n, bytes[lineEnd] != 0x0A, bytes[lineEnd] != 0x0D { lineEnd += 1 }
            var start = i
            var end = lineEnd
            // advance past \r\n / \n / \r
            i = lineEnd
            while i < n, bytes[i] == 0x0A || bytes[i] == 0x0D { i += 1 }

            while start < end, isSpace(bytes[start]) { start += 1 }
            while end > start, isSpace(bytes[end - 1]) { end -= 1 }
            if start == end { continue }

            let line = bytes[start..<end]
            if line.first == UInt8(ascii: "#") {
                if hasPrefix(line, "#EXTINF") {
                    pending = parseExtinf(line)
                    vlcUserAgent = nil
                    vlcReferrer = nil
                    extGroup = nil
                } else if hasPrefix(line, "#EXTM3U") {
                    builder.applyHeader(parseAttributes(line, from: line.startIndex + 7).attributes)
                } else if hasPrefix(line, "#EXTVLCOPT:") {
                    let opt = string(line.dropFirst(11))
                    if let v = value(of: "http-user-agent", in: opt) { vlcUserAgent = v }
                    if let v = value(of: "http-referrer", in: opt) ?? value(of: "http-referer", in: opt) { vlcReferrer = v }
                } else if hasPrefix(line, "#EXTGRP:") {
                    extGroup = string(line.dropFirst(8)).nilIfEmpty
                }
                continue
            }

            // A URL line consumes the pending #EXTINF metadata.
            guard var entry = pending else { continue }
            pending = nil
            let url = string(line)
            guard url.contains("://") || url.hasPrefix("/") else { continue }
            entry.userAgent = vlcUserAgent ?? entry.attributes["user-agent"] ?? entry.attributes["http-user-agent"]
            entry.referrer = vlcReferrer ?? entry.attributes["referrer"] ?? entry.attributes["http-referrer"]
            if entry.attributes["group-title"] == nil, entry.attributes["group"] == nil, let g = extGroup {
                entry.attributes["group-title"] = g
            }
            builder.add(entry, url: url)
        }
        return builder.finish()
    }

    // MARK: - EXTINF

    struct PendingEntry {
        var title: String
        var attributes: [String: String]
        var userAgent: String?
        var referrer: String?
    }

    static func parseExtinf(_ line: ArraySlice<UInt8>) -> PendingEntry {
        var p = line.startIndex + 7 // after "#EXTINF"
        if p < line.endIndex, line[p] == UInt8(ascii: ":") { p += 1 }
        // duration token
        while p < line.endIndex, isSpace(line[p]) { p += 1 }
        while p < line.endIndex, !isSpace(line[p]), line[p] != UInt8(ascii: ",") { p += 1 }
        let (attributes, titleStart) = parseAttributes(line, from: p)
        var title = ""
        if let t = titleStart {
            title = string(line[t...]).trimmingCharacters(in: .whitespaces)
        }
        return PendingEntry(title: title, attributes: attributes)
    }

    /// Parses `key="value" key2=value2 ...` until a top-level comma (returned as the title start).
    static func parseAttributes(_ line: ArraySlice<UInt8>, from: Int) -> (attributes: [String: String], titleStart: Int?) {
        var attrs: [String: String] = [:]
        var p = from
        let end = line.endIndex
        while p < end {
            while p < end, isSpace(line[p]) { p += 1 }
            guard p < end else { break }
            if line[p] == UInt8(ascii: ",") { return (attrs, p + 1) }

            let keyStart = p
            while p < end, line[p] != UInt8(ascii: "="), line[p] != UInt8(ascii: ","), !isSpace(line[p]) { p += 1 }
            let key = string(line[keyStart..<p]).lowercased()
            // tolerate spaces around '='
            var q = p
            while q < end, isSpace(line[q]) { q += 1 }
            guard q < end, line[q] == UInt8(ascii: "=") else { continue } // bare token
            p = q + 1
            while p < end, isSpace(line[p]) { p += 1 }
            guard p < end else { break }

            let value: String
            let quote = line[p]
            if quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") {
                let valueStart = p + 1
                var close = valueStart
                while close < end, line[close] != quote { close += 1 }
                if close < end {
                    value = string(line[valueStart..<close])
                    p = close + 1
                } else {
                    // Unclosed quote: read up to the next comma.
                    var c = valueStart
                    while c < end, line[c] != UInt8(ascii: ",") { c += 1 }
                    value = string(line[valueStart..<c])
                    p = c
                }
            } else {
                let valueStart = p
                while p < end, !isSpace(line[p]), line[p] != UInt8(ascii: ",") { p += 1 }
                let raw = string(line[valueStart..<p])
                // `tvg-id= tvg-name="A"` must not swallow the next key.
                value = raw.contains("=") && !raw.contains("://") && !raw.contains("?") ? "" : raw
            }
            if !key.isEmpty, attrs[key]?.isEmpty ?? true {
                attrs[key] = value.trimmingCharacters(in: .whitespaces)
            }
        }
        return (attrs, nil)
    }

    // MARK: - Builder

    struct Builder {
        let sourceId: String
        var ids: M3UChannelIDAllocator
        var playlist = M3UPlaylist()
        var categoryIndex: [String: Int] = [:]
        var movieCategoryIndex: [String: Int] = [:]
        var seriesCategoryIndex: [String: Int] = [:]
        var seriesIndex: [String: Int] = [:]
        var movieIDs: Set<String> = []
        var headerCatchupType: String?
        var headerCatchupSource: String?
        var headerCatchupDays: Int?

        init(sourceId: String) {
            self.sourceId = sourceId
            self.ids = M3UChannelIDAllocator(sourceId: sourceId)
        }

        mutating func applyHeader(_ attrs: [String: String]) {
            for key in ["url-tvg", "x-tvg-url", "tvg-url"] {
                guard let raw = attrs[key] else { continue }
                for url in raw.split(separator: ",") {
                    let u = url.trimmingCharacters(in: .whitespaces)
                    if !u.isEmpty, !playlist.epgURLs.contains(u) { playlist.epgURLs.append(u) }
                }
            }
            headerCatchupType = attrs["catchup"] ?? attrs["catchup-type"] ?? attrs["catchup-mode"]
            headerCatchupSource = attrs["catchup-source"] ?? attrs["catchup-url"]
            headerCatchupDays = (attrs["catchup-days"] ?? attrs["catchup-days-max"] ?? attrs["catchup-range"]).flatMap { Int($0) }
            if headerCatchupType == nil, let shift = attrs["timeshift"] ?? attrs["tvg-shift"], (Int(shift) ?? 0) > 0 {
                headerCatchupType = "shift"
            }
        }

        mutating func add(_ entry: PendingEntry, url: String) {
            let a = entry.attributes
            let tvgName = a["tvg-name"]?.nilIfEmpty
            let name = entry.title.nilIfEmpty ?? tvgName ?? "Channel \(playlist.channels.count + 1)"
            let group = (a["group-title"] ?? a["group"])?.nilIfEmpty ?? "Uncategorized"
            let logo = (a["tvg-logo"] ?? a["tvg-icon"] ?? a["logo"])?.nilIfEmpty

            switch M3UParser.classify(url: url) {
            case .movie:
                addMovie(name: name, group: group, logo: logo, url: url)
                return
            case .episode:
                if addEpisode(name: name, group: group, logo: logo, url: url) { return }
                addMovie(name: name, group: group, logo: logo, url: url)
                return
            case .live:
                break
            }

            let categoryId = liveCategory(group)
            var catchupType = (a["catchup"] ?? a["catchup-type"] ?? a["catchup-mode"])?.nilIfEmpty
            if catchupType == nil, let shift = a["timeshift"] ?? a["tvg-shift"], (Int(shift) ?? 0) > 0 { catchupType = "shift" }
            catchupType = catchupType ?? headerCatchupType
            let catchupSource = (a["catchup-source"] ?? a["catchup-url"])?.nilIfEmpty ?? headerCatchupSource
            let days = (a["catchup-days"] ?? a["catchup-days-max"] ?? a["catchup-range"] ?? a["tvg-rec"]).flatMap { Int($0) } ?? headerCatchupDays
            let hasCatchup = catchupType != nil || catchupSource != nil || (a["tvg-rec"].flatMap { Int($0) } ?? 0) > 0

            let tvgId = a["tvg-id"]?.nilIfEmpty
            let channel = Channel(
                id: ids.allocate(tvgId: tvgId, url: url),
                sourceId: sourceId,
                categoryId: categoryId,
                name: name,
                number: (a["tvg-chno"] ?? a["tvg-ch"] ?? a["channel-number"]).flatMap { Int($0) },
                providerOrder: playlist.channels.count,
                logoURL: logo,
                tvgId: tvgId,
                streamURL: url,
                providerStreamId: M3UParser.xtreamStreamId(in: url),
                catchupType: hasCatchup ? CatchupType(m3uValue: catchupType ?? "default") : nil,
                catchupSource: catchupSource,
                catchupDays: hasCatchup ? (days ?? 7) : nil,
                userAgent: entry.userAgent?.nilIfEmpty,
                referrer: entry.referrer?.nilIfEmpty,
                isAdult: a["tvg-adult"] == "1" || group.lowercased().contains("adult") || group.contains("XXX")
            )
            playlist.channels.append(channel)
        }

        mutating func liveCategory(_ name: String) -> String {
            let id = "\(sourceId)_\(StableID.slug(name))"
            if categoryIndex[id] == nil {
                categoryIndex[id] = playlist.categories.count
                playlist.categories.append(Category(id: id, sourceId: sourceId, kind: .live, name: name, providerOrder: playlist.categories.count))
            }
            return id
        }

        mutating func addMovie(name: String, group: String, logo: String?, url: String) {
            let catId = "\(sourceId)_vod_\(StableID.slug(group))"
            if movieCategoryIndex[catId] == nil {
                movieCategoryIndex[catId] = playlist.movieCategories.count
                playlist.movieCategories.append(Category(id: catId, sourceId: sourceId, kind: .movie, name: group, providerOrder: playlist.movieCategories.count))
            }
            var id = "\(sourceId)_vod_\(StableID.hash(url))"
            var n = 2
            while movieIDs.contains(id) { id = "\(sourceId)_vod_\(StableID.hash(url))_\(n)"; n += 1 }
            movieIDs.insert(id)
            let parsed = TitleParser.splitYear(name)
            var movie = Movie(id: id, sourceId: sourceId, categoryId: catId, name: parsed.title, providerId: id, streamURL: url, providerOrder: playlist.movies.count)
            movie.year = parsed.year
            movie.posterURL = logo
            movie.containerExtension = URL(string: url)?.pathExtension.nilIfEmpty
            playlist.movies.append(movie)
        }

        /// Groups "Show Name S01 E02" entries into a series. Returns false if the name has no SxxEyy.
        mutating func addEpisode(name: String, group: String, logo: String?, url: String) -> Bool {
            guard let ep = TitleParser.episodeInfo(name) else { return false }
            let catId = "\(sourceId)_series_\(StableID.slug(group))"
            if seriesCategoryIndex[catId] == nil {
                seriesCategoryIndex[catId] = playlist.seriesCategories.count
                playlist.seriesCategories.append(Category(id: catId, sourceId: sourceId, kind: .series, name: group, providerOrder: playlist.seriesCategories.count))
            }
            let seriesId = "\(sourceId)_series_\(StableID.slug(ep.show))"
            if seriesIndex[seriesId] == nil {
                seriesIndex[seriesId] = playlist.series.count
                var s = Series(id: seriesId, sourceId: sourceId, categoryId: catId, name: ep.show, providerId: seriesId, providerOrder: playlist.series.count)
                s.coverURL = logo
                playlist.series.append(s)
            }
            let epId = "\(sourceId)_ep_\(StableID.hash(url))"
            var episode = Episode(id: epId, seriesId: seriesId, sourceId: sourceId, season: ep.season, number: ep.episode, title: ep.title ?? "Episode \(ep.episode)", providerId: epId, streamURL: url)
            episode.imageURL = logo
            episode.containerExtension = URL(string: url)?.pathExtension.nilIfEmpty
            playlist.episodes.append(episode)
            return true
        }

        func finish() -> M3UPlaylist { playlist }
    }

    // MARK: - Helpers

    enum EntryKind { case live, movie, episode }

    static func classify(url: String) -> EntryKind {
        let lower = url.lowercased()
        if lower.contains("/movie/") { return .movie }
        if lower.contains("/series/") { return .episode }
        if lower.contains("/live/") { return .live }
        let ext = (lower.split(separator: "?").first.map(String.init) ?? lower).split(separator: ".").last.map(String.init) ?? ""
        if ["mkv", "mp4", "avi", "mov", "m4v", "wmv"].contains(ext) { return .movie }
        return .live
    }

    /// `/live/{user}/{pass}/{id}.ts` → `id`
    static func xtreamStreamId(in url: String) -> String? {
        guard let comps = URLComponents(string: url) else { return nil }
        let parts = comps.path.split(separator: "/").map(String.init)
        guard let i = parts.firstIndex(of: "live"), i + 3 < parts.count else { return nil }
        let digits = parts[i + 3].prefix { $0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }

    static func value(of key: String, in option: String) -> String? {
        guard option.lowercased().hasPrefix(key + "=") else { return nil }
        return String(option.dropFirst(key.count + 1)).nilIfEmpty
    }

    @inline(__always) static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 }

    static func hasPrefix(_ line: ArraySlice<UInt8>, _ prefix: StaticString) -> Bool {
        let count = prefix.utf8CodeUnitCount
        guard line.count >= count else { return false }
        return prefix.withUTF8Buffer { buf in
            var idx = line.startIndex
            for b in buf {
                var c = line[idx]
                if c >= 0x61 && c <= 0x7A { c -= 0x20 } // case-insensitive ASCII
                var p = b
                if p >= 0x61 && p <= 0x7A { p -= 0x20 }
                if c != p { return false }
                idx += 1
            }
            return true
        }
    }

    @inline(__always) static func string(_ slice: ArraySlice<UInt8>) -> String {
        String(decoding: slice, as: UTF8.self)
    }
}

/// Heuristics for VOD titles.
public enum TitleParser {
    /// A year in brackets anywhere: "Title (2024)", "Title ( 2026 ) Pure", "Title [2019]".
    static let bracketYear = try! NSRegularExpression(pattern: #"[\(\[]\s*((?:19|20)\d{2})\s*[\)\]]"#)
    /// A trailing year after an explicit separator: "Title - 2024", "Title.2024". A bare trailing number
    /// ("Blade Runner 2049") is deliberately NOT treated as a year.
    static let separatedYear = try! NSRegularExpression(pattern: #"^(.*?)(?:\s+-\s+|\.)((?:19|20)\d{2})\s*$"#)
    static let episodePattern = try! NSRegularExpression(
        pattern: #"^(.*?)[\s._\-]*S(\d{1,2})[\s._\-]*E(\d{1,3})(?:[\s._\-]+(.*))?$"#,
        options: [.caseInsensitive]
    )

    public static func splitYear(_ name: String) -> (title: String, year: String?) {
        let range = NSRange(name.startIndex..., in: name)
        if let m = bracketYear.firstMatch(in: name, range: range),
           let whole = Range(m.range, in: name), let y = Range(m.range(at: 1), in: name) {
            var title = name
            title.removeSubrange(whole)
            title = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            title = title.trimmingCharacters(in: CharacterSet(charactersIn: " -_."))
            return title.isEmpty ? (name, String(name[y])) : (title, String(name[y]))
        }
        if let m = separatedYear.firstMatch(in: name, range: range),
           let t = Range(m.range(at: 1), in: name), let y = Range(m.range(at: 2), in: name) {
            let title = String(name[t]).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { return (title, String(name[y])) }
        }
        return (name, nil)
    }

    public static func episodeInfo(_ name: String) -> (show: String, season: Int, episode: Int, title: String?)? {
        let range = NSRange(name.startIndex..., in: name)
        guard let m = episodePattern.firstMatch(in: name, range: range),
              let showR = Range(m.range(at: 1), in: name),
              let sR = Range(m.range(at: 2), in: name), let eR = Range(m.range(at: 3), in: name),
              let season = Int(name[sR]), let episode = Int(name[eR]) else { return nil }
        let show = String(name[showR]).trimmingCharacters(in: CharacterSet(charactersIn: " -_."))
        guard !show.isEmpty else { return nil }
        var title: String?
        if let tR = Range(m.range(at: 4), in: name) { title = String(name[tR]).nilIfEmpty }
        return (show, season, episode, title)
    }
}
