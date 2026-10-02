import Foundation

/// One HTTP GET whose body is appended to a file. URLSession calls this delegate on a private serial queue, so a
/// multi-gigabyte body is written there and never passes through the `DownloadService` actor.
///
/// Use: `start()`, `await response()` (the final response, after redirects), then either `await receive(into:)` to
/// take the body or `await drop()` to refuse it. `cancel()` may be called at any time from anywhere; every waiter
/// still resumes, and only once URLSession has finished with the task, so nothing writes to the file afterwards.
/// Each transfer has its own URLSession (invalidated at the end), so a cancelled transfer really closes its
/// connection: on a one-connection account the provider sees it free.
final class FileTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// Headers that must survive redirects (VOD URLs usually 302 to a CDN host).
    static let carriedHeaders = ["User-Agent", "Referer", "Range", "Accept", "Accept-Encoding"]

    private let request: URLRequest
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()

    // Everything below is guarded by `lock`.
    private var task: URLSessionDataTask?
    private var cancelled = false
    private var response: Result<URLResponse, any Error>?
    private var responseWaiter: CheckedContinuation<URLResponse, any Error>?
    private var disposition: (@Sendable (URLSession.ResponseDisposition) -> Void)?
    private var handle: FileHandle?
    private var writeError: (any Error)?
    private var received: Int64 = 0
    private var completion: Result<Void, any Error>?
    private var completionWaiters: [CheckedContinuation<Result<Void, any Error>, Never>] = []

    init(request: URLRequest, configuration: URLSessionConfiguration) {
        self.request = request
        self.configuration = configuration
    }

    /// Body bytes written to the file so far.
    var bytesReceived: Int64 { lock.withLock { received } }

    func start() {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        queue.name = "app.tuner.download"
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let task = session.dataTask(with: request)
        let cancelled = lock.withLock {
            self.task = task
            return self.cancelled
        }
        task.resume()
        if cancelled { task.cancel() }
    }

    /// The response once its headers arrive (redirects already followed). Throws the network error otherwise.
    func response() async throws -> URLResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let response {
                lock.unlock()
                continuation.resume(with: response)
            } else {
                responseWaiter = continuation
                lock.unlock()
            }
        }
    }

    /// Accepts the body, appending it to `handle` (positioned by the caller), and returns when it ends.
    func receive(into handle: FileHandle) async -> Result<Void, any Error> {
        let allow = lock.withLock {
            self.handle = handle
            defer { disposition = nil }
            return disposition
        }
        allow?(.allow)
        return await finished()
    }

    /// Refuses the body (or stops the transfer) and waits until the session is done with it.
    func drop() async {
        cancel()
        _ = await finished()
    }

    func cancel() {
        let (pending, task) = lock.withLock {
            cancelled = true
            defer { disposition = nil }
            return (disposition, self.task)
        }
        pending?(.cancel)
        task?.cancel()
    }

    /// Waits for the task to complete: success, the network error, or the error that stopped writing the file.
    func finished() async -> Result<Void, any Error> {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let completion {
                lock.unlock()
                continuation.resume(returning: completion)
            } else {
                completionWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        var next = newRequest
        for field in Self.carriedHeaders {
            if let value = request.value(forHTTPHeaderField: field) { next.setValue(value, forHTTPHeaderField: field) }
        }
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        if cancelled {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        self.response = .success(response)
        disposition = completionHandler
        let waiter = responseWaiter
        responseWaiter = nil
        lock.unlock()
        waiter?.resume(returning: response)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let handle = lock.withLock { writeError == nil ? self.handle : nil }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            lock.withLock { received += Int64(data.count) }
        } catch {
            lock.withLock { writeError = error }
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        let result: Result<Void, any Error>
        if let writeError {
            result = .failure(writeError)
        } else if let error {
            result = .failure(error)
        } else {
            result = .success(())
        }
        completion = result
        let failure = error ?? URLError(.badServerResponse)
        if response == nil { response = .failure(failure) }
        let responseWaiter = self.responseWaiter
        self.responseWaiter = nil
        let waiters = completionWaiters
        completionWaiters = []
        disposition = nil
        lock.unlock()

        responseWaiter?.resume(throwing: failure)
        for waiter in waiters { waiter.resume(returning: result) }
        session.finishTasksAndInvalidate()
    }
}

/// `Content-Range: bytes 100-999/1000`, `bytes 100-999/*` or `bytes */1000`.
struct ContentRange: Equatable {
    var start: Int64?
    var total: Int64?

    init?(_ header: String?) {
        guard let header = header?.trimmingCharacters(in: .whitespaces),
              header.lowercased().hasPrefix("bytes") else { return nil }
        let spec = header.dropFirst(5).trimmingCharacters(in: .whitespaces)
        let parts = spec.split(separator: "/", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        start = parts[0] == "*" ? nil : parts[0].split(separator: "-").first.flatMap { Int64($0) }
        total = Int64(parts[1])
        if start == nil, total == nil { return nil }
    }

    init(response: URLResponse) {
        self = (response as? HTTPURLResponse).flatMap { ContentRange($0.value(forHTTPHeaderField: "Content-Range")) }
            ?? ContentRange(start: nil, total: nil)
    }

    init(start: Int64?, total: Int64?) {
        self.start = start
        self.total = total
    }
}
