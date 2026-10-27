import Foundation
import XCTest
import ZCore
@testable import ZVM

/// A pretend serial console with a logged-in shell: echoes what is typed (like a tty), and for our command lines
/// prints the BEGIN marker, the command's canned output and the END marker with an exit status.
final class FakeShellConsole: SerialTransport, @unchecked Sendable {
    private let broadcaster = Broadcaster<Data>()
    private let lock = NSLock()
    private var pending = ""
    private var staged: [String: String] = [:]
    private var commands: [String] = []
    private let handler: @Sendable (String) -> (output: String, status: Int)

    init(handler: @escaping @Sendable (String) -> (output: String, status: Int)) { self.handler = handler }

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
        emit(line + "\r\n")                                    // tty echo
        if let ack = Self.capture(line, after: "echo \"__Z\"\"K_", before: "__\"") {
            // Staging line: printf %s '<chunk>' >> file
            if let chunk = Self.capture(line, after: "printf %s '", before: "' >>"),
               let file = Self.capture(line, after: ">> ", before: ";") {
                lock.lock(); staged[file, default: ""] += chunk; lock.unlock()
            }
            emit("__ZK_\(ack)__\r\n$ ")
            return
        }
        if let rnonce = Self.capture(line, after: "echo \"__Z\"\"R_", before: "__\"") {
            emit("__ZR_\(rnonce)__\r\n$ ")
            return
        }
        guard let nonce = Self.capture(line, after: "\"__Z\"\"B_", before: "__\"") else {
            emit("$ ")
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
        emit("__ZB_\(nonce)__\r\n" + body + "__ZE_\(nonce)_\(status)__\r\n$ ")
    }

    static func capture(_ s: String, after start: String, before end: String) -> String? {
        guard let a = s.range(of: start), let b = s.range(of: end, range: a.upperBound..<s.endIndex) else { return nil }
        return String(s[a.upperBound..<b.lowerBound])
    }
}

final class SerialShellTests: XCTestCase {
    func testParseIgnoresEchoAndNormalisesLineEnds() {
        let markers = SerialShell.Markers(nonce: "n1")
        let echo = "Z_SH=$(command -v bash); printf '%s\\n' \"__Z\"\"B_n1__\"; ...; echo \"__Z\"\"E_n1_$?__\"\r\n"
        let text = echo + "__ZB_n1__\r\nline one\r\nline two\r\n__ZE_n1_7__\r\n$ "
        let parsed = SerialShell.parseOutput(text, markers: markers)
        XCTAssertEqual(parsed?.output, "line one\nline two\n")
        XCTAssertEqual(parsed?.exitCode, 7)
        XCTAssertEqual(parsed?.consumedUTF8, text.utf8.count - "\r\n$ ".utf8.count)
    }

    func testParseWaitsForTheCompleteEndMarker() {
        let markers = SerialShell.Markers(nonce: "q")
        XCTAssertNil(SerialShell.parseOutput("__ZB_q__\r\npartial", markers: markers))
        XCTAssertNil(SerialShell.parseOutput("__ZB_q__\r\nout\r\n__ZE_q_1", markers: markers))
        XCTAssertNil(SerialShell.parseOutput("__ZE_q_0__", markers: markers), "END without BEGIN")
        // Output without a trailing newline ends right before the END marker.
        let parsed = SerialShell.parseOutput("__ZB_q__\nno newline__ZE_q_0__", markers: markers)
        XCTAssertEqual(parsed?.output, "no newline")
        XCTAssertEqual(parsed?.exitCode, 0)
        // A longer nonce sharing the prefix is not confused with this one.
        XCTAssertNil(SerialShell.parseOutput("__ZB_q2__\nx__ZE_q2_0__", markers: markers))
    }

    func testTypedLinesNeverContainTheMarkers() {
        let payload = Data("echo 'quoted' \"double\" $HOME\nsecond line".utf8).base64EncodedString()
        let lines = SerialShell.typedLines(payload: payload, nonce: "abc")
        XCTAssertEqual(lines.count, 1)
        let line = lines[0]
        XCTAssertFalse(line.contains("__ZB_abc__"))
        XCTAssertFalse(line.contains("__ZE_abc_"))
        XCTAssertTrue(line.contains(payload))
        XCTAssertLessThanOrEqual(line.utf8.count, SerialShell.maxTypedLine)
    }

