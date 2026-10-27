import Darwin
import Foundation
import ZCore

/// A byte-stream connection to the guest agent (vsock in production, an in-memory fake in tests).
public protocol GuestAgentConnection: AnyObject, Sendable {
    func write(_ data: Data) async throws
    /// Reads up to `maxLength` bytes. An empty result means EOF.
    func read(maxLength: Int) async throws -> Data
    /// Closes the connection; a pending `read` returns EOF / throws. Must be idempotent.
    func close()
}

/// Opens a new connection to the agent (e.g. `VMController.connectGuestAgent()`).
public typealias GuestAgentConnector = @Sendable () async throws -> any GuestAgentConnection

/// A connection over a (duplicated) socket file descriptor, e.g. the fd of a `VZVirtioSocketConnection`.
/// Blocking I/O runs on private dispatch queues; `close()` shuts the socket down so pending reads return.
public final class FileDescriptorConnection: GuestAgentConnection, @unchecked Sendable {
    public let fileDescriptor: Int32
    private let lock = NSLock()
    private var closed = false
    private let onClose: (@Sendable () -> Void)?
    private let readQueue = DispatchQueue(label: "zvm.agent.read")
    private let writeQueue = DispatchQueue(label: "zvm.agent.write")

    /// Takes ownership of `fileDescriptor` (closed on deinit). `onClose` runs once when the connection is closed
    /// (used to release the `VZVirtioSocketConnection` it was duplicated from).
    public init(fileDescriptor: Int32, onClose: (@Sendable () -> Void)? = nil) {
        self.fileDescriptor = fileDescriptor
        self.onClose = onClose
        // Never die of SIGPIPE when the guest goes away; get EPIPE instead.
        _ = fcntl(fileDescriptor, F_SETNOSIGPIPE, 1)
        // The reader below expects blocking I/O.
        let flags = fcntl(fileDescriptor, F_GETFL)
        if flags >= 0, (flags & O_NONBLOCK) != 0 {
            _ = fcntl(fileDescriptor, F_SETFL, flags & ~O_NONBLOCK)
        }
    }

    deinit {
        _ = Darwin.close(fileDescriptor)
    }

    public var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    public func close() {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        guard !wasClosed else { return }
        _ = shutdown(fileDescriptor, SHUT_RDWR)
        onClose?()
    }

    public func read(maxLength: Int) async throws -> Data {
        if isClosed { return Data() }
        let capacity = max(1, maxLength)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, any Error>) in
                readQueue.async { [self] in
                    var buffer = [UInt8](repeating: 0, count: capacity)
                    while true {
                        let n = buffer.withUnsafeMutableBytes { raw in Darwin.read(fileDescriptor, raw.baseAddress, raw.count) }
                        if n >= 0 {
                            cont.resume(returning: Data(buffer[0..<n]))
                            return
                        }
                        let err = errno
                        if err == EINTR { continue }
                        if err == EAGAIN {
                            var p = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
                            _ = poll(&p, 1, 1000)
                            continue
                        }
                        if isClosed { cont.resume(returning: Data()); return }
                        cont.resume(throwing: GuestAgentError(code: .transport, message: "read failed: \(String(cString: strerror(err)))"))
                        return
                    }
                }
            }
        } onCancel: { [weak self] in
            self?.close()
        }
    }

    public func write(_ data: Data) async throws {
        if isClosed { throw GuestAgentError(code: .transport, message: "connection closed") }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                writeQueue.async { [self] in
                    let failure: GuestAgentError? = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> GuestAgentError? in
                        guard let base = raw.baseAddress else { return nil }
                        var offset = 0
                        while offset < raw.count {
                            let n = Darwin.write(fileDescriptor, base + offset, raw.count - offset)
                            if n > 0 { offset += n; continue }
                            let err = errno
                            if n < 0 && err == EINTR { continue }
                            if n < 0 && err == EAGAIN {
                                var p = pollfd(fd: fileDescriptor, events: Int16(POLLOUT), revents: 0)
                                _ = poll(&p, 1, 1000)
                                continue
                            }
                            return GuestAgentError(code: .transport, message: "write failed: \(String(cString: strerror(err)))")
                        }
                        return nil
                    }
                    if let failure { cont.resume(throwing: failure) } else { cont.resume() }
                }
            }
        } onCancel: { [weak self] in
            self?.close()
        }
    }
}

