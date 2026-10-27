import Foundation
import ZCore

/// Retry behaviour for 408 / 429 / 5xx and network failures.
public struct RetryPolicy: Sendable, Hashable {
    /// Retries after the first attempt.
    public var maxRetries: Int
    /// First backoff delay in seconds; doubles per attempt (with ±20% jitter), capped at `maxDelay`.
    public var baseDelay: Double
    public var maxDelay: Double
    /// A `Retry-After` longer than this is not waited for: the error is returned so the caller can decide.
    public var maxRetryAfter: Double

    public init(maxRetries: Int = 2, baseDelay: Double = 1, maxDelay: Double = 20, maxRetryAfter: Double = 60) {
        self.maxRetries = maxRetries; self.baseDelay = baseDelay; self.maxDelay = maxDelay; self.maxRetryAfter = maxRetryAfter
    }

    public static let standard = RetryPolicy()
    public static let noRetries = RetryPolicy(maxRetries: 0)

    public func backoff(attempt: Int) -> Double {
        let raw = baseDelay * pow(2, Double(max(0, attempt)))
        return min(maxDelay, raw) * Double.random(in: 0.8...1.2)
    }

    public static func isRetryable(status: Int) -> Bool {
        status == 408 || status == 429 || status == 529 || (500...599).contains(status) && status != 501 && status != 505
    }
}

/// One line for the optional request/response log hook. Secrets in headers and the `key` query item are redacted.
public struct HTTPLogEntry: Sendable {
    public enum Phase: String, Sendable { case request, response, retry, failure }
    public var phase: Phase
    public var method: String
    public var url: String
    public var status: Int?
    public var headers: [String: String]
    /// Request body (request phase) or response body (response/failure phase, non-streaming or error bodies only).
    public var body: Data?
    public var note: String?
}

/// HTTP over a `Transport`: JSON helpers, retries with backoff (honouring `Retry-After`), and `ZError` mapping.
public struct HTTPClient: Sendable {
    public var transport: any Transport
    public var retry: RetryPolicy
    /// Default per-request timeout (seconds) for non-streaming requests.
    public var timeout: TimeInterval
    /// Idle timeout (seconds) between chunks of a streaming response.
    public var streamTimeout: TimeInterval
    /// Sleeps between retries (injectable so tests do not wait).
    public var sleep: @Sendable (Double) async throws -> Void
    /// Optional log hook (request/response/retry/failure).
    public var logger: (@Sendable (HTTPLogEntry) -> Void)?

    public init(transport: any Transport = URLSessionTransport.shared, retry: RetryPolicy = .standard,
                timeout: TimeInterval = 120, streamTimeout: TimeInterval = 300,
                sleep: (@Sendable (Double) async throws -> Void)? = nil,
                logger: (@Sendable (HTTPLogEntry) -> Void)? = nil) {
        self.transport = transport
        self.retry = retry
        self.timeout = timeout
        self.streamTimeout = streamTimeout
        self.sleep = sleep ?? HTTPClient.taskSleep
        self.logger = logger
    }

    /// The default sleeper.
    public static let taskSleep: @Sendable (Double) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    // MARK: Requests

