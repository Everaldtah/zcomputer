import Darwin
import Foundation
import Observation

/// Receives terminal output on any thread and forwards it to whichever view is attached (or buffers it).
final class TerminalOutputSink: @unchecked Sendable {
    private let lock = NSLock()
    private var receiver: (@Sendable ([UInt8]) -> Void)?
    private var scrollback: [UInt8] = []
    private let scrollbackLimit = 256 * 1024

    /// Sends future output to `receiver` after replaying what was buffered.
    func attach(_ receiver: @escaping @Sendable ([UInt8]) -> Void) {
        lock.lock()
        self.receiver = receiver
        let replay = scrollback
        lock.unlock()
        if !replay.isEmpty { receiver(replay) }
    }

    func detach() {
        lock.lock()
        receiver = nil
        lock.unlock()
    }

    func deliver(_ bytes: [UInt8]) {
        lock.lock()
        scrollback.append(contentsOf: bytes)
        if scrollback.count > scrollbackLimit { scrollback.removeFirst(scrollback.count - scrollbackLimit) }
        let target = receiver
        lock.unlock()
        target?(bytes)
    }

    func clear() {
        lock.lock()
        scrollback.removeAll()
        lock.unlock()
    }
}

/// A shell on the host Mac for the Terminal view: `/bin/zsh -l` launched with Foundation's `Process` (posix_spawn,
/// sandbox friendly: it inherits the app's sandbox) with its stdio on a pseudo-terminal from `openpty`.
/// Without a controlling terminal the shell has no job control (Ctrl-C reaches it as input, not as SIGINT).
@Observable
@MainActor
final class HostShellSession {
    private(set) var isRunning = false
    private(set) var exitStatus: Int32?
    private(set) var lastError: String?
    private(set) var title = "zsh"

    let output = TerminalOutputSink()

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var master: FileHandle?
    @ObservationIgnored private var slave: FileHandle?
    @ObservationIgnored private var size = (cols: 100, rows: 30)

    /// Starts the shell if it is not running.
    func start() {
        guard !isRunning else { return }
        lastError = nil
        exitStatus = nil
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        var window = winsize(ws_row: UInt16(clamping: size.rows), ws_col: UInt16(clamping: size.cols), ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&masterFD, &slaveFD, nil, nil, &window) == 0 else {
            lastError = "Could not open a pseudo-terminal (errno \(errno))."
            return
        }
        let masterHandle = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
        let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l"]
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        environment["TERM_PROGRAM"] = "ZComputer"
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        let sink = output
        masterHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            sink.deliver([UInt8](data))
        }
        let session = self   // lives as long as the app
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            let which = ObjectIdentifier(finished)
            Task { @MainActor in session.didExit(status: status, process: which) }
        }

        do {
            try process.run()
        } catch {
            masterHandle.readabilityHandler = nil
            lastError = "Could not start /bin/zsh: \(error.localizedDescription)"
            return
        }
        self.process = process
        self.master = masterHandle
        self.slave = slaveHandle
        isRunning = true
    }

    /// Bytes typed in the terminal view.
    func write(_ bytes: [UInt8]) {
        guard let master, isRunning else { return }
        try? master.write(contentsOf: Data(bytes))
    }

    func resize(cols: Int, rows: Int) {
        size = (cols, rows)
        guard let master else { return }
        var window = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master.fileDescriptor, TIOCSWINSZ, &window)
    }

    func terminate() {
        process?.terminate()
    }

    func restart() {
        terminate()
        tearDown()
        output.clear()
        start()
    }

    private func didExit(status: Int32, process which: ObjectIdentifier) {
        // A shell replaced by restart() reports its exit late; only the current one tears the session down.
        guard let process, ObjectIdentifier(process) == which else { return }
        exitStatus = status
        output.deliver(Array("\r\n[Process exited with status \(status). Use Restart to open a new shell.]\r\n".utf8))
        tearDown()
    }

    private func tearDown() {
        master?.readabilityHandler = nil
        master = nil
        slave = nil
        process = nil
        isRunning = false
    }
}
