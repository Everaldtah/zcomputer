import Foundation
import ZCore

/// Something that carries a serial console: output as a stream of chunks, input as raw bytes.
/// `EmuConsole` is the real one (COM1 of the emulated PC); tests use fakes.
public protocol EmuSerialTransport: AnyObject, Sendable {
    /// A new subscription to the guest's output. With `replay`, recent output is delivered first.
    func output(replay: Bool) -> AsyncStream<Data>
    /// Sends bytes to the guest (never blocks the caller).
    func write(_ data: Data)
}

/// The guest's first serial port (COM1, Linux `ttyS0`), shared by the terminal UI and the serial shell.
/// Output arrives from the web page in batches; input is forwarded to v86's `serial0_send` on the main thread in
/// the order it was written.
public final class EmuConsole: EmuSerialTransport, @unchecked Sendable {
    private let broadcaster = EmuBroadcaster<Data>(replaysLatest: false, bufferLimit: 4096)
    private let lock = NSLock()
    private var scrollback = Data()
    private let scrollbackLimit: Int
    private var pendingInput = Data()
    private var flushScheduled = false
    private var sink: (@MainActor @Sendable (Data) -> Void)?

    public init(scrollbackLimit: Int = 512 << 10) {
        self.scrollbackLimit = scrollbackLimit
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

    /// Queues bytes for the guest. Delivered in order on the main thread; dropped while no machine is attached.
    public func write(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        pendingInput.append(data)
        let schedule = !flushScheduled
        flushScheduled = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    public func write(_ text: String) { write(Data(text.utf8)) }

    @MainActor private func flush() {
        lock.lock()
        let data = pendingInput
        pendingInput = Data()
        flushScheduled = false
        let target = sink
        lock.unlock()
        if !data.isEmpty { target?(data) }
    }

    /// Where input goes (the host page). Set by `EmuController`.
    func setSink(_ sink: (@MainActor @Sendable (Data) -> Void)?) {
        lock.lock(); self.sink = sink; lock.unlock()
    }

    /// Output from the guest.
    func publish(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        scrollback.append(data)
        if scrollback.count > scrollbackLimit { scrollback.removeFirst(scrollback.count - scrollbackLimit) }
        lock.unlock()
        broadcaster.yield(data)
    }

    /// Forgets the scrollback (a cold boot starts a fresh console).
    func clearScrollback() {
        lock.lock(); scrollback.removeAll(keepingCapacity: true); lock.unlock()
    }
}
