import Foundation
import ZCore

/// Runs shell commands through the guest's serial console (ZVM's `SerialShell` protocol, for v86's COM1). Each
/// command is typed as one line that prints a BEGIN marker, runs the command (base64-encoded, so any quoting or
/// newlines survive) and prints an END marker with the exit status:
///
///     Z_SH=...; printf '%s\n' "__Z""B_<n>__"; "$Z_SH" -c "$(printf %s '<b64>' | base64 -d)" </dev/null 2>&1; echo "__Z""E_<n>_$?__"
///
/// The markers are split by quotes in the typed text, so the terminal's echo of the command never matches them; only
/// the command's real output does. stdout and stderr arrive merged (a serial line has one stream).
public actor EmuSerialShell {
    /// Marker texts for a nonce (exactly what appears in the output).
    public struct Markers: Sendable, Hashable {
        public let begin: String
        public let endPrefix: String
        public let suffix: String

        public init(nonce: String) {
            begin = "__ZB_\(nonce)__"
            endPrefix = "__ZE_\(nonce)_"
            suffix = "__"
        }
    }

    /// Maximum typed line length; Linux canonical tty input stops at 4095 bytes per line.
    public static let maxTypedLine = 3000

    private let transport: any EmuSerialTransport
    private var buffer = Data()
    private var pump: Task<Void, Never>?
    private var counter = 0
    private let session = String(UInt32.random(in: 0x1000_0000...0xFFFF_FFFF), radix: 36)
    /// Set after a successful `login` / `probe`.
    public private(set) var isReady = false

    public init(transport: any EmuSerialTransport) {
        self.transport = transport
    }

    /// Starts collecting console output (idempotent).
    public func start() {
        guard pump == nil else { return }
        let stream = transport.output(replay: false)
        pump = Task { [weak self] in
            for await chunk in stream {
                guard let self else { return }
                await self.append(chunk)
            }
        }
    }

    public func stop() {
        pump?.cancel()
        pump = nil
        isReady = false
    }

    /// Forget the logged-in state (after a reboot or a state restore).
    public func invalidate() { isReady = false }

    private func append(_ data: Data) {
        buffer.append(data)
        let limit = 32 << 20
        if buffer.count > limit { buffer.removeFirst(buffer.count - limit) }
    }

    /// Discards collected output.
    public func clearBuffer() { buffer.removeAll(keepingCapacity: true) }

    /// Collected output as text (lossy UTF-8), for diagnostics.
    public var bufferedText: String { String(decoding: buffer, as: UTF8.self) }

    private func nextNonce() -> String {
        counter += 1
        return "\(session)x\(counter)"
    }

    // MARK: Waiting

    /// Waits until the collected output contains `needle` and returns the text up to and including it; that part
    /// is removed from the buffer.
    @discardableResult
    public func waitFor(_ needle: String, timeout: TimeInterval, caseInsensitive: Bool = false) async throws -> String {
        start()
        let deadline = Date().addingTimeInterval(timeout)
        let options: String.CompareOptions = caseInsensitive ? [.caseInsensitive] : []
        while true {
            let text = String(decoding: buffer, as: UTF8.self)
            if let r = text.range(of: needle, options: options) {
                let consumed = String(text[..<r.upperBound])
                buffer.removeFirst(min(buffer.count, consumed.utf8.count))
                return consumed
            }
            if Date() >= deadline {
                throw ZError.vm("serial console: no \"\(needle)\" within \(Int(timeout)) s")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Waits for whichever of `needles` appears first in the output; returns its index.
    public func waitForAny(_ needles: [String], timeout: TimeInterval, caseInsensitive: Bool = true) async throws -> Int {
        start()
        let deadline = Date().addingTimeInterval(timeout)
        let options: String.CompareOptions = caseInsensitive ? [.caseInsensitive] : []
        while true {
            let text = String(decoding: buffer, as: UTF8.self)
            var best: (index: Int, start: String.Index, end: String.Index)?
            for (i, n) in needles.enumerated() {
                guard let r = text.range(of: n, options: options) else { continue }
                if let current = best, current.start <= r.lowerBound { continue }
                best = (i, r.lowerBound, r.upperBound)
            }
            if let best {
                let consumed = text[..<best.end].utf8.count
                buffer.removeFirst(min(buffer.count, consumed))
                return best.index
            }
            if Date() >= deadline {
                throw ZError.vm("serial console: none of \(needles) within \(Int(timeout)) s")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Types raw text into the console.
    public func send(_ text: String) {
        transport.write(Data(text.utf8))
    }

    // MARK: Session

    /// Checks whether a shell answers on the console right now.
    public func probe(timeout: TimeInterval = 3) async -> Bool {
        start()
        let nonce = nextNonce()
        send("\necho \"__Z\"\"R_\(nonce)__\"\n")
        do {
            try await waitFor("__ZR_\(nonce)__", timeout: timeout)
            isReady = true
            return true
        } catch {
            return false
        }
    }

    /// Logs in on the console's getty (`login:` / `Password:`) unless a shell already answers.
    /// - Throws: when the login is refused or nothing answers before `timeout` (the guest may still be booting).
    public func login(user: String, password: String?, timeout: TimeInterval = 180) async throws {
        start()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            clearBuffer()
            send("\n")
            let sawLogin = (try? await waitFor("login:", timeout: 4, caseInsensitive: true)) != nil
            if sawLogin {
                try await Task.sleep(nanoseconds: 300_000_000)
                clearBuffer()
                send(user + "\n")
                let next = try? await waitForAny(["Password:", "Login incorrect", "$ ", "# "], timeout: 20)
                if next == 0 {
                    send((password ?? "") + "\n")
                    let outcome = try? await waitForAny(["Login incorrect", "$ ", "# ", "Last login", "Welcome"], timeout: 40)
                    if outcome == 0 { throw ZError.vm("serial console: login incorrect for \(user)") }
                } else if next == 1 {
                    throw ZError.vm("serial console: login incorrect for \(user)")
                }
                try await Task.sleep(nanoseconds: 700_000_000)
                if await probe(timeout: 8) { return }
            } else if await probe(timeout: 3) {
                return
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw ZError.vm("serial console: no login prompt or shell within \(Int(timeout)) s")
    }

    // MARK: Commands

    /// Runs a command through the console shell (which must be logged in) and returns its merged output.
    public func run(_ command: String, timeout: TimeInterval = 60) async throws -> ShellResult {
        start()
        let started = Date()
        let nonce = nextNonce()
        let markers = Markers(nonce: nonce)
        let payload = Data(command.utf8).base64EncodedString()
        let lines = Self.typedLines(payload: payload, nonce: nonce)
        clearBuffer()
        // All lines except the last only stage the payload; each is acknowledged before the next is typed so the
        // guest's tty input buffer never overflows.
        for (i, line) in lines.enumerated() {
            send(line + "\n")
            if i < lines.count - 1 {
                try await waitFor("__ZK_\(nonce)_\(i)__", timeout: min(timeout, 60))
            }
        }
        let deadline = started.addingTimeInterval(timeout)
        while true {
            let text = String(decoding: buffer, as: UTF8.self)
            if let parsed = Self.parseOutput(text, markers: markers) {
                buffer.removeFirst(min(buffer.count, parsed.consumedUTF8))
                return ShellResult(stdout: parsed.output, stderr: "", exitCode: parsed.exitCode, truncated: false,
                                   durationSeconds: Date().timeIntervalSince(started))
            }
            if Date() >= deadline {
                // Interrupt the command so the console is usable again.
                send("\u{03}")
                throw ZError.vm("serial console: command did not finish within \(Int(timeout)) s")
            }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    /// Reads a file through the console (base64 over the wire).
    public func readFile(path: String, timeout: TimeInterval = 300) async throws -> Data {
        let r = try await run("base64 < \(emuShellQuote(path))", timeout: timeout)
        guard r.exitCode == 0 else { throw ZError.vm("serial console: cannot read \(path): \(r.stdout.prefix(300))") }
        guard let data = Data(base64Encoded: r.stdout, options: .ignoreUnknownCharacters) else {
            throw ZError.vm("serial console: invalid base64 while reading \(path)")
        }
        return data
    }

    /// Writes a file through the console: base64 chunks are appended to a temp file (each acknowledged), then
    /// decoded into place.
    public func writeFile(path: String, data: Data, mode: String? = nil, timeout: TimeInterval = 600) async throws {
        start()
        let nonce = nextNonce()
        let tmp = "/tmp/.zser_w_\(nonce)"
        let started = Date()
        clearBuffer()
        let lines = Self.stagingLines(payload: data.base64EncodedString(), file: tmp, nonce: nonce)
        for (i, line) in lines.enumerated() {
            send(line + "\n")
            let remaining = max(1, timeout - Date().timeIntervalSince(started))
            try await waitFor("__ZK_\(nonce)_\(i)__", timeout: min(remaining, 60))
        }
        let q = emuShellQuote(path)
        var finish = "mkdir -p \"$(dirname \(q))\" && base64 -d \(tmp) > \(q) && rm -f \(tmp)"
        if let mode { finish += " && chmod \(emuShellQuote(mode)) \(q)" }
        let r = try await run(finish, timeout: max(10, timeout - Date().timeIntervalSince(started)))
        guard r.exitCode == 0 else { throw ZError.vm("serial console: cannot write \(path): \(r.stdout.prefix(300))") }
    }

    // MARK: Pure helpers (tested)

    /// The lines to type for a base64 `payload`. Short payloads fit one line; long ones are staged into a temp file
    /// in chunks first (staging line `i` prints the acknowledgement `__ZK_<nonce>_<i>__`) and then run as a script,
    /// which also avoids Linux's 128 KiB limit on a single argument.
    public static func typedLines(payload: String, nonce: String) -> [String] {
        let shell = "Z_SH=$(command -v bash || command -v sh)"
        let begin = "printf '%s\\n' \"__Z\"\"B_\(nonce)__\""
        let end = "echo \"__Z\"\"E_\(nonce)_$?__\""
        let inline = "\(shell); \(begin); \"$Z_SH\" -c \"$(printf %s '\(payload)' | base64 -d)\" </dev/null 2>&1; \(end)"
        if inline.utf8.count <= maxTypedLine { return [inline] }

        let file = "/tmp/.zser_\(nonce)"
        var lines = stagingLines(payload: payload, file: file, nonce: nonce)
        lines.append("base64 -d \(file) > \(file).sh; \(shell); \(begin); \"$Z_SH\" \(file).sh </dev/null 2>&1; \(end); rm -f \(file) \(file).sh")
        return lines
    }

    /// Lines that write `payload` into `file` in 2048-character chunks; line `i` prints `__ZK_<nonce>_<i>__`.
    public static func stagingLines(payload: String, file: String, nonce: String) -> [String] {
        var lines: [String] = [": > \(file); echo \"__Z\"\"K_\(nonce)_0__\""]
        var index = payload.startIndex
        while index < payload.endIndex {
            let end = payload.index(index, offsetBy: 2048, limitedBy: payload.endIndex) ?? payload.endIndex
            lines.append("printf %s '\(payload[index..<end])' >> \(file); echo \"__Z\"\"K_\(nonce)_\(lines.count)__\"")
            index = end
        }
        return lines
    }

    /// Finds the command output between the markers. Returns nil until the END marker (with its exit status and
    /// closing `__`) has arrived. Normalises CRLF to LF. `consumedUTF8` is how many bytes of `text` were used.
    public static func parseOutput(_ text: String, markers: Markers) -> (output: String, exitCode: Int32, consumedUTF8: Int)? {
        guard let beginRange = text.range(of: markers.begin) else { return nil }
        // The output starts after the line break that ends the BEGIN line ("\r\n" is a single Character).
        var outputStart = beginRange.upperBound
        while outputStart < text.endIndex, text[outputStart] == "\r\n" || text[outputStart] == "\n" || text[outputStart] == "\r" {
            let isLineEnd = text[outputStart] != "\r"
            outputStart = text.index(after: outputStart)
            if isLineEnd { break }
        }
        guard let endRange = text.range(of: markers.endPrefix, range: outputStart..<text.endIndex) else { return nil }
        let tail = text[endRange.upperBound...]
        guard let suffixRange = tail.range(of: markers.suffix) else { return nil }
        guard let code = Int32(tail[..<suffixRange.lowerBound]) else { return nil }
        let raw = String(text[outputStart..<endRange.lowerBound])
        let output = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let consumed = text[..<suffixRange.upperBound].utf8.count
        return (output, code, consumed)
    }
}