/// Client for the in-guest agent `zguest` (guest-agent/PROTOCOL.md): newline-delimited JSON over vsock port 5555.
///
/// Every request takes an idle pooled connection or opens a new one, so concurrent calls (a long `exec` and a
/// `screenshot`) run on separate connections as the protocol recommends. Responses are matched by `id`.
public actor GuestAgentClient {
    /// The vsock port the agent listens on.
    public static let port: UInt32 = 5555

    private let connector: GuestAgentConnector
    private let maxIdleConnections: Int
    private var idle: [PooledConnection] = []
    private var nextRequestID = 1
    /// Deadline for requests without an explicit timeout.
    public var defaultTimeout: TimeInterval
    /// The last successful `ping`.
    public private(set) var lastPing: AgentPing?
    private var lastPingAt: Date?
    private var lastFailureAt: Date?

    public init(connector: @escaping GuestAgentConnector, maxIdleConnections: Int = 2, defaultTimeout: TimeInterval = 30) {
        self.connector = connector
        self.maxIdleConnections = maxIdleConnections
        self.defaultTimeout = defaultTimeout
    }

    public func setDefaultTimeout(_ seconds: TimeInterval) { defaultTimeout = seconds }

    // MARK: Ops

    public func ping(timeout: TimeInterval = 3) async throws -> AgentPing {
        do {
            let p = try await request("ping", [:], as: AgentPing.self, timeout: timeout)
            lastPing = p
            lastPingAt = Date()
            lastFailureAt = nil
            return p
        } catch {
            lastFailureAt = Date()
            throw error
        }
    }

    /// True when the agent answered a ping recently (cached for `maxAge` seconds; failures are cached for
    /// `failureBackoff` seconds so a missing agent does not slow every call down).
    public func isReachable(timeout: TimeInterval = 2, maxAge: TimeInterval = 5, failureBackoff: TimeInterval = 5) async -> Bool {
        if let at = lastPingAt, Date().timeIntervalSince(at) < maxAge { return true }
        if let failed = lastFailureAt, Date().timeIntervalSince(failed) < failureBackoff { return false }
        return (try? await ping(timeout: timeout)) != nil
    }

    /// Forgets the cached reachability (call after a VM restart).
    public func resetReachability() {
        lastPingAt = nil
        lastFailureAt = nil
    }

    public func sysinfo(timeout: TimeInterval = 10) async throws -> AgentSysInfo {
        try await request("sysinfo", [:], as: AgentSysInfo.self, timeout: timeout)
    }

    /// Runs `bash -lc command` in the guest. `timeout` is the agent-side kill timeout; the client waits 15 s longer.
    public func exec(_ command: String,
                     timeout: TimeInterval = 60,
                     cwd: String? = nil,
                     env: [String: String] = [:],
                     stdin: String? = nil,
                     desktop: Bool = false) async throws -> AgentExecResult {
        let ms = Int(min(max(timeout, 0.001), 24 * 3600) * 1000)
        var p: [String: JSONValue] = ["cmd": .string(command), "timeout_ms": .number(Double(ms))]
        if let cwd { p["cwd"] = .string(cwd) }
        if !env.isEmpty { p["env"] = .object(env.mapValues { JSONValue.string($0) }) }
        if let stdin { p["stdin"] = .string(stdin) }
        if desktop { p["desktop"] = .bool(true) }
        return try await request("exec", p, as: AgentExecResult.self, timeout: Double(ms) / 1000 + 15)
    }

    /// One `read_file` chunk (at most 48 MiB per call).
    public func readFile(path: String, maxBytes: Int? = nil, offset: Int64 = 0) async throws -> AgentFileChunk {
        var p: [String: JSONValue] = ["path": .string(path)]
        if let maxBytes { p["max_bytes"] = .number(Double(maxBytes)) }
        if offset > 0 { p["offset"] = .number(Double(offset)) }
        return try await request("read_file", p, as: AgentFileChunk.self, timeout: 120)
    }

    /// Reads a whole file in 16 MiB chunks.
    public func readWholeFile(path: String, limit: Int64 = 1 << 30) async throws -> Data {
        var out = Data()
        var offset: Int64 = 0
        while true {
            let chunk = try await readFile(path: path, maxBytes: 16 << 20, offset: offset)
            out.append(chunk.data)
            offset += Int64(chunk.data.count)
            if !chunk.truncated || chunk.data.isEmpty { return out }
            if offset > limit { throw ZError.invalidArgument("\(path) is larger than \(limit) bytes") }
        }
    }

    /// Writes a file. Data larger than 16 MiB is sent in several requests (write, then appends).
    /// `mode` is an octal string such as "0755".
    @discardableResult
    public func writeFile(path: String, data: Data, mode: String? = nil, mkdir: Bool = false, append: Bool = false) async throws -> AgentWriteResult {
        let chunkSize = 16 << 20
        var offset = 0
        var appendNext = append
        var last: AgentWriteResult?
        repeat {
            let end = min(data.count, offset + chunkSize)
            let piece = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + end))
            var p: [String: JSONValue] = ["path": .string(path), "data_b64": .string(piece.base64EncodedString())]
            if let mode { p["mode"] = .string(mode) }
            if mkdir { p["mkdir"] = .bool(true) }
            if appendNext { p["append"] = .bool(true) }
            last = try await request("write_file", p, as: AgentWriteResult.self, timeout: 120)
            appendNext = true
            offset = end
        } while offset < data.count
        guard let last else { throw GuestAgentError(code: .protocolError, message: "no write result") }
        return last
    }

    public func listDir(path: String) async throws -> AgentDirListing {
        try await request("list_dir", ["path": .string(path)], as: AgentDirListing.self, timeout: 30)
    }

    /// Screenshot of the guest's graphical session (PNG). `display` ":N" forces an X display.
    public func screenshot(display: String? = nil, timeout: TimeInterval = 30) async throws -> AgentScreenshot {
        var p: [String: JSONValue] = [:]
        if let display { p["display"] = .string(display) }
        return try await request("screenshot", p, as: AgentScreenshot.self, timeout: timeout)
    }

    /// Injects input into the guest session (xdotool / ydotool / wtype in the guest; unicode text works).
    @discardableResult
    public func input(_ actions: [AgentInputAction], backend: String? = nil, timeout: TimeInterval = 60) async throws -> AgentInputResult {
        guard !actions.isEmpty else { throw ZError.invalidArgument("no input actions") }
        var p: [String: JSONValue] = ["actions": .array(actions.map { $0.json })]
        if let backend { p["backend"] = .string(backend) }
        return try await request("input", p, as: AgentInputResult.self, timeout: timeout)
    }

    @discardableResult
    public func shutdown() async throws -> AgentPowerResult {
        let r = try await request("shutdown", [:], as: AgentPowerResult.self, timeout: 10)
        closeAll()
        return r
    }

    @discardableResult
    public func reboot() async throws -> AgentPowerResult {
        let r = try await request("reboot", [:], as: AgentPowerResult.self, timeout: 10)
        closeAll()
        return r
    }

    /// Closes every pooled connection (e.g. when the VM stops).
    public func closeAll() {
        for c in idle { c.connection.close() }
        idle.removeAll()
        lastPingAt = nil
    }

    // MARK: Transport

    /// Sends one request and decodes its flattened result. Exposed for ops added to the agent later.
    public func request<T: Decodable & Sendable>(_ op: String, _ params: [String: JSONValue], as type: T.Type,
                                                 timeout: TimeInterval? = nil) async throws -> T {
        let id = String(nextRequestID)
        nextRequestID += 1
        let line = try GuestAgentWire.encodeRequest(id: id, op: op, params: params)
        let seconds = timeout ?? defaultTimeout
        var attempt = 0
        while true {
            attempt += 1
            let (pooled, reused) = try await checkout()
            do {
                let timeoutError = GuestAgentError(code: .timeout, message: "the guest agent did not answer \(op) within \(Int(seconds.rounded(.up))) s")
                let response = try await withDeadline(seconds: seconds, timeoutError: timeoutError) {
                    try await pooled.connection.write(line)
                    return try await pooled.readLine()
                }
                let result = try GuestAgentWire.decodeResponse(response, as: T.self, expectedID: id)
                checkin(pooled)
                return result
            } catch let error as GuestAgentError where error.code == .transport && reused && attempt == 1 {
                // A pooled connection went stale (agent restarted): retry once on a fresh connection.
                pooled.connection.close()
                continue
            } catch let error as GuestAgentError where ![.transport, .timeout, .protocolError, .tooLarge].contains(error.code) {
                // The agent answered ok:false; the connection is still in sync.
                checkin(pooled)
                throw error
            } catch {
                pooled.connection.close()
                throw error
            }
        }
    }

    private func checkout() async throws -> (PooledConnection, Bool) {
        if let c = idle.popLast() { return (c, true) }
        do {
            let raw = try await connector()
            return (PooledConnection(raw), false)
        } catch let error as GuestAgentError {
            throw error
        } catch {
            throw GuestAgentError(code: .transport, message: "cannot connect to the guest agent: \(error)")
        }
    }

    private func checkin(_ pooled: PooledConnection) {
        if idle.count < maxIdleConnections && pooled.isInSync {
            idle.append(pooled)
        } else {
            pooled.connection.close()
        }
    }
}

/// A connection plus its framing state. Used by one request at a time.
final class PooledConnection: @unchecked Sendable {
    let connection: any GuestAgentConnection
    private var framer = JSONLineFramer()
    private var pending: [Data] = []

    init(_ connection: any GuestAgentConnection) { self.connection = connection }

    /// No buffered bytes or extra lines: safe to reuse for the next request.
    var isInSync: Bool { pending.isEmpty && framer.bufferedByteCount == 0 }

    func readLine() async throws -> Data {
        if !pending.isEmpty { return pending.removeFirst() }
        while true {
            let chunk = try await connection.read(maxLength: 256 << 10)
            if chunk.isEmpty {
                if let rest = framer.flush() { return rest }
                throw GuestAgentError(code: .transport, message: "the guest agent closed the connection")
            }
            let lines = try framer.append(chunk)
            if let first = lines.first {
                pending.append(contentsOf: lines.dropFirst())
                return first
            }
        }
    }
}
