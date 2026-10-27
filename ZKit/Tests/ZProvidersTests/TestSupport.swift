import Foundation
import XCTest
import ZCore
@testable import ZProviders

/// Scripted transport: replies are queued in order; every request is recorded.
final class MockTransport: Transport, @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int
        var headers: [String: String]
        var chunks: [Data]
    }

    private let lock = NSLock()
    private var queue: [Reply] = []
    private var recorded: [HTTPRequest] = []

    /// Queues a reply. `chunkSize` splits the body into chunks of that many bytes (to exercise incremental parsers).
    func enqueue(status: Int = 200, headers: [String: String] = [:], body: String, chunkSize: Int? = nil) {
        let data = Data(body.utf8)
        var chunks: [Data] = []
        if let chunkSize, chunkSize > 0 {
            var start = 0
            while start < data.count {
                let end = min(start + chunkSize, data.count)
                chunks.append(data.subdata(in: start..<end))
                start = end
            }
        } else {
            chunks = [data]
        }
        lock.lock()
        queue.append(Reply(status: status, headers: headers, chunks: chunks))
        lock.unlock()
    }

    var requests: [HTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var lastRequest: HTTPRequest? { requests.last }
    var lastBody: JSONValue? { lastRequest?.jsonBody }

    private func next(_ request: HTTPRequest) throws -> Reply {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(request)
        guard !queue.isEmpty else { throw ZError.network("MockTransport: no reply queued for \(request.url)") }
        return queue.removeFirst()
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let reply = try next(request)
        var body = Data()
        for chunk in reply.chunks { body.append(chunk) }
        return HTTPResponse(status: reply.status, headers: reply.headers, body: body)
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
        let reply = try next(request)
        let chunks = reply.chunks
        let body = AsyncThrowingStream<Data, Error> { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
        return HTTPStreamResponse(status: reply.status, headers: reply.headers, body: body)
    }
}

/// Records retry sleeps instead of sleeping.
final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func record(_ seconds: Double) {
        lock.lock()
        values.append(seconds)
        lock.unlock()
    }

    var delays: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

/// What a stream produced, flattened for assertions.
struct Collected {
    var text = ""
    var reasoning = ""
    var calls: [ToolCall] = []
    var starts: [(id: String, name: String)] = []
    var deltas: [(id: String, delta: String)] = []
    var usage: Usage?
    var finish: FinishReason?
    var eventCount = 0
}

func collect(_ stream: AsyncThrowingStream<StreamEvent, Error>) async throws -> Collected {
    var c = Collected()
    for try await event in stream {
        c.eventCount += 1
        switch event {
        case .textDelta(let d): c.text += d
        case .reasoningDelta(let d): c.reasoning += d
        case .toolCallStart(let id, let name): c.starts.append((id, name))
        case .toolCallDelta(let id, let delta): c.deltas.append((id, delta))
        case .toolCall(let call): c.calls.append(call)
        case .usage(let u): c.usage = u
        case .finished(let f): c.finish = f
        }
    }
    return c
}

/// Runs `body` and returns the error it throws (fails the test when it does not throw).
func caughtError(file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void) async -> Error? {
    do {
        try await body()
        XCTFail("Expected an error", file: file, line: line)
        return nil
    } catch {
        return error
    }
}

func testURL(_ string: String) -> URL {
    URL(string: string) ?? URL(fileURLWithPath: "/invalid")
}

func testEndpoint(_ base: String, auth: AuthStyle = .bearer, key: String? = "test-key",
                  provider: ProviderID = "test") -> ProviderEndpoint {
    ProviderEndpoint(providerID: provider, baseURL: testURL(base), auth: auth, apiKey: key)
}

func testHTTP(_ transport: MockTransport, retry: RetryPolicy = .noRetries) -> HTTPClient {
    HTTPClient(transport: transport, retry: retry, sleep: { _ in })
}

/// A tiny "PNG" (only the bytes matter for encoding tests).
let testPNG = ImageData(mime: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), width: 4, height: 3)
let testPNGBase64 = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).base64EncodedString()

/// Builds an SSE body from (event, data) pairs.
func sse(_ events: [(String?, String)]) -> String {
    events.map { event, data in
        (event.map { "event: \($0)\n" } ?? "") + "data: \(data)\n\n"
    }.joined()
}

extension JSONValue {
    /// Path lookup for assertions: `json.at("messages", 1, "content")`.
    func at(_ path: Any...) -> JSONValue? {
        var current: JSONValue? = self
        for component in path {
            if let key = component as? String { current = current?[key] }
            else if let index = component as? Int { current = current?[index] }
            else { return nil }
        }
        return current
    }
}
