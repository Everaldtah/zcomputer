import Foundation
import ZCore

/// Fan-out of values to any number of `AsyncStream` subscribers (state updates, serial output).
public final class Broadcaster<Element: Sendable>: @unchecked Sendable {
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

/// Thread-safe "first caller wins" flag (used to race completion handlers against timeouts).
public final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    public init() {}
    public func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

/// A small mutable box for values shared with `@Sendable` closures under a lock.
public final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    public init(_ value: Value) { self.value = value }
    public func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    public func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
    @discardableResult
    public func update<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}

/// Runs `operation` with a deadline. On timeout the operation's task is cancelled (operations must honour
/// cancellation, e.g. by closing their connection) and `timeoutError` is thrown.
func withDeadline<T: Sendable>(seconds: TimeInterval,
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

/// Random-access byte source (ISO images, qcow2 files, in-memory test data).
public protocol RandomAccessSource {
    var size: UInt64 { get }
    /// Reads up to `count` bytes at `offset`; returns fewer bytes only at the end of the source.
    func read(at offset: UInt64, count: Int) throws -> Data
}

/// In-memory source.
public struct DataSource: RandomAccessSource {
    public let data: Data
    public init(_ data: Data) { self.data = data }
    public var size: UInt64 { UInt64(data.count) }
    public func read(at offset: UInt64, count: Int) throws -> Data {
        guard offset < UInt64(data.count), count > 0 else { return Data() }
        let start = data.startIndex + Int(offset)
        let end = min(data.endIndex, start + count)
        return Data(data[start..<end])
    }
}

/// File-backed source (read-only).
public final class FileSource: RandomAccessSource {
    private let handle: FileHandle
    public let size: UInt64

    public init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        size = try handle.seekToEnd()
    }

    deinit { try? handle.close() }

    public func read(at offset: UInt64, count: Int) throws -> Data {
        guard offset < size, count > 0 else { return Data() }
        try handle.seek(toOffset: offset)
        var out = Data()
        var remaining = Int(min(UInt64(count), size - offset))
        while remaining > 0 {
            guard let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else { break }
            out.append(chunk)
            remaining -= chunk.count
        }
        return out
    }
}

/// Byte helpers shared by the ISO 9660 and qcow2 code.
enum Bytes {
    static func u16le(_ d: Data, _ o: Int) -> UInt16 {
        guard o + 2 <= d.count else { return 0 }
        let b = d.startIndex + o
        return UInt16(d[b]) | UInt16(d[b + 1]) << 8
    }
    static func u32le(_ d: Data, _ o: Int) -> UInt32 {
        guard o + 4 <= d.count else { return 0 }
        let b = d.startIndex + o
        return UInt32(d[b]) | UInt32(d[b + 1]) << 8 | UInt32(d[b + 2]) << 16 | UInt32(d[b + 3]) << 24
    }
    static func u32be(_ d: Data, _ o: Int) -> UInt32 {
        guard o + 4 <= d.count else { return 0 }
        let b = d.startIndex + o
        return UInt32(d[b]) << 24 | UInt32(d[b + 1]) << 16 | UInt32(d[b + 2]) << 8 | UInt32(d[b + 3])
    }
    static func u64be(_ d: Data, _ o: Int) -> UInt64 {
        UInt64(u32be(d, o)) << 32 | UInt64(u32be(d, o + 4))
    }
    static func byte(_ d: Data, _ o: Int) -> UInt8 {
        guard o >= 0, o < d.count else { return 0 }
        return d[d.startIndex + o]
    }
    static func slice(_ d: Data, _ o: Int, _ n: Int) -> Data {
        guard o >= 0, n > 0, o < d.count else { return Data() }
        let b = d.startIndex + o
        return Data(d[b..<min(d.endIndex, b + n)])
    }
    /// True when every byte is zero (word-at-a-time).
    static func isAllZero(_ d: Data) -> Bool {
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
    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        let digits = Array("0123456789abcdef")
        var s = ""
        for b in bytes { s.append(digits[Int(b >> 4)]); s.append(digits[Int(b & 0x0f)]) }
        return s
    }
}

/// Quotes a string for POSIX `sh` (single quotes; embedded quotes become `'\''`).
public func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
