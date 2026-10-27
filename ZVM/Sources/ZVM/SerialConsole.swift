import Darwin
import Foundation

/// Something that carries a serial console: output as a stream of chunks, input as raw bytes.
/// `SerialConsole` is the real one (pipes into the VM); tests use fakes.
public protocol SerialTransport: AnyObject, Sendable {
    /// A new subscription to the guest's output. With `replay`, recent output is delivered first.
    func output(replay: Bool) -> AsyncStream<Data>
    /// Sends bytes to the guest (never blocks the caller).
    func write(_ data: Data)
}

/// The guest's virtio console (`/dev/hvc0` in Linux) over two pipes, shared by the terminal UI and `SerialShell`.
///
/// Apple's semantics for `VZFileHandleSerialPortAttachment`: the guest *reads* `fileHandleForReading` and
/// *writes* `fileHandleForWriting`, so the attachment gets `guestInputHandle` / `guestOutputHandle` below.
public final class SerialConsole: SerialTransport, @unchecked Sendable {
    private let toGuest = Pipe()     // host writes -> guest reads
    private let fromGuest = Pipe()   // guest writes -> host reads
    private let writeQueue = DispatchQueue(label: "zvm.serial.write")
    private let broadcaster = Broadcaster<Data>(replaysLatest: false, bufferLimit: 4096)
    private let lock = NSLock()
    private var scrollback = Data()
    private let scrollbackLimit: Int
    private var reading = false
    private var closed = false

    public init(scrollbackLimit: Int = 512 << 10) {
        self.scrollbackLimit = scrollbackLimit
        // A write to a pipe whose reader is gone must fail with EPIPE, not kill the app with SIGPIPE.
        _ = fcntl(toGuest.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    /// For `VZFileHandleSerialPortAttachment(fileHandleForReading:fileHandleForWriting:)`: what the guest reads.
    public var guestInputHandle: FileHandle { toGuest.fileHandleForReading }
    /// For `VZFileHandleSerialPortAttachment(fileHandleForReading:fileHandleForWriting:)`: where the guest writes.
    public var guestOutputHandle: FileHandle { fromGuest.fileHandleForWriting }

    /// Starts forwarding guest output to subscribers (idempotent). `VMController` calls it before starting the VM.
    public func startReading() {
        lock.lock()
        let already = reading
        reading = true
        lock.unlock()
        guard !already else { return }
        fromGuest.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.publish(data)
        }
    }

    private func publish(_ data: Data) {
        lock.lock()
        scrollback.append(data)
        if scrollback.count > scrollbackLimit {
            scrollback.removeFirst(scrollback.count - scrollbackLimit)
        }
        lock.unlock()
        broadcaster.yield(data)
    }

    /// Output received so far (bounded by `scrollbackLimit`).
    public var recentOutput: Data {
        lock.lock(); defer { lock.unlock() }
        return scrollback
    }

    public func output(replay: Bool = false) -> AsyncStream<Data> {
        guard replay else { return broadcaster.stream() }
        let history = recentOutput
        let live = broadcaster.stream()
        return AsyncStream<Data> { continuation in
            if !history.isEmpty { continuation.yield(history) }
            let task = Task {
                for await chunk in live { continuation.yield(chunk) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Queues bytes for the guest. Pipe writes can block while the guest is not reading, so they run on a
    /// private serial queue; ordering is preserved.
    public func write(_ data: Data) {
        guard !data.isEmpty else { return }
        let handle = toGuest.fileHandleForWriting
        writeQueue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            do { try handle.write(contentsOf: data) } catch { /* guest side gone: drop */ }
        }
    }

    public func write(_ text: String) { write(Data(text.utf8)) }

    private var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    /// Stops reading and ends all output streams.
    public func close() {
        lock.lock()
        closed = true
        lock.unlock()
        fromGuest.fileHandleForReading.readabilityHandler = nil
        broadcaster.finish()
    }
}
