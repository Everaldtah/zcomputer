import Foundation
import XCTest
import ZCore
@testable import ZVM

/// In-memory agent connection: every complete request line written is answered by `responder` (raw response
/// lines). Responses are delivered in chunks of `chunkSize` bytes to exercise the framing.
final class FakeAgentConnection: GuestAgentConnection, @unchecked Sendable {
    typealias Responder = @Sendable (JSONValue) -> [String]

    private let lock = NSLock()
    private var inbound = Data()
    private var outbound = Data()
    private var closed = false
    private var received: [JSONValue] = []
    private let responder: Responder
    private let chunkSize: Int

    init(chunkSize: Int = 7, responder: @escaping Responder) {
        self.chunkSize = chunkSize
        self.responder = responder
    }

    var requests: [JSONValue] {
        lock.lock(); defer { lock.unlock() }
        return received
    }

    var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    func write(_ data: Data) async throws {
        var lines: [Data] = []
        lock.lock()
        if closed { lock.unlock(); throw GuestAgentError(code: .transport, message: "closed") }
        inbound.append(data)
        while let nl = inbound.firstIndex(of: 0x0A) {
            lines.append(Data(inbound[inbound.startIndex..<nl]))
            inbound = Data(inbound[(nl + 1)...])
        }
        lock.unlock()
        for line in lines {
            let request = (try? JSONValue.parse(line)) ?? .null
            let answers = responder(request)
            lock.lock()
            received.append(request)
            for answer in answers { outbound.append(Data((answer + "\n").utf8)) }
            lock.unlock()
        }
    }

    func read(maxLength: Int) async throws -> Data {
        while true {
            lock.lock()
            if !outbound.isEmpty {
                let n = min(maxLength, chunkSize, outbound.count)
                let chunk = Data(outbound.prefix(n))
                outbound = Data(outbound.dropFirst(n))
                lock.unlock()
                return chunk
            }
            let isClosed = closed
            lock.unlock()
            if isClosed { return Data() }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func close() {
        lock.lock(); closed = true; lock.unlock()
    }
}

/// Counts connections handed out by a connector.
final class ConnectionFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [FakeAgentConnection] = []
    let responder: FakeAgentConnection.Responder

    init(responder: @escaping FakeAgentConnection.Responder) { self.responder = responder }

    var connections: [FakeAgentConnection] {
        lock.lock(); defer { lock.unlock() }
        return made
    }

    var connector: GuestAgentConnector {
        { [self] in
            let c = FakeAgentConnection(responder: responder)
            lock.lock(); made.append(c); lock.unlock()
            return c
        }
    }
}

private func id(of request: JSONValue) -> String { request["id"]?.stringValue ?? "" }

final class JSONLineFramerTests: XCTestCase {
    func testSplitsLinesAcrossChunks() throws {
        var framer = JSONLineFramer()
        XCTAssertEqual(try framer.append(Data("{\"a\":".utf8)), [])
        let lines = try framer.append(Data("1}\r\n\n{\"b\":2}\n{\"c\"".utf8))
        XCTAssertEqual(lines.map { String(decoding: $0, as: UTF8.self) }, ["{\"a\":1}", "{\"b\":2}"])
        XCTAssertEqual(framer.bufferedByteCount, 4)
        XCTAssertEqual(try framer.append(Data(":3}\n".utf8)).map { String(decoding: $0, as: UTF8.self) }, ["{\"c\":3}"])
        XCTAssertNil(framer.flush())
    }

    func testFlushReturnsUnterminatedLine() throws {
        var framer = JSONLineFramer()
        XCTAssertEqual(try framer.append(Data("{\"x\":1}".utf8)), [])
        XCTAssertEqual(framer.flush().map { String(decoding: $0, as: UTF8.self) }, "{\"x\":1}")
    }

    func testRejectsOverlongLines() {
        var framer = JSONLineFramer(maxLineLength: 16)
        XCTAssertThrowsError(try framer.append(Data(repeating: 0x41, count: 32))) { error in
            XCTAssertEqual((error as? GuestAgentError)?.code, .tooLarge)
        }
    }

    func testRequestEncoding() throws {
        let data = try GuestAgentWire.encodeRequest(id: "7", op: "exec", params: ["cmd": "ls /", "timeout_ms": 5000])
        XCTAssertEqual(data.last, 0x0A)
        let value = try JSONValue.parse(Data(data.dropLast()))
        XCTAssertEqual(value["id"], "7")
        XCTAssertEqual(value["op"], "exec")
        XCTAssertEqual(value["cmd"], "ls /")
        XCTAssertEqual(value["timeout_ms"]?.intValue, 5000)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\\/"), "slashes must not be escaped")
    }

