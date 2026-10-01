import Foundation

/// The epgshare01.online catalogue of free XMLTV guides.
public enum OnlineGuideCatalog {
    public static let indexURL = "https://epgshare01.online/epgshare01/"

    struct EmptyListing: LocalizedError {
        var errorDescription: String? { "The online guide catalogue didn't list any guides. Try again later." }
    }

    /// Directory listing → guides sorted by name, then variant.
    public static func fetch() async throws -> [OnlineGuide] {
        let http = HTTPClient(userAgent: MetadataHTTP.userAgent, timeout: 20)
        let data = try await http.data(from: indexURL)
        let guides = parse(listing: String(decoding: data, as: UTF8.self), baseURL: indexURL)
        if guides.isEmpty { throw EmptyListing() }
        return guides
    }

    static let hrefPattern = try! NSRegularExpression(pattern: #"href\s*=\s*["']([^"']+\.xml\.gz)["']"#, options: [.caseInsensitive])
    static let variantPattern = try! NSRegularExpression(pattern: #"^(.*?)(\d+)$"#)

    /// Parses an Apache/nginx-style index page: every `*.xml.gz` link becomes a guide.
    static func parse(listing html: String, baseURL: String) -> [OnlineGuide] {
        let base = URL(string: baseURL)
        var files: [(file: String, url: String, code: String, digits: String?)] = []
        var seen = Set<String>()
        for m in hrefPattern.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let r = Range(m.range(at: 1), in: html) else { continue }
            let href = String(html[r]).replacingOccurrences(of: "&amp;", with: "&")
            let decoded = href.removingPercentEncoding ?? href
            guard let file = decoded.split(separator: "/").last.map(String.init), seen.insert(file).inserted else { continue }
            let absolute = URL(string: href, relativeTo: base)?.absoluteURL.absoluteString ?? baseURL + href
            var stem = String(file.dropLast(".xml.gz".count))
            if stem.lowercased().hasPrefix("epg_ripper_") { stem = String(stem.dropFirst("epg_ripper_".count)) }
            var code = stem
            var digits: String?
            if let vm = variantPattern.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
               let codeR = Range(vm.range(at: 1), in: stem), let digitsR = Range(vm.range(at: 2), in: stem),
               !stem[codeR].isEmpty {
                code = String(stem[codeR]).trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
                digits = String(stem[digitsR])
            }
            files.append((file, absolute, code, digits))
        }

        // Only number variants when a region actually has several files.
        var perCode: [String: Int] = [:]
        for f in files { perCode[f.code.uppercased(), default: 0] += 1 }

        let guides = files.map { f -> OnlineGuide in
            let (name, country) = displayName(forCode: f.code)
            let variant = (perCode[f.code.uppercased()] ?? 0) > 1 ? f.digits.map { String(Int($0) ?? 0) } : nil
            return OnlineGuide(id: f.file, name: name, variant: variant, countryCode: country, url: f.url)
        }
        return guides.sorted { a, b in
            let order = a.name.compare(b.name, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive])
            if order != .orderedSame { return order == .orderedAscending }
            let va = a.variant.flatMap { Int($0) } ?? 0, vb = b.variant.flatMap { Int($0) } ?? 0
            return va != vb ? va < vb : a.id < b.id
        }
    }

    /// Names for epgshare01's non-country files.
    static let specialNames: [String: String] = [
        "ALJAZEERA": "Al Jazeera",
        "ALL_SOURCES": "All Sources (very large)",
        "ASIANTELEVISION": "Asian Television",
        "AUDACY": "Audacy",
        "BEIN": "beIN Sports",
        "DELUXEMUSIC": "Deluxe Music",
        "DIRECTVSPORTS": "DirecTV Sports",
        "DISTROTV": "DistroTV",
        "DRAFTKINGS": "DraftKings",
        "DUMMY_CHANNELS": "Dummy Channels",
        "FANDUEL": "FanDuel",
        "MUSICBOX": "Music Box",
        "PEACOCK": "Peacock",
        "PLEX": "Plex",
        "PLUTO": "Pluto TV",
        "RAKUTEN": "Rakuten TV",
        "RALLY_TV": "Rally TV",
        "ROKU": "The Roku Channel",
        "SAMSUNG": "Samsung TV Plus",
        "SPORTKLUB": "Sport Klub",
        "SSPORTPLUS": "S Sport Plus",
        "STIRR": "Stirr",
        "TBNPLUS": "TBN+",
        "THESPORTPLUS": "The Sport Plus",
        "TUBI": "Tubi",
        "US_LOCALS": "United States — Locals",
        "US_SPORTS": "United States — Sports",
        "VIVA-RUSSIA.RU": "Viva Russia",
        "VOA": "Voice of America",
        "WHALETVPLUS": "Whale TV+",
        "XUMO": "Xumo Play",
    ]

    static let regionCodes: Set<String> = Set(Locale.Region.isoRegions.map(\.identifier).filter { $0.count == 2 && $0.allSatisfy(\.isLetter) })

    /// ISO region code for a file code ("UK" is epgshare's spelling of GB).
    static func region(_ code: String) -> String? {
        let upper = code.uppercased()
        if upper == "UK" { return "GB" }
        return upper.count == 2 && regionCodes.contains(upper) ? upper : nil
    }

    static func countryName(_ region: String) -> String {
        Locale(identifier: "en").localizedString(forRegionCode: region) ?? region
    }

    /// "SA" → ("Saudi Arabia", "SA"); "US_LOCALS" → ("United States — Locals", "US"); "BEIN" → ("beIN Sports", nil).
    static func displayName(forCode code: String) -> (name: String, countryCode: String?) {
        let upper = code.uppercased()
        let parts = upper.split(whereSeparator: { $0 == "_" || $0 == "-" }).map(String.init)
        let prefixRegion = parts.count > 1 ? region(parts[0]) : nil
        if let special = specialNames[upper] { return (special, prefixRegion) }
        if let r = region(upper) { return (countryName(r), r) }
        if let r = prefixRegion {
            return ("\(countryName(r)) — \(titleCase(parts.dropFirst().joined(separator: " ")))", r)
        }
        var stem = code
        if let dot = stem.firstIndex(of: "."), stem.distance(from: stem.startIndex, to: dot) > 0 { stem = String(stem[..<dot]) }
        return (titleCase(stem), nil)
    }

    /// "RALLY_TV" → "Rally TV": words of up to three letters stay upper case (acronyms), others are capitalised.
    static func titleCase(_ s: String) -> String {
        s.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " || $0 == "." })
            .map { word -> String in
                let w = String(word)
                return w.count <= 3 ? w.uppercased() : w.prefix(1).uppercased() + w.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }
}
