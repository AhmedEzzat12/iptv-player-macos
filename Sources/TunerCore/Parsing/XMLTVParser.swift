import Foundation

public struct XMLTVChannel: Sendable, Hashable {
    public var id: String
    public var displayNames: [String]
    public var iconURL: String?
}

public struct XMLTVProgramme: Sendable, Hashable {
    public var channel: String
    public var start: Date
    public var stop: Date
    public var title: String
    public var subtitle: String?
    public var desc: String?
    public var category: String?
    public var iconURL: String?
    public var episode: String?
}

/// Fast, allocation-light XMLTV reader.
///
/// XMLTV is regular enough that a purpose-built scanner over raw bytes is several times faster than
/// `XMLParser` (whose per-callback ObjC/String bridging dominates on 100 MB+ guides). It supports
/// entities (named + numeric), CDATA, comments, processing instructions, DOCTYPE and nested
/// elements (unknown children like `<credits>` are skipped depth-aware).
public struct XMLTVParser {
    public enum Event {
        case channel(XMLTVChannel)
        case programme(XMLTVProgramme)
    }

    /// True if the file starts like an XMLTV document (has a `<tv` root within the first 256 KB).
    /// Lets callers accept a valid-but-empty guide (`<tv></tv>`), which some panels return.
    public static func looksLikeXMLTV(fileAt url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
        let text = String(decoding: head, as: UTF8.self)
        return text.range(of: #"<tv[\s>]"#, options: .regularExpression) != nil || text.contains("<tv/>")
    }

    /// Parses a (decompressed) XMLTV file, memory-mapped.
    public static func parse(fileAt url: URL, _ handler: (Event) throws -> Void) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        try parse(data, handler)
    }

