import Foundation
import ZCore

/// A transport-level HTTP request (no URLSession types, so tests can mock the transport on any platform).
public struct HTTPRequest: Sendable, Hashable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    /// Seconds. For streaming requests this is the idle timeout between chunks.
    public var timeout: TimeInterval

    public init(url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil,
                timeout: TimeInterval = 120) {
        self.url = url; self.method = method; self.headers = headers; self.body = body; self.timeout = timeout
    }

    /// Case-insensitive header lookup.
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// The body parsed as JSON (tests and logging).
    public var jsonBody: JSONValue? { body.flatMap { try? JSONValue.parse($0) } }
}

/// A complete HTTP response. Header names are lower-cased.
public struct HTTPResponse: Sendable, Hashable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(status) }
    public func header(_ name: String) -> String? { headers[name.lowercased()] }
    public var text: String { String(decoding: body, as: UTF8.self) }
}

/// A streaming HTTP response: status and headers first, then the body as raw chunks.
public struct HTTPStreamResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: AsyncThrowingStream<Data, Error>

    public init(status: Int, headers: [String: String] = [:], body: AsyncThrowingStream<Data, Error>) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(status) }
    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// The network seam. `URLSessionTransport` is the default; tests inject a mock.
public protocol Transport: Sendable {
    /// Sends a request and returns the whole response (any status; errors are only thrown for transport failures).
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
    /// Sends a request and returns once the response head is available; the body arrives as chunks.
    func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse
}

extension AsyncThrowingStream where Element == Data, Failure == Error {
    /// Collects a byte stream (up to `limit` bytes).
    func collect(limit: Int = 32 * 1024 * 1024) async throws -> Data {
        var data = Data()
        for try await chunk in self {
            data.append(chunk)
            if data.count >= limit { break }
        }
        return data
    }
}