    /// Sends with retries; returns the 2xx response or throws the mapped `ZError`.
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var attempt = 0
        while true {
            try checkCancelled()
            log(.request, request, body: request.body)
            let response: HTTPResponse
            do {
                response = try await transport.send(request)
            } catch {
                let mapped = Self.normalize(error)
                if case ZError.network = mapped, attempt < retry.maxRetries {
                    let delay = retry.backoff(attempt: attempt)
                    log(.retry, request, note: "network error, retrying in \(delay)s: \(mapped)")
                    try await pause(delay)
                    attempt += 1
                    continue
                }
                log(.failure, request, note: "\(mapped)")
                throw mapped
            }
            log(.response, request, status: response.status, headers: response.headers, body: response.body)
            if response.isSuccess { return response }
            if let delay = retryDelay(status: response.status, headers: response.headers, body: response.body, attempt: attempt) {
                log(.retry, request, status: response.status, note: "retrying in \(delay)s")
                try await pause(delay)
                attempt += 1
                continue
            }
            throw ProviderErrorMapper.error(status: response.status, headers: response.headers, body: response.body)
        }
    }

    /// Opens a streaming request with retries on the response head; returns the body chunks of a 2xx response.
    /// Non-2xx bodies are read fully and mapped to `ZError`.
    public func stream(_ request: HTTPRequest) async throws -> AsyncThrowingStream<Data, Error> {
        var attempt = 0
        while true {
            try checkCancelled()
            log(.request, request, body: request.body)
            let response: HTTPStreamResponse
            do {
                response = try await transport.stream(request)
            } catch {
                let mapped = Self.normalize(error)
                if case ZError.network = mapped, attempt < retry.maxRetries {
                    let delay = retry.backoff(attempt: attempt)
                    log(.retry, request, note: "network error, retrying in \(delay)s: \(mapped)")
                    try await pause(delay)
                    attempt += 1
                    continue
                }
                log(.failure, request, note: "\(mapped)")
                throw mapped
            }
            if response.isSuccess {
                log(.response, request, status: response.status, headers: response.headers)
                return response.body
            }
            let body = (try? await response.body.collect(limit: 256 * 1024)) ?? Data()
            log(.response, request, status: response.status, headers: response.headers, body: body)
            if let delay = retryDelay(status: response.status, headers: response.headers, body: body, attempt: attempt) {
                log(.retry, request, status: response.status, note: "retrying in \(delay)s")
                try await pause(delay)
                attempt += 1
                continue
            }
            throw ProviderErrorMapper.error(status: response.status, headers: response.headers, body: body)
        }
    }

    // MARK: JSON helpers

    public func request(url: URL, method: String = "GET", headers: [String: String] = [:], json: JSONValue? = nil,
                        stream: Bool = false) throws -> HTTPRequest {
        var allHeaders = headers
        var body: Data?
        if let json {
            body = try json.jsonData()
            if !allHeaders.keys.contains(where: { $0.caseInsensitiveCompare("content-type") == .orderedSame }) {
                allHeaders["Content-Type"] = "application/json"
            }
        }
        if !allHeaders.keys.contains(where: { $0.caseInsensitiveCompare("accept") == .orderedSame }) {
            allHeaders["Accept"] = stream ? "text/event-stream" : "application/json"
        }
        return HTTPRequest(url: url, method: method, headers: allHeaders, body: body,
                           timeout: stream ? streamTimeout : timeout)
    }

    public func getJSON(_ url: URL, headers: [String: String] = [:]) async throws -> JSONValue {
        try Self.decodeJSON(try await send(try request(url: url, headers: headers)))
    }

    public func postJSON(_ url: URL, headers: [String: String] = [:], body: JSONValue) async throws -> JSONValue {
        try Self.decodeJSON(try await send(try request(url: url, method: "POST", headers: headers, json: body)))
    }

    public static func decodeJSON(_ response: HTTPResponse) throws -> JSONValue {
        do {
            return try JSONValue.parse(response.body)
        } catch {
            throw ZError.decoding("Expected JSON, got: \(String(response.text.prefix(300)))")
        }
    }

    // MARK: Internals

    func retryDelay(status: Int, headers: [String: String], body: Data, attempt: Int) -> Double? {
        guard attempt < retry.maxRetries, RetryPolicy.isRetryable(status: status) else { return nil }
        if status == 429, ProviderErrorMapper.isQuotaExhausted(message: ProviderErrorMapper.message(from: body)) {
            return nil
        }
        if let after = ProviderErrorMapper.retryAfter(headers: headers, body: body) {
            return after <= retry.maxRetryAfter ? after : nil
        }
        return retry.backoff(attempt: attempt)
    }

    private func pause(_ seconds: Double) async throws {
        do {
            try await sleep(seconds)
        } catch {
            throw Self.normalize(error)
        }
    }

    private func checkCancelled() throws {
        if Task.isCancelled { throw ZError.cancelled }
    }

    /// Maps cancellation and foreign errors into `ZError` where there is an obvious equivalent.
    public static func normalize(_ error: Error) -> Error {
        if let z = error as? ZError { return z }
        if error is CancellationError { return ZError.cancelled }
        if error is DecodingError { return ZError.decoding("\(error)") }
        return URLSessionTransport.mapError(error)
    }

    private func log(_ phase: HTTPLogEntry.Phase, _ request: HTTPRequest, status: Int? = nil,
                     headers: [String: String]? = nil, body: Data? = nil, note: String? = nil) {
        guard let logger else { return }
        logger(HTTPLogEntry(phase: phase, method: request.method, url: Self.redact(request.url),
                            status: status, headers: Self.redact(headers ?? request.headers), body: body, note: note))
    }

    static let secretHeaders: Set<String> = ["authorization", "x-api-key", "x-goog-api-key", "api-key", "proxy-authorization"]

    static func redact(_ headers: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (name, value) in headers {
            out[name] = secretHeaders.contains(name.lowercased()) ? "***" : value
        }
        return out
    }

    static func redact(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, !items.isEmpty else { return url.absoluteString }
        components.queryItems = items.map { item in
            ["key", "api_key", "apikey", "token"].contains(item.name.lowercased()) ? URLQueryItem(name: item.name, value: "***") : item
        }
        return components.string ?? url.absoluteString
    }
}