    public static func parse(_ data: Data, _ handler: (Event) throws -> Void) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var scanner = Scanner(p: base, end: raw.count)
            try scanner.run(handler)
        }
    }

    // MARK: - Scanner

    struct Scanner {
        let p: UnsafePointer<UInt8>
        let end: Int
        var i = 0

        init(p: UnsafePointer<UInt8>, end: Int) {
            self.p = p
            self.end = end
        }

        mutating func run(_ handler: (Event) throws -> Void) throws {
            while let tag = nextTag() {
                guard !tag.isClosing else { continue }
                switch tag.name {
                case "channel":
                    if let channel = parseChannel(tag) { try handler(.channel(channel)) }
                case "programme":
                    if let programme = parseProgramme(tag) { try handler(.programme(programme)) }
                default:
                    break // <tv>, unknown top-level elements: descend into them
                }
            }
        }

        struct Tag {
            var name: String
            var attributes: [String: String]
            var isClosing: Bool
            var isSelfClosing: Bool
        }

        /// Advances to the next element tag, skipping text, comments, PIs, DOCTYPE.
        mutating func nextTag() -> Tag? {
            while i < end {
                guard let lt = find(UInt8(ascii: "<"), from: i) else { i = end; return nil }
                i = lt + 1
                guard i < end else { return nil }
                switch p[i] {
                case UInt8(ascii: "!"):
                    if matches("!--", at: i) {
                        i = (findSequence("-->", from: i + 3) ?? end - 3) + 3
                    } else if matches("![CDATA[", at: i) {
                        i = (findSequence("]]>", from: i + 8) ?? end - 3) + 3
                    } else {
                        i = (find(UInt8(ascii: ">"), from: i) ?? end - 1) + 1
                    }
                case UInt8(ascii: "?"):
                    i = (findSequence("?>", from: i) ?? end - 2) + 2
                default:
                    return readTag()
                }
            }
            return nil
        }

        /// Reads a tag starting just after `<`.
        mutating func readTag() -> Tag? {
            var closing = false
            if p[i] == UInt8(ascii: "/") { closing = true; i += 1 }
            let nameStart = i
            while i < end, !isSpace(p[i]), p[i] != UInt8(ascii: ">"), p[i] != UInt8(ascii: "/") { i += 1 }
            let name = string(nameStart, i)
            var attrs: [String: String] = [:]
            var selfClosing = false
            while i < end {
                while i < end, isSpace(p[i]) { i += 1 }
                guard i < end else { break }
                if p[i] == UInt8(ascii: ">") { i += 1; break }
                if p[i] == UInt8(ascii: "/") { selfClosing = true; i += 1; continue }
                let keyStart = i
                while i < end, p[i] != UInt8(ascii: "="), !isSpace(p[i]), p[i] != UInt8(ascii: ">") { i += 1 }
                let key = string(keyStart, i)
                while i < end, isSpace(p[i]) { i += 1 }
                guard i < end, p[i] == UInt8(ascii: "=") else { continue }
                i += 1
                while i < end, isSpace(p[i]) { i += 1 }
                guard i < end else { break }
                let quote = p[i]
                if quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") {
                    let vStart = i + 1
                    let vEnd = find(quote, from: vStart) ?? end
                    attrs[key] = decodeEntities(vStart, vEnd)
                    i = min(end, vEnd + 1)
                } else {
                    let vStart = i
                    while i < end, !isSpace(p[i]), p[i] != UInt8(ascii: ">") { i += 1 }
                    attrs[key] = decodeEntities(vStart, i)
                }
            }
            return Tag(name: name, attributes: attrs, isClosing: closing, isSelfClosing: selfClosing)
        }

        mutating func parseChannel(_ tag: Tag) -> XMLTVChannel? {
            guard let id = tag.attributes["id"]?.nilIfEmpty else {
                if !tag.isSelfClosing { skipElement("channel") }
                return nil
            }
            var channel = XMLTVChannel(id: id, displayNames: [], iconURL: nil)
            guard !tag.isSelfClosing else { return channel }
            while let child = nextTag() {
                if child.isClosing {
                    if child.name == "channel" { break }
                    continue
                }
                switch child.name {
                case "display-name":
                    if !child.isSelfClosing, let text = readText(until: "display-name")?.nilIfEmpty {
                        channel.displayNames.append(text)
                    }
                case "icon":
                    if channel.iconURL == nil { channel.iconURL = child.attributes["src"]?.nilIfEmpty }
                    if !child.isSelfClosing { skipElement("icon") }
                default:
                    if !child.isSelfClosing { skipElement(child.name) }
                }
            }
            return channel
        }

        mutating func parseProgramme(_ tag: Tag) -> XMLTVProgramme? {
            let channel = tag.attributes["channel"]
            let start = tag.attributes["start"].flatMap(XMLTVDate.parse)
            let stop = tag.attributes["stop"].flatMap(XMLTVDate.parse)
            var title: String?
            var subtitle: String?
            var desc: String?
            var category: String?
            var icon: String?
            var episode: String?
            var onscreenEpisode: String?

            if !tag.isSelfClosing {
                while let child = nextTag() {
                    if child.isClosing {
                        if child.name == "programme" { break }
                        continue
                    }
                    if child.isSelfClosing {
                        if child.name == "icon", icon == nil { icon = child.attributes["src"]?.nilIfEmpty }
                        continue
                    }
                    switch child.name {
                    case "title":
                        let t = readText(until: "title")
                        if title == nil { title = t?.nilIfEmpty }
                    case "sub-title":
                        let t = readText(until: "sub-title")
                        if subtitle == nil { subtitle = t?.nilIfEmpty }
                    case "desc":
                        let t = readText(until: "desc")
                        if desc == nil { desc = t?.nilIfEmpty }
                    case "category":
                        let t = readText(until: "category")
                        if category == nil { category = t?.nilIfEmpty }
                    case "episode-num":
                        let system = child.attributes["system"] ?? ""
                        let t = readText(until: "episode-num")?.nilIfEmpty
                        if system == "onscreen" { onscreenEpisode = t } else if system == "xmltv_ns" { episode = t.flatMap(XMLTVDate.formatXMLTVNS) }
                    case "icon":
                        if icon == nil { icon = child.attributes["src"]?.nilIfEmpty }
                        skipElement("icon")
                    default:
                        skipElement(child.name)
                    }
                }
            }
            guard let channel, let start, let stop, stop > start else { return nil }
            return XMLTVProgramme(
                channel: channel,
                start: start,
                stop: stop,
                title: title ?? "",
                subtitle: subtitle,
                desc: desc,
                category: category,
                iconURL: icon,
                episode: onscreenEpisode ?? episode
            )
        }

        /// Reads character data (text + CDATA, entities decoded) up to `</name>`.
        mutating func readText(until name: String) -> String? {
            var result = ""
            var segmentStart = i
            while i < end {
                guard let lt = find(UInt8(ascii: "<"), from: i) else { i = end; break }
                if lt > segmentStart { result += decodeEntities(segmentStart, lt) }
                i = lt + 1
                if matches("![CDATA[", at: i) {
                    let cStart = i + 8
                    let cEnd = findSequence("]]>", from: cStart) ?? end
                    result += string(cStart, cEnd)
                    i = min(end, cEnd + 3)
                    segmentStart = i
                } else if matches("!--", at: i) {
                    i = (findSequence("-->", from: i + 3) ?? end - 3) + 3
                    segmentStart = i
                } else if i < end, p[i] == UInt8(ascii: "/") {
                    // closing tag — assume it is ours (text elements have no element children)
                    i = (find(UInt8(ascii: ">"), from: i) ?? end - 1) + 1
                    _ = name
                    return result.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    // Unexpected nested element inside text: skip it.
                    if let tag = readTag(), !tag.isSelfClosing, !tag.isClosing { skipElement(tag.name) }
                    segmentStart = i
                }
            }
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Skips to the matching `</name>`, honouring nesting of the same element.
        mutating func skipElement(_ name: String) {
            var depth = 1
            while depth > 0, let tag = nextTag() {
                if tag.name == name {
                    if tag.isClosing { depth -= 1 } else if !tag.isSelfClosing { depth += 1 }
                }
            }
        }

        // MARK: Byte helpers

        @inline(__always) func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 }

        func find(_ byte: UInt8, from: Int) -> Int? {
            guard from < end else { return nil }
            let found = memchr(p + from, Int32(byte), end - from)
            return found.map { UnsafePointer($0.assumingMemoryBound(to: UInt8.self)) - p }
        }

        func findSequence(_ seq: StaticString, from: Int) -> Int? {
            let first = seq.utf8Start[0]
            var j = from
            while let k = find(first, from: j) {
                if matches(seq, at: k) { return k }
                j = k + 1
            }
            return nil
        }

        func matches(_ seq: StaticString, at pos: Int) -> Bool {
            let n = seq.utf8CodeUnitCount
            guard pos + n <= end else { return false }
            return memcmp(p + pos, seq.utf8Start, n) == 0
        }

        func string(_ from: Int, _ to: Int) -> String {
            guard to > from else { return "" }
            return String(decoding: UnsafeBufferPointer(start: p + from, count: to - from), as: UTF8.self)
        }

        func decodeEntities(_ from: Int, _ to: Int) -> String {
            guard to > from else { return "" }
            // Fast path: no '&'
            if memchr(p + from, Int32(UInt8(ascii: "&")), to - from) == nil { return string(from, to) }
            var out = [UInt8]()
            out.reserveCapacity(to - from)
            var k = from
            while k < to {
                let b = p[k]
                guard b == UInt8(ascii: "&"), let semi = find(UInt8(ascii: ";"), from: k), semi < to, semi - k <= 10 else {
                    out.append(b)
                    k += 1
                    continue
                }
                let entity = string(k + 1, semi)
                var replacement: String?
                switch entity {
                case "amp": replacement = "&"
                case "lt": replacement = "<"
                case "gt": replacement = ">"
                case "quot": replacement = "\""
                case "apos": replacement = "'"
                case "nbsp": replacement = "\u{00A0}"
                default:
                    if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                        replacement = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                    } else if entity.hasPrefix("#") {
                        replacement = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                    }
                }
                if let replacement {
                    out.append(contentsOf: replacement.utf8)
                    k = semi + 1
                } else {
                    out.append(b)
                    k += 1
                }
            }
            return String(decoding: out, as: UTF8.self)
        }
    }
}

