import Foundation
import os

public enum HTTPError: LocalizedError, Sendable {
    case badURL(String)
    case status(Int, url: String)
    case emptyBody
    /// The body wasn't JSON; carries the first bytes of what the server sent, for diagnosis.
    case invalidJSON(String?)
    case authFailed(String)

    public var errorDescription: String? {
        switch self {
        case .badURL(let s): "Invalid URL: \(s)"
        case .status(let code, _):
            switch code {
            case 401: "Access denied (401): authentication required"
            case 403: "Access denied (403): blocked by server"
            case 404: "Not found (404)"
            case 512...599, 500...511: "Server error (\(code))"
            default: "HTTP error \(code)"
            }
        case .emptyBody: "The server returned an empty response"
        case .invalidJSON(let preview):
            preview.map { "The server returned invalid data (\($0))" } ?? "The server returned invalid data"
        case .authFailed(let msg): msg
        }
    }
}

/// Thin async wrapper over URLSession with IPTV-friendly defaults.
public struct HTTPClient: Sendable {
    public static let defaultUserAgent = "VLC/3.0.20 LibVLC/3.0.20"

    public var userAgent: String
    public var timeout: TimeInterval
    let session: URLSession

    public init(userAgent: String? = nil, timeout: TimeInterval = 30, session: URLSession = .tunerShared) {
        self.userAgent = userAgent?.nilIfEmpty ?? Self.defaultUserAgent
        self.timeout = timeout
        self.session = session
    }

    public func data(from urlString: String, headers: [String: String] = [:], retries: Int = 2) async throws -> Data {
        guard let url = URL(string: urlString) else { throw HTTPError.badURL(urlString) }
        var attempt = 0
        while true {
            do {
                let (data, response) = try await session.data(for: request(url, headers: headers))
                try Self.check(response, url: urlString)
                return data
            } catch let error as HTTPError {
                // Client errors won't fix themselves on retry.
                if case .status(let code, _) = error, (400..<500).contains(code) { throw error }
                attempt += 1
                if attempt > retries { throw error }
            } catch {
                if (error as? URLError)?.code == .cancelled || Task.isCancelled { throw error }
                attempt += 1
                if attempt > retries { throw error }
            }
            try await Task.sleep(for: .milliseconds(500 * (1 << (attempt - 1))))
        }
    }

    /// Downloads to a temporary file (for multi-hundred-MB EPG/playlist files).
    public func download(from urlString: String, headers: [String: String] = [:]) async throws -> URL {
        guard let url = URL(string: urlString) else { throw HTTPError.badURL(urlString) }
        if url.isFileURL { return url }
        var req = request(url, headers: headers)
        req.timeoutInterval = max(timeout, 120)
        let (tmp, response) = try await session.download(for: req)
        try Self.check(response, url: urlString)
        // Move out of the system-managed location before the session deletes it.
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("tuner-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    /// Fetches and parses JSON. IPTV panels sometimes prepend PHP warnings or return a transient error page,
    /// so a malformed body is (1) re-parsed from its first `[`/`{` to the last `]`/`}`, then (2) re-fetched
    /// with backoff before giving up with a preview of what the server actually sent.
    public func json(from urlString: String, headers: [String: String] = [:], attempts: Int = 3) async throws -> Any {
        var lastError: Error = HTTPError.emptyBody
        for attempt in 1...max(1, attempts) {
            if attempt > 1 { try await Task.sleep(for: .seconds(Double(attempt - 1) * 1.5)) }
            let data = try await data(from: urlString, headers: headers)
            guard !data.isEmpty else {
                lastError = HTTPError.emptyBody
                continue
            }
            if let value = Self.parseJSONLeniently(data) {
                if attempt > 1 { Self.log.notice("JSON recovered on attempt \(attempt, privacy: .public) for \(Self.redacted(urlString), privacy: .public)") }
                return value
            }
            lastError = HTTPError.invalidJSON(Self.preview(of: data))
            Self.log.error("Malformed JSON (attempt \(attempt, privacy: .public)) from \(Self.redacted(urlString), privacy: .public): \(Self.preview(of: data), privacy: .public)")
        }
        throw lastError
    }

    static let log = Logger(subsystem: "app.tuner.macos", category: "HTTP")

    /// URL without credentials, for logs.
    static func redacted(_ url: String) -> String {
        guard var comps = URLComponents(string: url) else { return "?" }
        comps.queryItems = comps.queryItems?.map { item in
            ["username", "password", "token"].contains(item.name) ? URLQueryItem(name: item.name, value: "***") : item
        }
        comps.path = comps.path.replacingOccurrences(of: #"/(live|movie|series|timeshift)/[^/]+/[^/]+/"#, with: "/$1/***/***/", options: .regularExpression)
        return comps.string ?? "?"
    }

    /// Strict parse, then a parse of the outermost `[...]`/`{...}` span (strips leading/trailing junk).
    static func parseJSONLeniently(_ data: Data) -> Any? {
        if let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) { return value }
        log.notice("Strict JSON parse failed (\(preview(of: data), privacy: .public)); trying lenient span")
        let bytes = [UInt8](data)
        guard let start = bytes.firstIndex(where: { $0 == UInt8(ascii: "[") || $0 == UInt8(ascii: "{") }) else { return nil }
        let close: UInt8 = bytes[start] == UInt8(ascii: "[") ? UInt8(ascii: "]") : UInt8(ascii: "}")
        guard let end = bytes.lastIndex(of: close), end > start else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(bytes[start...end]), options: [])
    }

    /// A short, single-line description of a non-JSON body (size + first characters).
    static func preview(of data: Data) -> String {
        let head = String(decoding: data.prefix(120), as: UTF8.self)
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        return head.isEmpty ? "\(size), empty" : "\(size): \(head)"
    }

    func request(_ url: URL, headers: [String: String]) -> URLRequest {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }

    static func check(_ response: URLResponse, url: String) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPError.status(http.statusCode, url: url)
        }
    }
}

extension URLSession {
    /// Shared session: no URL cache (playlists are huge and always fresh), generous connection pool.
    public static let tunerShared: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 8
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()
}

extension String {
    /// Percent-encodes a value for use inside a query string or path segment.
    public var urlQueryEncoded: String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?/#")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }

    public var urlPathEncoded: String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
