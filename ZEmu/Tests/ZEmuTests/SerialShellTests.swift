import Foundation
import XCTest
import ZCore
@testable import ZEmu

/// A pretend serial console with a shell: echoes what is typed (like a tty), and for our command lines prints the
/// BEGIN marker, the command's canned output and the END marker with an exit status. With `requireLogin`, a getty
/// asks for a login first.
final class FakeShellConsole: EmuSerialTransport, @unchecked Sendable {
    private let broadcaster = EmuBroadcaster<Data>()
    private let lock = NSLock()
    private var pending = ""
    private var staged: [String: String] = [:]
    private var commands: [String] = []
    private var loginState: Int
    private let handler: @Sendable (String) -> (output: String, status: Int)

    init(requireLogin: Bool = false, handler: @escaping @Sendable (String) -> (output: String, status: Int)) {
        self.handler = handler
        self.loginState = requireLogin ? 0 : 3
    }

    var executed: [String] {
        lock.lock(); defer { lock.unlock() }
        return commands
    }

    func output(replay: Bool) -> AsyncStream<Data> { broadcaster.stream() }

    func write(_ data: Data) {
        lock.lock()
        pending += String(decoding: data, as: UTF8.self)
        var lines: [String] = []
        while let nl = pending.firstIndex(of: "\n") {
            lines.append(String(pending[..<nl]))
            pending = String(pending[pending.index(after: nl)...])
        }
        lock.unlock()
        for line in lines { respond(to: line) }
    }

    private func emit(_ text: String) { broadcaster.yield(Data(text.utf8)) }

    private func respond(to line: String) {
        lock.lock()
        let state = loginState
        lock.unlock()
        if state < 3 {
            switch state {
            case 0:     // getty waiting: anything typed shows the prompt again, a user name asks for the password
                if line.isEmpty || line.contains("echo") {
                    emit("\r\nWelcome to Fake Linux\r\nfake login: ")
                } else {
                    emit(line + "\r\nPassword: ")
                    lock.lock(); loginState = line == "root" ? 1 : 2; lock.unlock()
                }
            case 1:
                if line == "secret" {
                    emit("\r\nWelcome!\r\nfake:~# ")
                    lock.lock(); loginState = 3; lock.unlock()
                } else {
                    emit("\r\nLogin incorrect\r\nfake login: ")
                    lock.lock(); loginState = 0; lock.unlock()
                }
            default:
                emit("\r\nLogin incorrect\r\nfake login: ")
                lock.lock(); loginState = 0; lock.unlock()
            }
            return
        }
        emit(line + "\r\n")                                    // tty echo
        if let ack = Self.capture(line, after: "echo \"__Z\"\"K_", before: "__\"") {
            if let chunk = Self.capture(line, after: "printf %s '", before: "' >>"),
               let file = Self.capture(line, after: ">> ", before: ";") {
                lock.lock(); staged[file, default: ""] += chunk; lock.unlock()
            }
            emit("__ZK_\(ack)__\r\n# ")
            return
        }
        if let rnonce = Self.capture(line, after: "echo \"__Z\"\"R_", before: "__\"") {
            emit("__ZR_\(rnonce)__\r\n# ")
            return
        }
        guard let nonce = Self.capture(line, after: "\"__Z\"\"B_", before: "__\"") else {
            emit("# ")
            return
        }
        var payload = Self.capture(line, after: "printf %s '", before: "' | base64 -d")
        if payload == nil, let file = Self.capture(line, after: "base64 -d ", before: " > ") {
            lock.lock(); payload = staged[file]; lock.unlock()
        }
        let command = payload.flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
        lock.lock(); commands.append(command); lock.unlock()
        let (output, status) = handler(command)
        let body = output.replacingOccurrences(of: "\n", with: "\r\n")
        emit("__ZB_\(nonce)__\r\n" + body + "__ZE_\(nonce)_\(status)__\r\n# ")
    }

    static func capture(_ s: String, after start: String, before end: String) -> String? {
        guard let a = s.range(of: start), let b = s.range(of: end, range: a.upperBound..<s.endIndex) else { return nil }
        return String(s[a.upperBound..<b.lowerBound])
    }
}

final class SerialShellTests: XCTestCase {
    func testParseIgnoresEchoAndNormalisesLineEnds() {
        let markers = EmuSerialShell.Markers(nonce: "n1")
        let echo = "Z_SH=$(command -v bash); printf '%s\\n' \"__Z\"\"B_n1__\"; ...; echo \"__Z\"\"E_n1_$?__\"\r\n"
        let text = echo + "__ZB_n1__\r\nline one\r\nline two\r\n__ZE_n1_7__\r\n$ "
        let parsed = EmuSerialShell.parseOutput(text, markers: markers)
        XCTAssertEqual(parsed?.output, "line one\nline two\n")
        XCTAssertEqual(parsed?.exitCode, 7)
        XCTAssertEqual(parsed?.consumedUTF8, text.utf8.count - "\r\n$ ".utf8.count)
    }

    func testParseWaitsForTheCompleteEndMarker() {
        let markers = EmuSerialShell.Markers(nonce: "q")
        XCTAssertNil(EmuSerialShell.parseOutput("__ZB_q__\r\npartial", markers: markers))
        XCTAssertNil(EmuSerialShell.parseOutput("__ZB_q__\r\nout\r\n__ZE_q_1", markers: markers))
        XCTAssertNil(EmuSerialShell.parseOutput("__ZE_q_0__", markers: markers), "END without BEGIN")
        let parsed = EmuSerialShell.parseOutput("__ZB_q__\nno newline__ZE_q_0__", markers: markers)
        XCTAssertEqual(parsed?.output, "no newline")
        XCTAssertEqual(parsed?.exitCode, 0)
        XCTAssertNil(EmuSerialShell.parseOutput("__ZB_q2__\nx__ZE_q2_0__", markers: markers))
    }

