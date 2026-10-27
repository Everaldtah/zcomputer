import Foundation
import ZCore

// Wire types for the zguest protocol, version 1 (guest-agent/PROTOCOL.md). Responses are flat JSON objects:
// `{"id":..., "ok":true, <result fields>}` or `{"id":..., "ok":false, "error":..., "code":...}`.

/// An error answered by the guest agent (`ok:false`) or raised by the client transport.
public struct GuestAgentError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The protocol's `code` field (plus client-side codes). Unknown codes are kept verbatim.
    public struct Code: RawRepresentable, Sendable, Hashable, CustomStringConvertible {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public var description: String { rawValue }

        // Agent codes (PROTOCOL.md "Responses").
        public static let badRequest = Code(rawValue: "bad_request")
        public static let unknownOp = Code(rawValue: "unknown_op")
        public static let tooLarge = Code(rawValue: "too_large")
        public static let notFound = Code(rawValue: "not_found")
        public static let permissionDenied = Code(rawValue: "permission_denied")
        public static let unavailable = Code(rawValue: "unavailable")
        public static let failed = Code(rawValue: "failed")
        public static let internalError = Code(rawValue: "internal")
        // Client-side codes.
        /// The connection could not be opened or broke (agent not running, VM stopped, EOF).
        public static let transport = Code(rawValue: "transport")
        /// No answer within the deadline.
        public static let timeout = Code(rawValue: "timeout")
        /// The agent answered something that is not a valid protocol response.
        public static let protocolError = Code(rawValue: "protocol")
    }

    public var code: Code
    public var message: String

    public init(code: Code, message: String) {
        self.code = code; self.message = message
    }

    public var description: String { "\(message) [\(code.rawValue)]" }

    /// The same error in ZCore's vocabulary (what agent tools show to the model).
    public var zError: ZError {
        switch code {
        case .notFound: return .notFound(message)
        case .badRequest: return .invalidArgument(message)
        case .unavailable, .unknownOp: return .unsupported(message)
        default: return .guest(description)
        }
    }
}

// MARK: - Results

/// `ping` result.
public struct AgentPing: Decodable, Sendable, Hashable {
    public var version: String
    public var protocolVersion: Int
    public var uptime: Double
    public var ops: [String]

    private enum CodingKeys: String, CodingKey { case version, protocolVersion = "protocol", uptime, ops }

    public init(version: String, protocolVersion: Int, uptime: Double, ops: [String]) {
        self.version = version; self.protocolVersion = protocolVersion; self.uptime = uptime; self.ops = ops
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        protocolVersion = try c.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? 0
        uptime = try c.decodeIfPresent(Double.self, forKey: .uptime) ?? 0
        ops = try c.decodeIfPresent([String].self, forKey: .ops) ?? []
    }

    public func supports(_ op: String) -> Bool { ops.contains(op) }
}

/// The graphical session found by the agent (`sysinfo.display`).
public struct AgentDisplay: Decodable, Sendable, Hashable {
    public var wayland: Bool
    public var x11: Bool
    /// "wayland", "x11" or "" (no session).
    public var type: String
    public var user: String
    public var uid: Int
    public var session: String
    public var desktop: String
    public var source: String
    public var env: [String: String]
    public var error: String?

    private enum CodingKeys: String, CodingKey { case wayland, x11, type, user, uid, session, desktop, source, env, error }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wayland = try c.decodeIfPresent(Bool.self, forKey: .wayland) ?? false
        x11 = try c.decodeIfPresent(Bool.self, forKey: .x11) ?? false
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        uid = try c.decodeIfPresent(Int.self, forKey: .uid) ?? -1
        session = try c.decodeIfPresent(String.self, forKey: .session) ?? ""
        desktop = try c.decodeIfPresent(String.self, forKey: .desktop) ?? ""
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }

    public var hasSession: Bool { !type.isEmpty }
}

/// `sysinfo` result.
public struct AgentSysInfo: Decodable, Sendable, Hashable {
    public var version: String
    public var hostname: String
    public var os: String
    public var osId: String
    public var osVersion: String
    public var kernel: String
    /// `uname -m` style: "aarch64", "x86_64".
    public var arch: String
    public var cpus: Int
    public var memTotal: Int64
    public var memFree: Int64
    public var uptime: Double
    public var agentUser: String
    public var display: AgentDisplay?
    public var tools: [String: Bool]

