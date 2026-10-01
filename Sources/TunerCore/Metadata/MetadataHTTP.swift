import Foundation

/// GETs a URL and returns its top-level JSON object. Injected into the metadata clients so tests can serve
/// fixtures instead of hitting the network.
typealias MetadataFetch = @Sendable (_ url: String, _ headers: [String: String]) async throws -> JSONObject

enum MetadataHTTP {
    static let userAgent = "Tuner/1.0 (Macintosh; macOS)"

    /// Live fetcher: `HTTPClient` (retry with backoff on network/5xx errors, none on 4xx) plus its lenient
    /// JSON parse. `HTTPClient.json` is deliberately not used: it logs the request URL on malformed bodies,
    /// and TMDB v3 keys travel in the query string.
    /// Cinemeta's search intermittently answers 504 after ~15 s, hence two retries.
    static func live(_ http: HTTPClient = HTTPClient(userAgent: userAgent, timeout: 20)) -> MetadataFetch {
        { url, headers in
            let data = try await http.data(from: url, headers: headers.merging(["Accept": "application/json"]) { a, _ in a }, retries: 2)
            guard !data.isEmpty else { throw HTTPError.emptyBody }
            guard let object = JSONObject(HTTPClient.parseJSONLeniently(data)) else {
                throw HTTPError.invalidJSON(HTTPClient.preview(of: data))
            }
            return object
        }
    }

    /// True for "this credential is wrong" responses (fall back to another provider, don't retry).
    static func isAuthError(_ error: Error) -> Bool {
        if case HTTPError.status(let code, _) = error { return code == 401 || code == 403 }
        return false
    }

    static func isNotFound(_ error: Error) -> Bool {
        if case HTTPError.status(404, _) = error { return true }
        return false
    }
}

extension JSONObject {
    /// Objects in an array field (non-objects are skipped).
    func objects(_ key: String) -> [JSONObject] { array(key).compactMap { JSONObject($0) } }

    /// A list of names from an array of strings, an array of `{name: …}` objects, or a comma-separated string.
    func stringList(_ key: String) -> [String] {
        var out: [String] = []
        switch raw[key] {
        case let list as [Any]:
            for item in list {
                if let s = item as? String {
                    out.append(s)
                } else if let o = JSONObject(item), let name = o.string("name") {
                    out.append(name)
                }
            }
        case let s as String:
            out = s.split(separator: ",").map(String.init)
        default:
            break
        }
        var seen = Set<String>()
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

enum MetadataFormat {
    /// "2024-03-01T00:00:00.000Z" / "2024-03-01" → "2024-03-01".
    static func isoDay(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), s.count >= 10 else { return nil }
        let day = String(s.prefix(10))
        return day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil ? day : nil
    }

    /// "155 min", "2h 35min", "1 h 5 m", "49" → minutes.
    static func minutes(_ s: String?) -> Int? {
        guard let s = s?.lowercased(), !s.isEmpty else { return nil }
        if let m = s.range(of: #"(\d+)\s*h(?:ours?|rs?)?\s*(?:(\d+)\s*m)?"#, options: .regularExpression) {
            let digits = s[m].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            let total = (digits.first ?? 0) * 60 + (digits.count > 1 ? digits[1] : 0)
            return total > 0 ? total : nil
        }
        let digits = s.prefix { $0.isNumber || $0 == " " }.filter(\.isNumber)
        return Int(digits).flatMap { $0 > 0 ? $0 : nil }
    }

    /// Display year: "2024"; series runs "2008–2013" (en dash); an open run ("2022–") shows its start year.
    static func displayYear(_ s: String?, kind: MediaMetadata.Kind) -> String? {
        let range = TitleMatcher.parseYearRange(s)
        guard let start = range.start else { return nil }
        if kind == .series, let end = range.end, end > start { return "\(start)–\(end)" }
        return String(start)
    }

    /// A rating in 0–10, or nil for missing/zero values.
    static func rating(_ value: Double?) -> Double? {
        guard let value, value > 0, value <= 10 else { return nil }
        return (value * 10).rounded() / 10
    }
}