public enum XMLTVDate {
    /// Parses `YYYYMMDDhhmmss ±hhmm` (seconds, minutes and offset optional). Missing offset = UTC.
    public static func parse(_ s: String) -> Date? {
        let bytes = Array(s.utf8)
        guard bytes.count >= 8 else { return nil }
        func num(_ from: Int, _ len: Int) -> Int? {
            guard from + len <= bytes.count else { return nil }
            var v = 0
            for k in from..<(from + len) {
                let d = Int(bytes[k]) - 48
                guard d >= 0, d <= 9 else { return nil }
                v = v * 10 + d
            }
            return v
        }
        guard let year = num(0, 4), let month = num(4, 2), let day = num(6, 2) else { return nil }
        let hour = num(8, 2) ?? 0
        let minute = num(10, 2) ?? 0
        let second = num(12, 2) ?? 0

        var offsetSeconds = 0
        // Find a +/- followed by 4 digits after the digits.
        var k = 8
        while k < bytes.count, bytes[k] >= 48, bytes[k] <= 57 { k += 1 }
        while k < bytes.count, bytes[k] == 0x20 { k += 1 }
        if k < bytes.count, bytes[k] == UInt8(ascii: "+") || bytes[k] == UInt8(ascii: "-") {
            let sign = bytes[k] == UInt8(ascii: "-") ? -1 : 1
            if let hh = num(k + 1, 2) {
                let mm = num(k + 3, 2) ?? 0
                offsetSeconds = sign * (hh * 3600 + mm * 60)
            }
        }

        let days = daysFromCivil(year, month, day)
        let epoch = days * 86400 + hour * 3600 + minute * 60 + second - offsetSeconds
        return Date(timeIntervalSince1970: TimeInterval(epoch))
    }

    /// Howard Hinnant's days-from-civil (proleptic Gregorian).
    static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (m + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    /// `xmltv_ns` "season.episode.part" (zero-based) → "S01E05".
    static func formatXMLTVNS(_ s: String) -> String? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2 else { return nil }
        let season = parts[0].split(separator: "/").first.flatMap { Int($0) }
        let episode = parts[1].split(separator: "/").first.flatMap { Int($0) }
        switch (season, episode) {
        case let (s?, e?): return String(format: "S%02dE%02d", s + 1, e + 1)
        case let (nil, e?): return "E\(e + 1)"
        case let (s?, nil): return "S\(s + 1)"
        default: return nil
        }
    }
}