    private enum CodingKeys: String, CodingKey {
        case version, hostname, os, osId, osVersion, kernel, arch, cpus, memTotal, memFree, uptime, agentUser, display, tools
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        hostname = try c.decodeIfPresent(String.self, forKey: .hostname) ?? ""
        os = try c.decodeIfPresent(String.self, forKey: .os) ?? ""
        osId = try c.decodeIfPresent(String.self, forKey: .osId) ?? ""
        osVersion = try c.decodeIfPresent(String.self, forKey: .osVersion) ?? ""
        kernel = try c.decodeIfPresent(String.self, forKey: .kernel) ?? ""
        arch = try c.decodeIfPresent(String.self, forKey: .arch) ?? ""
        cpus = try c.decodeIfPresent(Int.self, forKey: .cpus) ?? 0
        memTotal = try c.decodeIfPresent(Int64.self, forKey: .memTotal) ?? 0
        memFree = try c.decodeIfPresent(Int64.self, forKey: .memFree) ?? 0
        uptime = try c.decodeIfPresent(Double.self, forKey: .uptime) ?? 0
        agentUser = try c.decodeIfPresent(String.self, forKey: .agentUser) ?? ""
        display = try c.decodeIfPresent(AgentDisplay.self, forKey: .display)
        tools = try c.decodeIfPresent([String: Bool].self, forKey: .tools) ?? [:]
    }

    public func has(_ tool: String) -> Bool { tools[tool] ?? false }
}

/// `exec` result. A non-zero exit or a timeout is still a successful response.
public struct AgentExecResult: Decodable, Sendable, Hashable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int
    public var signal: String?
    public var timedOut: Bool
    public var truncated: Bool
    public var stdoutTruncated: Bool
    public var stderrTruncated: Bool
    public var durationMs: Int
    public var shell: String
    public var user: String?

    private enum CodingKeys: String, CodingKey {
        case stdout, stderr, exitCode = "exit_code", signal, timedOut = "timed_out", truncated
        case stdoutTruncated = "stdout_truncated", stderrTruncated = "stderr_truncated", durationMs = "duration_ms", shell, user
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stdout = try c.decodeIfPresent(String.self, forKey: .stdout) ?? ""
        stderr = try c.decodeIfPresent(String.self, forKey: .stderr) ?? ""
        exitCode = try c.decodeIfPresent(Int.self, forKey: .exitCode) ?? 0
        signal = try c.decodeIfPresent(String.self, forKey: .signal)
        timedOut = try c.decodeIfPresent(Bool.self, forKey: .timedOut) ?? false
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        stdoutTruncated = try c.decodeIfPresent(Bool.self, forKey: .stdoutTruncated) ?? false
        stderrTruncated = try c.decodeIfPresent(Bool.self, forKey: .stderrTruncated) ?? false
        durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs) ?? 0
        shell = try c.decodeIfPresent(String.self, forKey: .shell) ?? ""
        user = try c.decodeIfPresent(String.self, forKey: .user)
    }

    /// The result as a ZCore `ShellResult`.
    public var shellResult: ShellResult {
        var err = stderr
        if timedOut { err += (err.isEmpty ? "" : "\n") + "[timed out]" }
        return ShellResult(stdout: stdout, stderr: err, exitCode: Int32(clamping: exitCode),
                           truncated: truncated || stdoutTruncated || stderrTruncated,
                           durationSeconds: Double(durationMs) / 1000)
    }
}

/// `read_file` result (one chunk).
public struct AgentFileChunk: Decodable, Sendable, Hashable {
    public var path: String
    public var data: Data
    public var size: Int64
    public var truncated: Bool

    private enum CodingKeys: String, CodingKey { case path, dataB64 = "data_b64", size, truncated }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        let b64 = try c.decodeIfPresent(String.self, forKey: .dataB64) ?? ""
        guard let d = Data(base64Encoded: b64) else {
            throw DecodingError.dataCorruptedError(forKey: .dataB64, in: c, debugDescription: "invalid base64")
        }
        data = d
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? Int64(d.count)
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}

/// `write_file` result.
public struct AgentWriteResult: Decodable, Sendable, Hashable {
    public var path: String
    public var written: Int64
    public var size: Int64

    private enum CodingKeys: String, CodingKey { case path, written, size }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        written = try c.decodeIfPresent(Int64.self, forKey: .written) ?? 0
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
    }
}

/// One `list_dir` entry.
public struct AgentDirEntry: Decodable, Sendable, Hashable {
    public var name: String
    public var isDir: Bool
    public var isSymlink: Bool
    public var size: Int64
    public var mode: String
    public var mtime: Int64

    private enum CodingKeys: String, CodingKey { case name, isDir, isSymlink, size, mode, mtime }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        isDir = try c.decodeIfPresent(Bool.self, forKey: .isDir) ?? false
        isSymlink = try c.decodeIfPresent(Bool.self, forKey: .isSymlink) ?? false
        size = try c.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? ""
        mtime = try c.decodeIfPresent(Int64.self, forKey: .mtime) ?? 0
    }
}

