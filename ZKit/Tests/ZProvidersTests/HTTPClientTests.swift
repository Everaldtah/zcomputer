import Foundation
import XCTest
import ZCore
@testable import ZProviders

final class HTTPClientTests: XCTestCase {
    let url = testURL("https://api.example.com/v1/chat/completions")

    func client(_ transport: MockTransport, _ sleeps: SleepRecorder, maxRetries: Int = 2,
                logger: (@Sendable (HTTPLogEntry) -> Void)? = nil) -> HTTPClient {
        HTTPClient(transport: transport, retry: RetryPolicy(maxRetries: maxRetries, baseDelay: 0.5, maxDelay: 4),
                   sleep: { sleeps.record($0) }, logger: logger)
    }

    func testRetries429HonouringRetryAfter() async throws {
        let transport = MockTransport()
        transport.enqueue(status: 429, headers: ["Retry-After": "2"], body: #"{"error":{"message":"slow down"}}"#)
        transport.enqueue(status: 200, body: #"{"ok":true}"#)
        let sleeps = SleepRecorder()
        let json = try await client(transport, sleeps).postJSON(url, body: ["a": 1])
        XCTAssertEqual(json["ok"], true)
        XCTAssertEqual(sleeps.delays, [2])
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests[0].header("content-type"), "application/json")
        XCTAssertEqual(transport.requests[0].jsonBody, ["a": 1])
    }

    func testRetries5xxWithBackoff() async throws {
        let transport = MockTransport()
        transport.enqueue(status: 503, body: "upstream unavailable")
        transport.enqueue(status: 502, body: "bad gateway")
        transport.enqueue(status: 200, body: "{}")
        let sleeps = SleepRecorder()
        _ = try await client(transport, sleeps).send(HTTPRequest(url: url))
        XCTAssertEqual(sleeps.delays.count, 2)
        XCTAssertTrue((0.4...0.6).contains(sleeps.delays[0]), "\(sleeps.delays)")
        XCTAssertTrue((0.8...1.2).contains(sleeps.delays[1]), "\(sleeps.delays)")
    }

    func testRetryAfterMilliseconds() async throws {
        let transport = MockTransport()
        transport.enqueue(status: 429, headers: ["retry-after-ms": "1500"], body: "{}")
        transport.enqueue(status: 200, body: "{}")
        let sleeps = SleepRecorder()
        _ = try await client(transport, sleeps).send(HTTPRequest(url: url))
        XCTAssertEqual(sleeps.delays, [1.5])
    }

    func testAuthErrorIsNotRetriedAndCarriesProviderMessage() async {
        let transport = MockTransport()
        transport.enqueue(status: 401, body: #"{"error":{"message":"Incorrect API key provided","type":"invalid_request_error","code":"invalid_api_key"}}"#)
        let sleeps = SleepRecorder()
        let error = await caughtError { _ = try await self.client(transport, sleeps).send(HTTPRequest(url: self.url)) }
        XCTAssertEqual(error as? ZError, .http(status: 401, body: "invalid_api_key: Incorrect API key provided"))
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(sleeps.delays, [])
    }

    func testRateLimitAfterRetriesAreExhausted() async {
        let transport = MockTransport()
        for _ in 0..<3 { transport.enqueue(status: 429, headers: ["retry-after": "1"], body: "{}") }
        let sleeps = SleepRecorder()
        let error = await caughtError { _ = try await self.client(transport, sleeps).send(HTTPRequest(url: self.url)) }
        XCTAssertEqual(error as? ZError, .rateLimited(retryAfter: 1))
        XCTAssertEqual(sleeps.delays, [1, 1])
        XCTAssertEqual(transport.requests.count, 3)
    }

    func testQuotaExhaustionIsNotRetried() async {
        let transport = MockTransport()
        transport.enqueue(status: 429, body: #"{"error":{"message":"You exceeded your current quota, please check your plan and billing details.","type":"insufficient_quota","code":"insufficient_quota"}}"#)
        let sleeps = SleepRecorder()
        let error = await caughtError { _ = try await self.client(transport, sleeps).send(HTTPRequest(url: self.url)) }
        guard case ZError.http(let status, let body)? = error as? ZError else { return XCTFail("\(String(describing: error))") }
        XCTAssertEqual(status, 429)
        XCTAssertTrue(body.contains("exceeded your current quota"))
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testLongRetryAfterIsReturnedNotAwaited() async {
        let transport = MockTransport()
        transport.enqueue(status: 429, headers: ["retry-after": "120"], body: "{}")
        let sleeps = SleepRecorder()
        let error = await caughtError { _ = try await self.client(transport, sleeps).send(HTTPRequest(url: self.url)) }
        XCTAssertEqual(error as? ZError, .rateLimited(retryAfter: 120))
        XCTAssertEqual(sleeps.delays, [])
    }

    func testStreamRetriesOnHeadThenReturnsBody() async throws {
        let transport = MockTransport()
        transport.enqueue(status: 500, body: #"{"error":{"message":"internal"}}"#)
        transport.enqueue(status: 200, body: "data: one\n\ndata: two\n\n", chunkSize: 5)
        let sleeps = SleepRecorder()
        let body = try await client(transport, sleeps).stream(HTTPRequest(url: url))
        var parser = SSEParser()
        var events: [SSEEvent] = []
        for try await chunk in body { events += parser.feed(chunk) }
        XCTAssertEqual(events.map(\.data), ["one", "two"])
        XCTAssertEqual(sleeps.delays.count, 1)
    }

    func testStreamErrorBodyIsMapped() async {
        let transport = MockTransport()
        transport.enqueue(status: 400, body: #"{"type":"error","error":{"type":"invalid_request_error","message":"max_tokens: too large"}}"#)
        let sleeps = SleepRecorder()
        let error = await caughtError { _ = try await self.client(transport, sleeps).stream(HTTPRequest(url: self.url)) }
        XCTAssertEqual(error as? ZError, .http(status: 400, body: "invalid_request_error: max_tokens: too large"))
    }

    func testNetworkErrorsAreRetriedThenReported() async {
        let transport = MockTransport()   // nothing queued: every attempt is a network error
        let sleeps = SleepRecorder()
        let error = await caughtError { _ = try await self.client(transport, sleeps, maxRetries: 1).send(HTTPRequest(url: self.url)) }
        guard case ZError.network? = error as? ZError else { return XCTFail("\(String(describing: error))") }
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testLoggerRedactsSecrets() async throws {
        let transport = MockTransport()
        transport.enqueue(status: 200, body: "{}")
        let entries = LogBox()
        let http = client(transport, SleepRecorder(), logger: { entries.append($0) })
        let keyed = testURL("https://generativelanguage.googleapis.com/v1beta/models?key=secret123")
        _ = try await http.send(HTTPRequest(url: keyed, headers: ["Authorization": "Bearer sk-secret", "Accept": "x"]))
        let all = entries.entries
        XCTAssertEqual(all.map(\.phase), [.request, .response])
        XCTAssertEqual(all[0].headers["Authorization"], "***")
        XCTAssertEqual(all[0].headers["Accept"], "x")
        XCTAssertFalse(all[0].url.contains("secret123"))
        XCTAssertEqual(all[1].status, 200)
    }
}

final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [HTTPLogEntry] = []
    func append(_ entry: HTTPLogEntry) { lock.lock(); stored.append(entry); lock.unlock() }
    var entries: [HTTPLogEntry] { lock.lock(); defer { lock.unlock() }; return stored }
}

final class ProviderErrorMapperTests: XCTestCase {
    func message(_ json: String) -> String { ProviderErrorMapper.message(from: Data(json.utf8)) }

    func testMessagesFromEveryProviderShape() {
        XCTAssertEqual(message(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#),
                       "authentication_error: invalid x-api-key")
        XCTAssertEqual(message(#"{"error":{"code":400,"message":"API key not valid.","status":"INVALID_ARGUMENT"}}"#),
                       "INVALID_ARGUMENT: API key not valid.")
        XCTAssertEqual(message(#"[{"error":{"code":429,"message":"Quota","status":"RESOURCE_EXHAUSTED"}}]"#),
                       "RESOURCE_EXHAUSTED: Quota")
        XCTAssertEqual(message(#"{"error":"model 'llama9' not found"}"#), "model 'llama9' not found")
        XCTAssertEqual(message(#"{"message":"Unauthorized"}"#), "Unauthorized")
        XCTAssertEqual(message(#"{"detail":[{"msg":"field required"},{"msg":"bad value"}]}"#), "field required; bad value")
        XCTAssertEqual(message("<html>502 Bad Gateway</html>"), "<html>502 Bad Gateway</html>")
        XCTAssertEqual(message(""), "(empty response body)")
    }

    func testRetryAfterSources() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(ProviderErrorMapper.retryAfter(headers: ["retry-after": "7"], body: Data(), now: now), 7)
        XCTAssertEqual(ProviderErrorMapper.retryAfter(headers: ["retry-after-ms": "250"], body: Data(), now: now), 0.25)
        let later = Date(timeIntervalSince1970: 1_000_030)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let header = formatter.string(from: later)
        let seconds = ProviderErrorMapper.retryAfter(headers: ["retry-after": header], body: Data(), now: now)
        XCTAssertEqual(seconds ?? -1, 30, accuracy: 1)
        let gemini = #"{"error":{"code":429,"details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"12s"}]}}"#
        XCTAssertEqual(ProviderErrorMapper.retryAfter(headers: [:], body: Data(gemini.utf8), now: now), 12)
        XCTAssertNil(ProviderErrorMapper.retryAfter(headers: [:], body: Data(), now: now))
    }

    func testStreamErrors() {
        XCTAssertEqual(ProviderErrorMapper.streamError(["type": "error", "error": ["type": "overloaded_error", "message": "Overloaded"]]),
                       .http(status: 529, body: "overloaded_error: Overloaded"))
        XCTAssertEqual(ProviderErrorMapper.streamError(["error": ["type": "rate_limit_error", "message": "slow"]]),
                       .rateLimited(retryAfter: nil))
        XCTAssertEqual(ProviderErrorMapper.streamError(["error": ["code": 400, "message": "bad", "status": "INVALID_ARGUMENT"]]),
                       .http(status: 400, body: "INVALID_ARGUMENT: bad"))
    }
}
