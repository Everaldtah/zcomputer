import Foundation
import ZCore

/// Fan-out of values to any number of `AsyncStream` subscribers (run state, serial output).
public final class EmuBroadcaster<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private var latest: Element?
    private var finished = false
    private let replaysLatest: Bool
    private let bufferLimit: Int

    /// - Parameters:
    ///   - replaysLatest: new subscribers immediately receive the most recent value.
    ///   - bufferLimit: per-subscriber buffer; the oldest values are dropped when a subscriber falls behind.
    public init(replaysLatest: Bool = false, bufferLimit: Int = 1024) {
        self.replaysLatest = replaysLatest
        self.bufferLimit = bufferLimit
    }

    public func stream() -> AsyncStream<Element> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Element>.makeStream(bufferingPolicy: .bufferingNewest(bufferLimit))
        lock.lock()
        let isFinished = finished
        let replay = replaysLatest ? latest : nil
        if !isFinished { continuations[id] = continuation }
        lock.unlock()
        if let replay { continuation.yield(replay) }
        if isFinished {
            continuation.finish()
        } else {
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.continuations[id] = nil; self.lock.unlock()
            }
        }
        return stream
    }

    public func yield(_ value: Element) {
        lock.lock()
        latest = value
        let targets = Array(continuations.values)
        lock.unlock()
        for c in targets { c.yield(value) }
    }

    public var current: Element? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    public func finish() {
        lock.lock()
        finished = true
        let targets = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for c in targets { c.finish() }
    }
}

/// A small mutable box for values shared with `@Sendable` closures under a lock.
final class EmuLocked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
    @discardableResult
    func update<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}

/// Runs `operation` with a deadline. On timeout the operation's task is cancelled and `timeoutError` is thrown.
func emuWithDeadline<T: Sendable>(seconds: TimeInterval,
                                  timeoutError: any Error,
                                  _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let nanos = UInt64(max(0, seconds) * 1_000_000_000)
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: nanos)
            throw timeoutError
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw ZError.cancelled }
        return first
    }
}

/// Quotes a string for POSIX `sh` (single quotes; embedded quotes become `'\''`).
public func emuShellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Lowercase hex of bytes.
func emuHex(_ bytes: some Sequence<UInt8>) -> String {
    let digits = Array("0123456789abcdef")
    var s = ""
    for b in bytes { s.append(digits[Int(b >> 4)]); s.append(digits[Int(b & 0x0f)]) }
    return s
}

/// True when every byte is zero (word-at-a-time).
func emuIsAllZero(_ d: Data) -> Bool {
    d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
        let n = raw.count
        var i = 0
        while i + 8 <= n {
            if raw.loadUnaligned(fromByteOffset: i, as: UInt64.self) != 0 { return false }
            i += 8
        }
        while i < n {
            if raw[i] != 0 { return false }
            i += 1
        }
        return true
    }
}

/// Size of a file in bytes.
func emuFileSize(_ url: URL) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    if let n = attributes[.size] as? NSNumber { return n.uint64Value }
    throw ZError.notFound("size of \(url.path)")
}