/// `list_dir` result.
public struct AgentDirListing: Decodable, Sendable, Hashable {
    public var path: String
    public var entries: [AgentDirEntry]
    public var truncated: Bool

    private enum CodingKeys: String, CodingKey { case path, entries, truncated }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        entries = try c.decodeIfPresent([AgentDirEntry].self, forKey: .entries) ?? []
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}

/// `screenshot` result.
public struct AgentScreenshot: Decodable, Sendable, Hashable {
    public var png: Data
    public var width: Int
    public var height: Int
    public var tool: String
    public var session: String
    public var warning: String?

    private enum CodingKeys: String, CodingKey { case pngB64 = "png_b64", width, height, tool, session, warning }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let b64 = try c.decode(String.self, forKey: .pngB64)
        guard let d = Data(base64Encoded: b64) else {
            throw DecodingError.dataCorruptedError(forKey: .pngB64, in: c, debugDescription: "invalid base64")
        }
        png = d
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 0
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 0
        tool = try c.decodeIfPresent(String.self, forKey: .tool) ?? ""
        session = try c.decodeIfPresent(String.self, forKey: .session) ?? ""
        warning = try c.decodeIfPresent(String.self, forKey: .warning)
    }
}

/// `input` result.
public struct AgentInputResult: Decodable, Sendable, Hashable {
    public var backend: String
    public var performed: Int
    public var warning: String?

    private enum CodingKeys: String, CodingKey { case backend, performed, warning }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        backend = try c.decodeIfPresent(String.self, forKey: .backend) ?? ""
        performed = try c.decodeIfPresent(Int.self, forKey: .performed) ?? 0
        warning = try c.decodeIfPresent(String.self, forKey: .warning)
    }
}

/// `shutdown` / `reboot` result.
public struct AgentPowerResult: Decodable, Sendable, Hashable {
    public var action: String
    public var delayMs: Int

    private enum CodingKeys: String, CodingKey { case action, delayMs = "delay_ms" }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = try c.decodeIfPresent(String.self, forKey: .action) ?? ""
        delayMs = try c.decodeIfPresent(Int.self, forKey: .delayMs) ?? 0
    }
}

// MARK: - Input actions

/// One action of the `input` op. Coordinates are session pixels (the screenshot's space).
public enum AgentInputAction: Sendable, Hashable {
    case click(x: Int?, y: Int?, button: MouseButton = .left, count: Int = 1)
    case doubleClick(x: Int?, y: Int?)
    case rightClick(x: Int?, y: Int?)
    case middleClick(x: Int?, y: Int?)
    case mouseMove(x: Int, y: Int)
    case mouseDown(x: Int?, y: Int?, button: MouseButton = .left)
    case mouseUp(x: Int?, y: Int?, button: MouseButton = .left)
    case drag(x: Int, y: Int, toX: Int, toY: Int)
    /// `dy > 0` scrolls down, `dx > 0` right; wheel steps −100…100.
    case scroll(x: Int?, y: Int?, dx: Int, dy: Int)
    case type(String)
    /// xdotool-style combos, several separated by spaces: "ctrl+a Delete".
    case key(String)

    /// The JSON object of this action.
    public var json: JSONValue {
        var o: [String: JSONValue] = [:]
        func point(_ x: Int?, _ y: Int?) {
            if let x, let y { o["x"] = .number(Double(x)); o["y"] = .number(Double(y)) }
        }
        switch self {
        case .click(let x, let y, let button, let count):
            o["type"] = "click"; point(x, y)
            o["button"] = .string(button.rawValue)
            o["count"] = .number(Double(count))
        case .doubleClick(let x, let y):
            o["type"] = "double_click"; point(x, y)
        case .rightClick(let x, let y):
            o["type"] = "right_click"; point(x, y)
        case .middleClick(let x, let y):
            o["type"] = "middle_click"; point(x, y)
        case .mouseMove(let x, let y):
            o["type"] = "mouse_move"; point(x, y)
        case .mouseDown(let x, let y, let button):
            o["type"] = "mouse_down"; point(x, y)
            o["button"] = .string(button.rawValue)
        case .mouseUp(let x, let y, let button):
            o["type"] = "mouse_up"; point(x, y)
            o["button"] = .string(button.rawValue)
        case .drag(let x, let y, let toX, let toY):
            o["type"] = "drag"; point(x, y)
            o["to_x"] = .number(Double(toX)); o["to_y"] = .number(Double(toY))
        case .scroll(let x, let y, let dx, let dy):
            o["type"] = "scroll"; point(x, y)
            o["dx"] = .number(Double(dx)); o["dy"] = .number(Double(dy))
        case .type(let text):
            o["type"] = "type"; o["text"] = .string(text)
        case .key(let key):
            o["type"] = "key"; o["key"] = .string(key)
        }
        return .object(o)
    }
}

