import Foundation

/// A playlist as sent to Antenna on a TV (the Google TV app's "Add a playlist" screen): the phone scans the QR code
/// the TV shows, `http://<lan-ip>:<port>/<token>`, and POSTs this JSON there. The TV asks before adding it.
public struct SharedPlaylist: Codable, Sendable, Equatable {
    public var version = 1
    public var name: String
    public var kind: String
    public var url: String
    public var username: String?
    public var password: String?
    public var mac: String?
    public var epgURL: String?
    public var userAgent: String?
    public var includeLive: Bool
    public var includeVOD: Bool
    public var backupURLs: [String]
    public var extraEPGURLs: [String]

    public init(source: Source) {
        name = source.name
        kind = source.kind.rawValue
        url = source.url
        username = source.username
        password = source.password
        mac = source.mac
        epgURL = source.epgURL
        userAgent = source.userAgent
        includeLive = source.includeLive
        includeVOD = source.includeVOD
        backupURLs = source.backupURLs
        extraEPGURLs = source.extraEPGURLs
    }
}

public enum PlaylistShare {
    public enum ShareError: LocalizedError, Equatable {
        case notATVCode
        case localFile
        case expired
        case rejected(Int)

        public var errorDescription: String? {
            switch self {
            case .notATVCode: "That isn't the code from the TV's “Add a playlist” screen."
            case .localFile: "Playlists from a file on this device can't be sent. Send a playlist that has a link."
            case .expired: "That code was already used or has expired. Open “Add a playlist” on the TV again."
            case .rejected(let status): "The TV didn't accept the playlist (error \(status))."
            }
        }
    }

    /// Whether `source` can be sent at all (a local M3U file can't: the TV can't reach it).
    public static func canShare(_ source: Source) -> Bool {
        guard let scheme = URL(string: source.url)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// The TV's receiving address from a scanned or typed code, or nil when it isn't one. Only plain HTTP to a
    /// private-network IPv4 address with a 22-character token is accepted, so a QR code from anywhere else can't make
    /// the phone send a password to a server on the internet.
    public static func receiverURL(_ text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.lowercased().hasPrefix("http://") { text = "http://" + text }
        guard let components = URLComponents(string: text), components.scheme?.lowercased() == "http",
              let host = components.host, isPrivateIPv4(host),
              components.user == nil, components.query == nil, components.fragment == nil else { return nil }
        let token = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard token.count == 22, token.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) })
        else { return nil }
        return components.url
    }

    static func isPrivateIPv4(_ host: String) -> Bool {
        // Canonical dotted decimal only: "010" or "+10" must not pass, since some URL loaders read leading zeros as
        // octal and would connect somewhere else than the address checked here.
        let parts = host.split(separator: ".", omittingEmptySubsequences: false).map { part -> Int? in
            guard let n = Int(part), (0...255).contains(n), String(n) == part else { return nil }
            return n
        }
        guard parts.count == 4, parts.allSatisfy({ $0 != nil }) else { return false }
        let a = parts[0]!, b = parts[1]!
        return a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
    }

    public static func request(_ playlist: SharedPlaylist, to url: URL) throws -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(playlist)
        return request
    }

    /// Sends `source` to the TV at `url` (from `receiverURL`).
    public static func send(_ source: Source, to url: URL, session: URLSession = .shared) async throws {
        guard canShare(source) else { throw ShareError.localFile }
        // Redirects are refused: a 307 would resend the body (with the password) wherever it points.
        let (_, response) = try await session.data(for: request(SharedPlaylist(source: source), to: url),
                                                   delegate: NoRedirects())
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw ShareError.expired }
        guard (200..<300).contains(status) else { throw ShareError.rejected(status) }
    }
}

final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}