    func testTypedLinesNeverContainTheMarkers() {
        let payload = Data("echo 'quoted' \"double\" $HOME\nsecond line".utf8).base64EncodedString()
        let lines = EmuSerialShell.typedLines(payload: payload, nonce: "abc")
        XCTAssertEqual(lines.count, 1)
        XCTAssertFalse(lines[0].contains("__ZB_abc__"))
        XCTAssertFalse(lines[0].contains("__ZE_abc_"))
        XCTAssertTrue(lines[0].contains(payload))
        XCTAssertLessThanOrEqual(lines[0].utf8.count, EmuSerialShell.maxTypedLine)
    }

    func testLongCommandsAreStagedInChunks() {
        let payload = String(repeating: "QUJD", count: 2000)
        let lines = EmuSerialShell.typedLines(payload: payload, nonce: "big")
        XCTAssertEqual(lines.count, 1 + 4 + 1)
        for (i, line) in lines.dropLast().enumerated() {
            XCTAssertTrue(line.contains("echo \"__Z\"\"K_big_\(i)__\""), line)
            XCTAssertLessThanOrEqual(line.utf8.count, EmuSerialShell.maxTypedLine)
        }
        XCTAssertTrue(lines.last?.contains("base64 -d /tmp/.zser_big") ?? false)
    }

    func testRunThroughFakeConsole() async throws {
        let console = FakeShellConsole { command in
            switch command {
            case "uname -m": return ("i686\n", 0)
            case "false": return ("", 1)
            default: return ("ran: \(command.count) bytes\n", 0)
            }
        }
        let shell = EmuSerialShell(transport: console)
        await shell.start()
        let probe = await shell.probe(timeout: 2)
        XCTAssertTrue(probe)
        let r1 = try await shell.run("uname -m", timeout: 5)
        XCTAssertEqual(r1.stdout, "i686\n")
        XCTAssertEqual(r1.exitCode, 0)
        let r2 = try await shell.run("false", timeout: 5)
        XCTAssertEqual(r2.exitCode, 1)
        let long = String(repeating: "echo 'long command'; ", count: 400)
        let r3 = try await shell.run(long, timeout: 10)
        XCTAssertEqual(r3.stdout, "ran: \(long.count) bytes\n")
        XCTAssertEqual(console.executed, ["uname -m", "false", long])
    }

    /// Operations started at the same time (the clock sync after a restore and the agent's first command) take
    /// turns on the one console line instead of clearing each other's output.
    func testConcurrentOperationsTakeTurns() async throws {
        let console = FakeShellConsole { command in ("out:\(command)\n", 0) }
        let shell = EmuSerialShell(transport: console)
        await shell.start()
        async let first = shell.run("one", timeout: 5)
        async let probe = shell.probe(timeout: 5)
        async let second = shell.run("two", timeout: 5)
        async let third = shell.run(String(repeating: "x", count: 5000), timeout: 10)
        let (r1, answered, r2, r3) = try await (first, probe, second, third)
        XCTAssertEqual(r1.stdout, "out:one\n")
        XCTAssertTrue(answered)
        XCTAssertEqual(r2.stdout, "out:two\n")
        XCTAssertEqual(r3.stdout, "out:" + String(repeating: "x", count: 5000) + "\n")
        XCTAssertEqual(Set(console.executed), ["one", "two", String(repeating: "x", count: 5000)])
    }

    func testLoginDetectionAtAGetty() async throws {
        let console = FakeShellConsole(requireLogin: true) { _ in ("ok\n", 0) }
        let shell = EmuSerialShell(transport: console)
        await shell.start()
        let early = await shell.probe(timeout: 1)
        XCTAssertFalse(early, "nothing answers at a login prompt")
        try await shell.login(user: "root", password: "secret", timeout: 20)
        let ready = await shell.isReady
        XCTAssertTrue(ready)
        let r = try await shell.run("whoami", timeout: 5)
        XCTAssertEqual(r.stdout, "ok\n")
    }

    func testWrongPasswordIsReported() async throws {
        let console = FakeShellConsole(requireLogin: true) { _ in ("", 0) }
        let shell = EmuSerialShell(transport: console)
        do {
            try await shell.login(user: "root", password: "wrong", timeout: 15)
            XCTFail("expected a login failure")
        } catch {
            XCTAssertTrue("\(error)".contains("login incorrect") || "\(error)".contains("no login prompt"), "\(error)")
        }
    }

    func testRunTimesOut() async throws {
        final class SilentConsole: EmuSerialTransport, @unchecked Sendable {
            let broadcaster = EmuBroadcaster<Data>()
            func output(replay: Bool) -> AsyncStream<Data> { broadcaster.stream() }
            func write(_ data: Data) {}
        }
        let shell = EmuSerialShell(transport: SilentConsole())
        do {
            _ = try await shell.run("sleep 100", timeout: 0.3)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertTrue("\(error)".contains("did not finish"), "\(error)")
        }
    }

    func testConsoleScrollbackAndReplay() async throws {
        let console = EmuConsole(scrollbackLimit: 8)
        console.publish(Data("0123456789".utf8))
        XCTAssertEqual(String(decoding: console.recentOutput, as: UTF8.self), "23456789")
        let stream = console.output(replay: true)
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first.map { String(decoding: $0, as: UTF8.self) }, "23456789")
        console.publish(Data("ab".utf8))
        let second = await iterator.next()
        XCTAssertEqual(second.map { String(decoding: $0, as: UTF8.self) }, "ab")
    }
}
