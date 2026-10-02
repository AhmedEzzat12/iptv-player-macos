import Foundation
import Synchronization

/// An in-process HTTP server for URLSession tests, reached through `StubURLProtocol` (install it in a session
/// configuration's `protocolClasses`). Each server has its own made-up host, so tests running in parallel never share
/// one. It serves byte bodies with Range support (206/416) and scripted behaviour: fixed statuses, redirects, and a
/// point where the body stalls until released or the connection is cut. Every request is recorded.
final class StubHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        var host: String
        var path: String
        var range: String?
        var userAgent: String?
        var referer: String?
        var acceptEncoding: String?
    }

    struct Resource {
        var body: Data
        var contentType = "video/x-matroska"
        var supportsRange = true
        /// Answer with this status and an empty body.
        var status: Int?
        /// Answer 302 to this URL.
        var redirect: URL?
    }

    private static let servers = Mutex<[String: StubHTTPServer]>([:])

    static func server(host: String) -> StubHTTPServer? {
        servers.withLock { $0[host] }
    }

    let host: String
    private let lock = NSLock()
    private var resources: [String: Resource] = [:]
    private var holds: [String: Int] = [:]
    private var cuts: Set<String> = []
    private var log: [Request] = []
    private var active = 0
    private var peak = 0

    init() {
        host = "stub-\(UUID().uuidString.lowercased()).test"
        Self.servers.withLock { $0[host] = self }
    }

    func shutDown() {
        Self.servers.withLock { $0[host] = nil }
    }

    func url(_ path: String) -> URL { URL(string: "http://\(host)\(path)")! }

    func serve(_ path: String, _ resource: Resource) {
        lock.withLock { resources[path] = resource }
    }

    /// The body of `path` stops at byte `offset` until `release(path)`.
    func hold(_ path: String, at offset: Int) {
        lock.withLock { holds[path] = offset }
    }

    func release(_ path: String) {
        _ = lock.withLock { holds.removeValue(forKey: path) }
    }

    /// A request stalled at the hold point of `path` fails with "network connection lost" (and the hold is lifted).
    func cut(_ path: String) {
        _ = lock.withLock { cuts.insert(path) }
    }

    var requests: [Request] { lock.withLock { log } }

    /// Most requests that were in flight at the same time.
    var maxConcurrent: Int { lock.withLock { peak } }

    // MARK: Serving (called by StubURLProtocol on a background queue)

    func handle(_ request: URLRequest, for proto: StubURLProtocol) {
        guard let url = request.url else { return }
        let path = url.path
        let resource: Resource? = lock.withLock {
            log.append(Request(host: host, path: path, range: request.value(forHTTPHeaderField: "Range"),
                               userAgent: request.value(forHTTPHeaderField: "User-Agent"),
                               referer: request.value(forHTTPHeaderField: "Referer"),
                               acceptEncoding: request.value(forHTTPHeaderField: "Accept-Encoding")))
            active += 1
            peak = max(peak, active)
            return resources[path]
        }
        let done = { self.lock.withLock { self.active -= 1 } }

        guard let resource else {
            done()
            return proto.respond(url: url, status: 404, headers: ["Content-Length": "0"], body: nil)
        }
        if let target = resource.redirect {
            done()
            return proto.redirect(from: url, to: target)
        }
        if let status = resource.status {
            done()
            return proto.respond(url: url, status: status, headers: ["Content-Length": "0"], body: nil)
        }

        let size = resource.body.count
        var start = 0
        var status = 200
        var headers = ["Content-Type": resource.contentType]
        if resource.supportsRange {
            headers["Accept-Ranges"] = "bytes"
            if let range = request.value(forHTTPHeaderField: "Range"), let from = Self.rangeStart(range) {
                guard from < size else {
                    done()
                    return proto.respond(url: url, status: 416, headers: ["Content-Range": "bytes */\(size)", "Content-Length": "0"], body: nil)
                }
                start = from
                status = 206
                headers["Content-Range"] = "bytes \(from)-\(size - 1)/\(size)"
            }
        }
        headers["Content-Length"] = String(size - start)
        proto.sendHeaders(url: url, status: status, headers: headers)

        var offset = start
        while offset < size {
            if proto.isStopped {
                done()
                return
            }
            let (hold, cut) = lock.withLock { (holds[path], cuts.contains(path)) }
            if let hold, offset >= hold {
                if cut {
                    lock.withLock {
                        holds[path] = nil
                        cuts.remove(path)
                    }
                    done()
                    return proto.fail(URLError(.networkConnectionLost))
                }
                usleep(2_000)
                continue
            }
            var end = min(size, offset + 8_192)
            if let hold, hold > offset { end = min(end, hold) }
            proto.send(resource.body.subdata(in: offset..<end))
            offset = end
        }
        done()
        proto.finish()
    }

    /// `bytes=N-` → N.
    static func rangeStart(_ header: String) -> Int? {
        guard header.hasPrefix("bytes="), let dash = header.firstIndex(of: "-") else { return nil }
        return Int(header[header.index(header.startIndex, offsetBy: 6)..<dash])
    }
}

/// Routes URLSession requests to the `StubHTTPServer` registered for the request's host.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private let stopLock = NSLock()
    private var stopped = false

    var isStopped: Bool { stopLock.withLock { stopped } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        guard let host = request.url?.host, let server = StubHTTPServer.server(host: host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        DispatchQueue.global().async { server.handle(request, for: self) }
    }

    override func stopLoading() {
        stopLock.withLock { stopped = true }
    }

    func sendHeaders(url: URL, status: Int, headers: [String: String]) {
        guard !isStopped, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    func respond(url: URL, status: Int, headers: [String: String], body: Data?) {
        sendHeaders(url: url, status: status, headers: headers)
        if let body { send(body) }
        finish()
    }

    func redirect(from url: URL, to target: URL) {
        guard !isStopped, let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                                          headerFields: ["Location": target.absoluteString, "Content-Length": "0"])
        else { return }
        // A bare request: the client has to carry its own headers (User-Agent, Range…) across the redirect.
        client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
    }

    func send(_ data: Data) {
        guard !isStopped else { return }
        client?.urlProtocol(self, didLoad: data)
    }

    func finish() {
        guard !isStopped else { return }
        client?.urlProtocolDidFinishLoading(self)
    }

    func fail(_ error: any Error) {
        guard !isStopped else { return }
        client?.urlProtocol(self, didFailWithError: error)
    }
}
