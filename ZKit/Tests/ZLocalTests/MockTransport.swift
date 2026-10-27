import Foundation
import XCTest
@testable import ZLocal

/// Scripted transport: routes `"METHOD http://host:port/path"` (or `"http://host:port/path"` for GET) to canned
/// answers. A host:port with no routes refuses the connection; a live host:port answers 404 for unknown paths.
final class MockTransport: LocalTransport, @unchecked Sendable {
    struct Route {
        var status: Int
        var body: Data
        var delay: TimeInterval
    }

    private let lock = NSLock()
    private var routes: [String: Route] = [:]
    private var liveOrigins: Set<String> = []
    private var recorded: [LocalHTTPRequest] = []

    /// Registers a JSON (or raw text) answer. `body` narrows a POST route to one exact request body.
    func on(_ method: String = "GET", _ url: String, body: String? = nil, status: Int = 200, json: String,
            delay: TimeInterval = 0) {
        lock.lock()
        defer { lock.unlock() }
        let key = body.map { "\(method) \(url) \($0)" } ?? "\(method) \(url)"
        routes[key] = Route(status: status, body: Data(json.utf8), delay: delay)
        if let origin = Self.origin(of: url) { liveOrigins.insert(origin) }
    }

    /// Marks a host:port as accepting connections (every path answers 404 unless routed).
    func live(_ origin: String) {
        lock.lock()
        liveOrigins.insert(origin)
        lock.unlock()
    }

    var requests: [LocalHTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func requestCount(containing fragment: String) -> Int {
        requests.filter { $0.url.absoluteString.contains(fragment) }.count
    }

    static func origin(of url: String) -> String? {
        guard let comps = URLComponents(string: url), let scheme = comps.scheme, let host = comps.host else { return nil }
        let port = comps.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    private func record(_ request: LocalHTTPRequest) -> (Route?, Bool) {
        let urlString = request.url.absoluteString
        let key = "\(request.method) \(urlString)"
        let bodyKey = request.body.map { "\(key) \(String(decoding: $0, as: UTF8.self))" }
        lock.lock()
        defer { lock.unlock() }
        recorded.append(request)
        let match = bodyKey.flatMap { routes[$0] } ?? routes[key]
        return (match, liveOrigins.contains(Self.origin(of: urlString) ?? ""))
    }

    func send(_ request: LocalHTTPRequest) async throws -> LocalHTTPResponse {
        let urlString = request.url.absoluteString
        let (route, isLive) = record(request)
        guard isLive else { throw LocalTransportError.connectionFailed("connection refused: \(urlString)") }
        guard let route else { return LocalHTTPResponse(status: 404, data: Data("not found".utf8)) }
        if route.delay > 0 { try await Task.sleep(nanoseconds: UInt64(route.delay * 1_000_000_000)) }
        return LocalHTTPResponse(status: route.status, data: route.body)
    }
}