    func testLongCommandsAreStagedInChunks() {
        let payload = String(repeating: "QUJD", count: 2000)        // 8000 base64 characters
        let lines = SerialShell.typedLines(payload: payload, nonce: "big")
        XCTAssertEqual(lines.count, 1 + 4 + 1)                       // truncate, 4 chunks of ≤2048, run
        for (i, line) in lines.dropLast().enumerated() {
            XCTAssertTrue(line.contains("echo \"__Z\"\"K_big_\(i)__\""), line)
            XCTAssertLessThanOrEqual(line.utf8.count, SerialShell.maxTypedLine)
        }
        XCTAssertEqual(lines.dropLast().joined().components(separatedBy: "printf %s '").count - 1, 4)
        XCTAssertTrue(lines.last?.contains("base64 -d /tmp/.zser_big") ?? false)
    }

    func testRunThroughFakeConsole() async throws {
        let console = FakeShellConsole { command in
            switch command {
            case "uname -m": return ("aarch64\n", 0)
            case "false": return ("", 1)
            default: return ("ran: \(command.count) bytes\n", 0)
            }
        }
        let shell = SerialShell(transport: console)
        await shell.start()

        let probe = await shell.probe(timeout: 2)
        XCTAssertTrue(probe)

        let r1 = try await shell.run("uname -m", timeout: 5)
        XCTAssertEqual(r1.stdout, "aarch64\n")
        XCTAssertEqual(r1.exitCode, 0)

        let r2 = try await shell.run("false", timeout: 5)
        XCTAssertEqual(r2.exitCode, 1)

        let long = String(repeating: "echo 'long command'; ", count: 400)   // > 3000 bytes after base64
        let r3 = try await shell.run(long, timeout: 10)
        XCTAssertEqual(r3.stdout, "ran: \(long.count) bytes\n")
        XCTAssertEqual(console.executed, ["uname -m", "false", long])
    }

    func testRunTimesOut() async throws {
        final class SilentConsole: SerialTransport, @unchecked Sendable {
            let broadcaster = Broadcaster<Data>()
            func output(replay: Bool) -> AsyncStream<Data> { broadcaster.stream() }
            func write(_ data: Data) {}
        }
        let shell = SerialShell(transport: SilentConsole())
        do {
            _ = try await shell.run("sleep 100", timeout: 0.3)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertTrue("\(error)".contains("did not finish"), "\(error)")
        }
    }
}

final class AutoProvisionerTests: XCTestCase {
    func testInstallScript() {
        let script = GuestAgentInstall.script(binaryName: "zguest-linux-arm64")
        XCTAssertTrue(script.contains("mount -t virtiofs -o ro 'zguest' '/mnt/zguest'"), script)
        XCTAssertTrue(script.contains("Z_SRC='/mnt/zguest/zguest-linux-arm64'"), script)
        XCTAssertTrue(script.contains("install -m 0755 \"$Z_SRC\" /usr/local/bin/zguest"), script)
        XCTAssertTrue(script.contains("ExecStart=/usr/local/bin/zguest"), script)
        XCTAssertTrue(script.contains("\nZGUEST_UNIT\n"), "heredoc terminator must start a line")
        XCTAssertTrue(script.contains("systemctl enable --now zguest.service"), script)
    }

    func testCommandUsesSudoForNonRootUsers() {
        let asRoot = AutoProvisioner(user: "root", password: nil, binaryName: "zguest").command()
        XCTAssertTrue(asRoot.hasPrefix("set -e"))
        let withPassword = AutoProvisioner(user: "z", password: "pa'ss", binaryName: "zguest").command()
        XCTAssertTrue(withPassword.hasPrefix("printf '%s\\n' 'pa'\\''ss' | sudo -S -p '' sh -c '"), withPassword)
        let passwordless = AutoProvisioner(user: "z", password: nil, binaryName: "zguest").command()
        XCTAssertTrue(passwordless.hasPrefix("sudo -n sh -c '"), passwordless)
    }

    func testShellQuote() {
        XCTAssertEqual(shellQuote("plain"), "'plain'")
        XCTAssertEqual(shellQuote("it's"), "'it'\\''s'")
        XCTAssertEqual(shellQuote(""), "''")
    }
}
