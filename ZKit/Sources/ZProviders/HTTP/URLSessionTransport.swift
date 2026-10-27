import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ZCore

/// The default `Transport`, on `URLSession`.
///
/// * `send` uses a shared session with a completion handler.
/// * `stream` uses a per-request session with a data delegate that forwards every received chunk, so it works the
///   same on Linux (swift-corelibs-foundation has no `URLSession.bytes(for:)`) and on Apple platforms.
public final class URLSessionTransport: Transport, @unchecked Sendable {
    public static let shared = URLSessionTransport()

    private let configuration: URLSessionConfiguration
    private let session: URLSession

    public init(configuration: URLSessionConfiguration = .default) {
        self.configuration = configuration
        self.session = URLSession(configuration: configuration)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let urlRequest = Self.makeURLRequest(request)
        let box = CancellableTaskBox()
        let session = self.session
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResponse, Error>) in
                let task = session.dataTask(with: urlRequest) { data, response, error in
                    if let error {
                        continuation.resume(throwing: URLSessionTransport.mapError(error))
                        return
                    }
                    guard let http = response as? HTTPURLResponse else {
                        continuation.resume(throwing: ZError.network("No HTTP response"))
                        return
                    }
                    continuation.resume(returning: HTTPResponse(status: http.statusCode,
                                                                headers: URLSessionTransport.headers(of: http),
                                                                body: data ?? Data()))
                }
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    public func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
        let delegate = StreamingDataDelegate()
        let streamingSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = streamingSession.dataTask(with: Self.makeURLRequest(request))
        delegate.attach(task)
        let head = try await withTaskCancellationHandler {
            try await delegate.waitForHead()
        } onCancel: {
            delegate.cancel()
        }
        return HTTPStreamResponse(status: head.status, headers: head.headers, body: delegate.body)
    }

    // MARK: Helpers

    static func makeURLRequest(_ request: HTTPRequest) -> URLRequest {
        var r = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: request.timeout)
        r.httpMethod = request.method
        for (name, value) in request.headers { r.setValue(value, forHTTPHeaderField: name) }
        r.httpBody = request.body
        return r
    }

    static func headers(of response: HTTPURLResponse) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let name = key as? String else { continue }
            out[name.lowercased()] = "\(value)"
        }
        return out
    }

    static func mapError(_ error: Error) -> Error {
        if error is ZError { return error }
        if error is CancellationError { return ZError.cancelled }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return ZError.cancelled
            case .timedOut: return ZError.network("The request timed out")
            default: return ZError.network(urlError.localizedDescription)
            }
        }
        return ZError.network(error.localizedDescription)
    }
}

/// Holds a task so a cancellation handler can cancel it, even if cancellation comes first.
final class CancellableTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func set(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

/// Bridges URLSession delegate callbacks into a head continuation plus an `AsyncThrowingStream` of body chunks.
final class StreamingDataDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Head: Sendable {
        var status: Int
        var headers: [String: String]
    }

    let body: AsyncThrowingStream<Data, Error>
    private let bodyContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var headContinuation: CheckedContinuation<Head, Error>?
    private var headResult: Result<Head, Error>?
    private var started = false

    override init() {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        body = stream
        bodyContinuation = continuation
        super.init()
        continuation.onTermination = { [weak self] termination in
            if case .cancelled = termination { self?.cancel() }
        }
    }

    func attach(_ task: URLSessionDataTask) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    /// Starts the task and waits until the status line and headers arrived (or the request failed).
    func waitForHead() async throws -> Head {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Head, Error>) in
            lock.lock()
            if let result = headResult {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            headContinuation = continuation
            let toStart: URLSessionDataTask? = started ? nil : task
            started = true
            lock.unlock()
            toStart?.resume()
        }
    }

    func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
        resolveHead(.failure(ZError.cancelled))
        bodyContinuation.finish(throwing: ZError.cancelled)
    }

    private func resolveHead(_ result: Result<Head, Error>) {
        lock.lock()
        if headResult != nil {
            lock.unlock()
            return
        }
        headResult = result
        let continuation = headContinuation
        headContinuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private static func head(of response: URLResponse?) -> Head {
        guard let http = response as? HTTPURLResponse else { return Head(status: 0, headers: [:]) }
        return Head(status: http.statusCode, headers: URLSessionTransport.headers(of: http))
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        resolveHead(.success(Self.head(of: dataTask.response)))
        bodyContinuation.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let mapped = URLSessionTransport.mapError(error)
            resolveHead(.failure(mapped))
            bodyContinuation.finish(throwing: mapped)
        } else {
            resolveHead(.success(Self.head(of: task.response)))
            bodyContinuation.finish()
        }
        lock.lock()
        self.task = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
    }
}