    func testInputActionJSON() {
        XCTAssertEqual(AgentInputAction.click(x: 10, y: 20, button: .right, count: 2).json,
                       ["type": "click", "x": 10, "y": 20, "button": "right", "count": 2])
        XCTAssertEqual(AgentInputAction.doubleClick(x: nil, y: nil).json, ["type": "double_click"])
        XCTAssertEqual(AgentInputAction.drag(x: 1, y: 2, toX: 3, toY: 4).json,
                       ["type": "drag", "x": 1, "y": 2, "to_x": 3, "to_y": 4])
        XCTAssertEqual(AgentInputAction.scroll(x: nil, y: nil, dx: 0, dy: -3).json, ["type": "scroll", "dx": 0, "dy": -3])
        XCTAssertEqual(AgentInputAction.type("héllo").json, ["type": "type", "text": "héllo"])
        XCTAssertEqual(AgentInputAction.key("ctrl+a Delete").json, ["type": "key", "key": "ctrl+a Delete"])
        XCTAssertEqual(AgentInputAction.mouseDown(x: 5, y: 6, button: .middle).json,
                       ["type": "mouse_down", "x": 5, "y": 6, "button": "middle"])
    }
}

final class GuestAgentClientTests: XCTestCase {
    func testPingAndSysinfoDecode() async throws {
        let factory = ConnectionFactory { req in
            switch req["op"]?.stringValue {
            case "ping":
                return [#"{"id":"\#(id(of: req))","ok":true,"version":"0.1.0","protocol":1,"uptime":12.345,"ops":["exec","ping","screenshot"],"future_field":true}"#]
            case "sysinfo":
                return [#"{"id":"\#(id(of: req))","ok":true,"version":"0.1.0","hostname":"vm","os":"Debian GNU/Linux 13 (trixie)","osId":"debian","osVersion":"13","kernel":"6.12.0","arch":"aarch64","cpus":4,"memTotal":4294967296,"memFree":3000000000,"uptime":42.5,"agentUser":"root","display":{"wayland":false,"x11":true,"type":"x11","user":"z","uid":1000,"session":"2","desktop":"XFCE","source":"loginctl","env":{"DISPLAY":":0"}},"tools":{"xdotool":true,"grim":false}}"#]
            default:
                return []
            }
        }
        let client = GuestAgentClient(connector: factory.connector)
        let ping = try await client.ping()
        XCTAssertEqual(ping.version, "0.1.0")
        XCTAssertEqual(ping.protocolVersion, 1)
        XCTAssertEqual(ping.uptime, 12.345, accuracy: 0.0001)
        XCTAssertTrue(ping.supports("screenshot"))
        XCTAssertFalse(ping.supports("input"))

        let info = try await client.sysinfo()
        XCTAssertEqual(info.arch, "aarch64")
        XCTAssertEqual(info.memTotal, 4_294_967_296)
        XCTAssertEqual(info.display?.type, "x11")
        XCTAssertEqual(info.display?.env["DISPLAY"], ":0")
        XCTAssertTrue(info.has("xdotool"))
        XCTAssertFalse(info.has("grim"))

        // Both requests reused one pooled connection.
        XCTAssertEqual(factory.connections.count, 1)
        XCTAssertEqual(factory.connections.first?.requests.map { $0["op"]?.stringValue ?? "" }, ["ping", "sysinfo"])
        let isReachable = await client.isReachable()
        XCTAssertTrue(isReachable)
    }

    func testExecRequestAndResult() async throws {
        let factory = ConnectionFactory { req in
            [#"{"id":"\#(id(of: req))","ok":true,"stdout":"hi\n","stderr":"warn\n","exit_code":3,"timed_out":false,"truncated":false,"stdout_truncated":false,"stderr_truncated":false,"duration_ms":1500,"shell":"bash"}"#]
        }
        let client = GuestAgentClient(connector: factory.connector)
        let result = try await client.exec("echo hi; exit 3", timeout: 5, cwd: "/tmp", env: ["A": "1"], stdin: "in", desktop: true)
        XCTAssertEqual(result.stdout, "hi\n")
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.shell, "bash")
        let shell = result.shellResult
        XCTAssertEqual(shell.exitCode, 3)
        XCTAssertEqual(shell.stderr, "warn\n")
        XCTAssertEqual(shell.durationSeconds, 1.5, accuracy: 0.001)

        let sent = try XCTUnwrap(factory.connections.first?.requests.first)
        XCTAssertEqual(sent["op"], "exec")
        XCTAssertEqual(sent["cmd"], "echo hi; exit 3")
        XCTAssertEqual(sent["timeout_ms"]?.intValue, 5000)
        XCTAssertEqual(sent["cwd"], "/tmp")
        XCTAssertEqual(sent["env"], ["A": "1"])
        XCTAssertEqual(sent["stdin"], "in")
        XCTAssertEqual(sent["desktop"], true)
    }

    func testAgentErrorsCarryTheirCode() async throws {
        let factory = ConnectionFactory { req in
            [#"{"id":"\#(id(of: req))","ok":false,"error":"open /nope: no such file or directory","code":"not_found"}"#]
        }
        let client = GuestAgentClient(connector: factory.connector)
        do {
            _ = try await client.readFile(path: "/nope")
            XCTFail("expected an error")
        } catch let error as GuestAgentError {
            XCTAssertEqual(error.code, .notFound)
            XCTAssertEqual(error.message, "open /nope: no such file or directory")
            XCTAssertEqual(error.zError, .notFound("open /nope: no such file or directory"))
        }
        // An ok:false answer keeps the connection in sync, so it is reused.
        _ = try? await client.readFile(path: "/nope")
        XCTAssertEqual(factory.connections.count, 1)
    }

    func testMismatchedIDIsAProtocolError() async throws {
        let factory = ConnectionFactory { _ in [#"{"id":"999","ok":true,"version":"x","protocol":1,"uptime":0,"ops":[]}"#] }
        let client = GuestAgentClient(connector: factory.connector)
        do {
            _ = try await client.ping()
            XCTFail("expected an error")
        } catch let error as GuestAgentError {
            XCTAssertEqual(error.code, .protocolError)
        }
        XCTAssertEqual(factory.connections.first?.isClosed, true, "an out-of-sync connection must be dropped")
    }

    func testFilesAndBase64() async throws {
        let payload = Data((0..<300).map { UInt8($0 % 256) })
        let factory = ConnectionFactory { req in
            switch req["op"]?.stringValue {
            case "read_file":
                return [#"{"id":"\#(id(of: req))","ok":true,"path":"/etc/x","data_b64":"\#(payload.base64EncodedString())","size":300,"truncated":false}"#]
            case "write_file":
                let n = Data(base64Encoded: req["data_b64"]?.stringValue ?? "")?.count ?? -1
                return [#"{"id":"\#(id(of: req))","ok":true,"path":"/tmp/y","written":\#(n),"size":\#(n)}"#]
            case "list_dir":
                return [#"{"id":"\#(id(of: req))","ok":true,"path":"/","entries":[{"name":"bin","isDir":true,"isSymlink":true,"size":7,"mode":"Lrwxrwxrwx","mtime":1700000000}],"truncated":false}"#]
            default:
                return []
            }
        }
        let client = GuestAgentClient(connector: factory.connector)
        let read = try await client.readWholeFile(path: "/etc/x")
        XCTAssertEqual(read, payload)

        let written = try await client.writeFile(path: "/tmp/y", data: payload, mode: "0755", mkdir: true)
        XCTAssertEqual(written.written, 300)
        let request = try XCTUnwrap(factory.connections.first?.requests.last)
        XCTAssertEqual(request["mode"], "0755")
        XCTAssertEqual(request["mkdir"], true)
        XCTAssertEqual(Data(base64Encoded: request["data_b64"]?.stringValue ?? ""), payload)

        let listing = try await client.listDir(path: "/")
        XCTAssertEqual(listing.entries.first?.name, "bin")
        XCTAssertEqual(listing.entries.first?.isSymlink, true)
    }

    func testScreenshotAndInput() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let factory = ConnectionFactory { req in
            switch req["op"]?.stringValue {
            case "screenshot":
                return [#"{"id":"\#(id(of: req))","ok":true,"png_b64":"\#(png.base64EncodedString())","width":1280,"height":800,"tool":"scrot","session":"x11"}"#]
            case "input":
                let n = req["actions"]?.arrayValue?.count ?? 0
                return [#"{"id":"\#(id(of: req))","ok":true,"backend":"xdotool","performed":\#(n)}"#]
            default:
                return []
            }
        }
        let client = GuestAgentClient(connector: factory.connector)
        let shot = try await client.screenshot()
        XCTAssertEqual(shot.png, png)
        XCTAssertEqual(shot.width, 1280)
        XCTAssertEqual(shot.tool, "scrot")

        let result = try await client.input([.click(x: 1, y: 2), .type("ü"), .key("Return")])
        XCTAssertEqual(result.performed, 3)
        let sent = try XCTUnwrap(factory.connections.first?.requests.last)
        XCTAssertEqual(sent["actions"]?[1], ["type": "type", "text": "ü"])
    }

    func testConcurrentRequestsUseSeparateConnections() async throws {
        let factory = ConnectionFactory { req in
            [#"{"id":"\#(id(of: req))","ok":true,"version":"v","protocol":1,"uptime":1,"ops":[]}"#]
        }
        let client = GuestAgentClient(connector: factory.connector, maxIdleConnections: 4)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { _ = try await client.ping() }
            }
            try await group.waitForAll()
        }
        let count = factory.connections.count
        XCTAssertGreaterThanOrEqual(count, 1)
        XCTAssertLessThanOrEqual(count, 4)
        XCTAssertEqual(factory.connections.reduce(0) { $0 + $1.requests.count }, 4)
    }

    func testTimeoutClosesTheConnection() async throws {
        let factory = ConnectionFactory { _ in [] }   // never answers
        let client = GuestAgentClient(connector: factory.connector)
        let started = Date()
        do {
            _ = try await client.ping(timeout: 0.3)
            XCTFail("expected a timeout")
        } catch let error as GuestAgentError {
            XCTAssertEqual(error.code, .timeout)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(factory.connections.first?.isClosed, true)
        let reachable = await client.isReachable()
        XCTAssertFalse(reachable)
    }

    func testConnectFailureIsATransportError() async throws {
        let client = GuestAgentClient(connector: { throw ZError.vm("not running") })
        do {
            _ = try await client.ping()
            XCTFail("expected an error")
        } catch let error as GuestAgentError {
            XCTAssertEqual(error.code, .transport)
        }
    }
}
