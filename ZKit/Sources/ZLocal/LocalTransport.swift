import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One HTTP request made by ZLocal (local-server probes, Hugging Face listings).
public struct LocalHTTPRequest: Sendable, Hashable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    /// Per-request timeout in seconds.
    public var timeout: TimeInterval

    public init(method: String = "GET", url: URL, headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 5) {
        self.method = method; self.url = url; self.headers = headers; self.body = body; self.timeout = timeout
    }
}

/// The raw answer: HTTP status and body bytes. Non-2xx statuses are answers, not errors.
public struct LocalHTTPResponse: Sendable, Hashable {
    public var status: Int
    public var data: Data
    public init(status: Int, data: Data = Data()) { self.status = status; self.data = data }

    public var isSuccess: Bool { (200..<300).contains(status) }
    public var text: String { String(decoding: data, as: UTF8.self) }
}

/// Errors thrown by a transport when no HTTP answer arrived at all.
public enum LocalTransportError: Error, Sendable, Equatable {
    /// Nothing answered within the timeout.
    case timedOut
    /// Connection refused, host unreachable, TLS failure, etc.
    case connectionFailed(String)
}

/// The network seam for ZLocal: URL in, `(status, data)` out. Tests inject a mock; the app uses
/// `URLSessionLocalTransport`.
public protocol LocalTransport: Sendable {
    func send(_ request: LocalHTTPRequest) async throws -> LocalHTTPResponse
}

public extension LocalTransport {
    func get(_ url: URL, headers: [String: String] = [:], timeout: TimeInterval) async throws -> LocalHTTPResponse {
        try await send(LocalHTTPRequest(method: "GET", url: url, headers: headers, timeout: timeout))
    }

    func post(_ url: URL, json body: Data, headers: [String: String] = [:], timeout: TimeInterval) async throws -> LocalHTTPResponse {
        var all = headers
        all["Content-Type"] = "application/json"
        return try await send(LocalHTTPRequest(method: "POST", url: url, headers: all, body: body, timeout: timeout))
    }
}

/// Runs `operation`, throwing `LocalTransportError.timedOut` when it has not finished after `seconds`.
/// The operation must honour task cancellation (both bundled transports do) so the group can unwind.
func withLocalTimeout<T: Sendable>(_ seconds: TimeInterval,
                                   _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let nanos = UInt64(max(0, seconds) * 1_000_000_000)
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: nanos)
            throw LocalTransportError.timedOut
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw LocalTransportError.timedOut }
        return first
    }
}

/// `URLSession`-backed transport (Foundation on Apple platforms, FoundationNetworking on Linux).
public final class URLSessionLocalTransport: LocalTransport, @unchecked Sendable {
    // URLSession is thread-safe; it is only read after init.
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.urlCache = nil
            config.httpCookieStorage = nil
            self.session = URLSession(configuration: config)
        }
    }

    public func send(_ request: LocalHTTPRequest) async throws -> LocalHTTPResponse {
        var req = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: max(0.05, request.timeout))
        req.httpMethod = request.method
        for (k, v) in request.headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = request.body
        let urlRequest = req
        let session = self.session

        let box = DataTaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LocalHTTPResponse, Error>) in
                let task = session.dataTask(with: urlRequest) { data, response, error in
                    if let error {
                        switch (error as? URLError)?.code {
                        case .some(.timedOut):
                            continuation.resume(throwing: LocalTransportError.timedOut)
                        case .some(.cancelled):
                            continuation.resume(throwing: CancellationError())
                        default:
                            continuation.resume(throwing: LocalTransportError.connectionFailed(error.localizedDescription))
                        }
                        return
                    }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    continuation.resume(returning: LocalHTTPResponse(status: status, data: data ?? Data()))
                }
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }
}

/// Holds the in-flight data task so a task-cancellation handler can cancel it.
private final class DataTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false

    func set(_ task: URLSessionDataTask) {
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