// MARK: - Framing

/// Splits a byte stream into newline-terminated lines (JSON-lines framing). A trailing `\r` is dropped and
/// blank lines are skipped, as in PROTOCOL.md. Lines longer than `maxLineLength` are an error.
public struct JSONLineFramer: Sendable {
    public let maxLineLength: Int
    private var buffer = Data()
    /// How far `buffer` has already been searched for a newline (avoids rescanning large partial lines).
    private var scanned = 0

    /// 80 MiB by default: the agent's largest responses are ~64 MiB of base64.
    public init(maxLineLength: Int = 80 << 20) { self.maxLineLength = maxLineLength }

    public var bufferedByteCount: Int { buffer.count }

    /// Appends bytes and returns every complete line now available (without the newline).
    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let nl = buffer[(buffer.startIndex + scanned)...].firstIndex(of: 0x0A) {
            var line = Data(buffer[buffer.startIndex..<nl])
            buffer = Data(buffer[(nl + 1)...])
            scanned = 0
            if line.last == 0x0D { line.removeLast() }
            if line.isEmpty { continue }
            if line.count > maxLineLength {
                throw GuestAgentError(code: .tooLarge, message: "response line of \(line.count) bytes exceeds \(maxLineLength)")
            }
            lines.append(line)
        }
        scanned = buffer.count
        if buffer.count > maxLineLength {
            throw GuestAgentError(code: .tooLarge, message: "response line exceeds \(maxLineLength) bytes")
        }
        return lines
    }

    /// Takes whatever is left in the buffer (a final line without newline at EOF).
    public mutating func flush() -> Data? {
        var rest = buffer
        buffer = Data(); scanned = 0
        if rest.last == 0x0D { rest.removeLast() }
        return rest.isEmpty ? nil : rest
    }
}

// MARK: - Requests and responses

enum GuestAgentWire {
    /// Encodes `{"id":..., "op":..., <params>}` + "\n".
    static func encodeRequest(id: String, op: String, params: [String: JSONValue]) throws -> Data {
        var object = params
        object["id"] = .string(id)
        object["op"] = .string(op)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var data = try encoder.encode(JSONValue.object(object))
        data.append(0x0A)
        return data
    }

    /// The common part of every response.
    struct Header: Decodable {
        var id: String
        var ok: Bool
        var error: String?
        var code: String?

        private enum CodingKeys: String, CodingKey { case id, ok, error, code }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            ok = try c.decode(Bool.self, forKey: .ok)
            error = try c.decodeIfPresent(String.self, forKey: .error)
            code = try c.decodeIfPresent(String.self, forKey: .code)
        }
    }

    /// Header + flattened result decoded in one pass over the line.
    struct Envelope<T: Decodable>: Decodable {
        var header: Header
        var result: T?

        init(from decoder: any Decoder) throws {
            header = try Header(from: decoder)
            if header.ok {
                result = try T(from: decoder)
            } else {
                result = nil
            }
        }
    }

    /// Decodes a response line: returns the result or throws the agent's error.
    static func decodeResponse<T: Decodable>(_ line: Data, as type: T.Type, expectedID: String?) throws -> T {
        let envelope: Envelope<T>
        do {
            envelope = try JSONDecoder().decode(Envelope<T>.self, from: line)
        } catch let error as GuestAgentError {
            throw error
        } catch {
            let preview = String(decoding: line.prefix(200), as: UTF8.self)
            throw GuestAgentError(code: .protocolError, message: "invalid response (\(error)): \(preview)")
        }
        if let expectedID, envelope.header.id != expectedID, !(envelope.header.ok == false && envelope.header.id.isEmpty) {
            throw GuestAgentError(code: .protocolError,
                                  message: "response id \(envelope.header.id) does not match request \(expectedID)")
        }
        guard envelope.header.ok else {
            throw GuestAgentError(code: GuestAgentError.Code(rawValue: envelope.header.code ?? "failed"),
                                  message: envelope.header.error ?? "guest agent error")
        }
        guard let result = envelope.result else {
            throw GuestAgentError(code: .protocolError, message: "missing result")
        }
        return result
    }
}

/// Decodes nothing (ops whose result fields are not needed).
public struct AgentEmptyResult: Decodable, Sendable, Hashable {
    public init() {}
    public init(from decoder: any Decoder) throws {}
}
