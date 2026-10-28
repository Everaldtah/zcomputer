import Foundation
import ZCore

/// One emulated machine: its `EmuHost` (web view + v86), lifecycle, saved states, autosave and serial console.
///
/// Disk model (v86 `async: true` images): the guest reads the image file lazily through the `zemu://` scheme and its
/// writes stay in memory; they are persisted only in saved states. The image file itself is never modified, which
/// is what keeps a saved state restorable (a state only restores with the pristine image it was taken with). Use
/// `stop(saveState: true)` or autosave to keep a machine's changes.
@MainActor
public final class EmuController {
    public private(set) var spec: EmuSpec
    public let store: EmuStore
    public let host: EmuHost
    /// COM1 (`ttyS0`): output stream with scrollback, and input.
    public nonisolated let console: EmuConsole
    /// The serial shell shared by every surface of this machine.
    nonisolated let shell: EmuSerialShell

    public private(set) var state: EmuRunState = .stopped
    public private(set) var screenMode: EmuScreenMode = .text(cols: 80, rows: 25)
    /// True while the guest uses v86's VMware absolute pointer (xf86-input-vmmouse / the kernel's vmmouse driver).
    public private(set) var absoluteMouseActive = false
    public private(set) var lastError: String?
    /// Outcome of the cold-boot keystrokes (`EmuSpec.bootAssist`), when they ran.
    public private(set) var bootAssistResult: String?
    /// The state the current session started from (nil after a cold boot).
    public private(set) var startedFromState: URL?
    /// Changes whenever the guest display or pointer may have changed under the host (mode switch, reset, restore).
    public private(set) var screenGeneration = 0
    /// How long `start()` waits for v86 (loading a big state takes a while on a phone).
    public var startTimeout: TimeInterval = 240
    /// After resuming a saved state, set the guest clock over the serial shell (`date -s`) when one answers.
    public var syncClockAfterRestore = true

    private let stateBroadcaster = EmuBroadcaster<EmuRunState>(replaysLatest: true, bufferLimit: 64)
    private let eventBroadcaster = EmuBroadcaster<EmuHostEvent>(replaysLatest: false, bufferLimit: 1024)
    private var emulatorStarted = false
    private var startFailure: String?
    private var cdromOverride: URL??
    private var recovering = false
    private var savingNow = false
    private var autosaveTask: Task<Void, Never>?
    private var autosaveInterval: TimeInterval?
    private var observers: [any NSObjectProtocol] = []
    private var observerCenter: NotificationCenter?
    private var serialOutbox: [Data] = []
    private var serialPump: Task<Void, Never>?

    public init(spec: EmuSpec, store: EmuStore) {
        self.spec = spec
        self.store = store
        self.host = EmuHost(frame: CGRect(x: 0, y: 0, width: spec.screen.width, height: spec.screen.height))
        self.console = EmuConsole()
        self.shell = EmuSerialShell(transport: console)
        host.onEvent = { [weak self] event in self?.handle(event) }
        console.setSink { [weak self] data in self?.sendSerial(data) }
    }

    /// The live screen (`WKWebView`). Keep it in a window while the machine runs (see `EmuHost`).
    public var view: EmuPlatformView { host.view }

    /// Pixel size of the guest display (the coordinate space of `EmuSurface`).
    public var displaySize: PixelSize { screenMode.pixelSize }

    /// State changes (the current state first).
    public var stateUpdates: AsyncStream<EmuRunState> { stateBroadcaster.stream() }

    /// Everything the page reports (download progress, logs, screen modes, ...), from now on.
    public func events() -> AsyncStream<EmuHostEvent> { eventBroadcaster.stream() }

    /// True when a saved state from an earlier session exists (`start()` resumes it).
    public var hasAutosave: Bool { FileManager.default.fileExists(atPath: store.autosaveStateURL(spec.id).path) }

    // MARK: Lifecycle

    /// Starts the machine. It resumes the autosave of an earlier session unless `fresh`; otherwise it starts from
    /// `state` when given, else from the spec (its saved state, or a cold boot of its ISO / disk).
    public func start(from state: URL? = nil, fresh: Bool = false) async throws {
        switch self.state {
        case .stopped, .error: break
        default: return
        }
        lastError = nil
        bootAssistResult = nil
        setState(.starting)
        do {
            try await launch(stateOverride: state, fresh: fresh)
            setState(.running)
            startAutosaveTimer()
        } catch {
            let message = "\(error)"
            lastError = message
            _ = try? await host.call("destroy")
            setState(.error(message))
            throw error
        }
    }

    /// Stops the machine. With `saveState`, the autosave is written first so the next `start()` resumes exactly
    /// here; without, the autosave is discarded so the next start boots afresh (or from the spec's saved state).
    public func stop(saveState: Bool = false) async {
        guard state.isActive else { return }
        stopAutosaveTimer()
        let autosave = store.autosaveStateURL(spec.id)
        if saveState, state == .running || state == .paused {
            do { try await self.saveState(to: autosave) } catch { lastError = "autosave failed: \(error)" }
        } else if !saveState {
            try? FileManager.default.removeItem(at: autosave)
        }
        _ = try? await host.call("destroy")
        await shell.invalidate()
        host.schemeHandler.unregisterAll()
        absoluteMouseActive = false
        setState(.stopped)
    }

    public func pause() async throws {
        guard state == .running else { return }
        try await host.call("pause")
        setState(.paused)
    }

    public func resume() async throws {
        guard state == .paused else { return }
        try await host.call("resume")
        setState(.running)
    }

    /// Reboots the guest (v86 `restart`, like the reset button).
    public func resetMachine() async throws {
        try requireActive()
        try await host.call("reset")
        absoluteMouseActive = false
        screenGeneration += 1
        await shell.invalidate()
    }

    // MARK: Saved states

    /// Saves the machine (CPU, RAM, devices and the guest's disk writes) to `destination` (a new timestamped file
    /// in the machine's `states/` folder by default) and returns it. The machine keeps running.
    @discardableResult
    public func saveState(to destination: URL? = nil) async throws -> URL {
        guard state == .running || state == .paused else { throw ZError.vm("cannot save: the machine is \(state.label.lowercased())") }
        guard !savingNow else { throw ZError.vm("a save is already in progress") }
        savingNow = true
        let previous = state
        setState(.saving)
        defer {
            savingNow = false
            if state == .saving { setState(previous) }
        }
        let url = destination ?? store.newStateURL(spec.id)
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = url.appendingPathExtension("partial")
        try? fm.removeItem(at: partial)
        let total = try await host.call("saveState").intValue ?? 0
        guard total > 0 else { throw ZError.vm("v86 returned an empty state") }
        _ = fm.createFile(atPath: partial.path, contents: nil)
        do {
            let handle = try FileHandle(forWritingTo: partial)
            defer { try? handle.close() }
            let chunk = 4 << 20
            var offset = 0
            while offset < total {
                let length = min(chunk, total - offset)
                let reply = try await host.call("stateChunk", [.number(Double(offset)), .number(Double(length))])
                guard let text = reply.stringValue, let data = Data(base64Encoded: text), data.count == length else {
                    throw ZError.vm("state transfer failed at byte \(offset)")
                }
                try handle.write(contentsOf: data)
                offset += length
            }
            try handle.synchronize()
        } catch {
            _ = try? await host.call("releaseState")
            try? fm.removeItem(at: partial)
            throw error
        }
        _ = try? await host.call("releaseState")
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try fm.moveItem(at: partial, to: url)
        return url
    }

    /// Restores a saved state into the running machine. The state must come from this v86 build and a machine with
    /// the same memory, VGA memory, devices and disk images.
    public func restoreState(_ url: URL) async throws {
        try requireActive()
        guard FileManager.default.fileExists(atPath: url.path) else { throw ZError.notFound(url.path) }
        try await host.call("restoreState", [.string(host.registerFile(url))])
        screenGeneration += 1
        absoluteMouseActive = false
        await shell.invalidate()
        startedFromState = url
        if syncClockAfterRestore { Task { await self.syncGuestClock() } }
    }

    // MARK: CD-ROM

    /// Inserts an ISO into the CD-ROM drive (also used by later starts unless the machine boots another ISO).
    public func attachISO(_ url: URL) async throws {
        let size = try emuFileSize(url)
        if state.isActive {
            try await host.call("insertCD", [.string(host.registerFile(url)), .number(Double(size))])
        }
        cdromOverride = .some(url)
        if case .iso = spec.boot {} else {
            spec.cdrom = url
            try? store.save(spec)
        }
    }

    /// Ejects the CD-ROM. For a machine that boots an ISO this lasts for the session only.
    public func detachISO() async throws {
        if state.isActive { try await host.call("ejectCD") }
        cdromOverride = .some(nil)
        if spec.cdrom != nil {
            spec.cdrom = nil
            try? store.save(spec)
        }
    }

    // MARK: Autosave

    /// Saves to `states/autosave.v86state` every `interval` seconds while running, and whenever one of
    /// `notifications` is posted (e.g. `UIApplication.willResignActiveNotification`; request background time in the
    /// app around it, iOS suspends WebKit soon after the app leaves the foreground).
    public func enableAutosave(interval: TimeInterval?, saveOn notifications: [Notification.Name] = [],
                               center: NotificationCenter = .default) {
        removeObservers()
        autosaveInterval = interval
        observerCenter = center
        observers = notifications.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.autosaveNow() }
            }
        }
        if state == .running { startAutosaveTimer() }
    }

    /// Starts an autosave now (no-op unless running or paused).
    public func autosaveNow() {
        guard state == .running || state == .paused, !savingNow else { return }
        let url = store.autosaveStateURL(spec.id)
        Task { [weak self] in
            guard let self else { return }
            do { try await self.saveState(to: url) } catch { self.lastError = "autosave failed: \(error)" }
        }
    }

    private func removeObservers() {
        if let center = observerCenter { for o in observers { center.removeObserver(o) } }
        observers = []
    }

    private func startAutosaveTimer() {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard let interval = autosaveInterval, interval > 0 else { return }
        autosaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                if self.state == .running { self.autosaveNow() }
            }
        }
    }

    private func stopAutosaveTimer() {
        autosaveTask?.cancel()
        autosaveTask = nil
    }

    // MARK: Surface

    /// A `ComputerSurface` for agents (and the touch layer). Surfaces of one machine share its serial shell.
    public func makeSurface() -> EmuSurface {
        EmuSurface(controller: self, credentials: spec.serialLogin, sensitivity: spec.mouseSensitivity, screen: displaySize)
    }

    // MARK: Launch

    private func launch(stateOverride: URL?, fresh: Bool) async throws {
        try await host.loadPage()
        host.schemeHandler.unregisterAll()
        var initial = stateOverride
        if initial == nil, !fresh, hasAutosave { initial = store.autosaveStateURL(spec.id) }
        if initial == nil { initial = spec.initialState }

        let cdImage: URL? = cdromOverride ?? spec.cdromImage
        var cdrom: EmuLaunchConfig.Disk?
        if let cdImage { cdrom = .init(url: host.registerFile(cdImage), size: try emuFileSize(cdImage)) }
        var hda: EmuLaunchConfig.Disk?
        if let disk = spec.diskImage { hda = .init(url: host.registerFile(disk), size: try emuFileSize(disk)) }
        if let initial, !FileManager.default.fileExists(atPath: initial.path) { throw ZError.notFound(initial.path) }
        let stateURL = initial.map { host.registerFile($0) }
        let config = try EmuLaunchConfig.make(spec: spec, cdrom: cdrom, hda: hda, initialState: stateURL)

        emulatorStarted = false
        startFailure = nil
        absoluteMouseActive = false
        screenMode = .text(cols: 80, rows: 25)
        screenGeneration += 1
        if initial == nil { console.clearScrollback() }
        await shell.invalidate()
        try await host.call("start", [try JSONValue(encoding: config)])

        let deadline = Date().addingTimeInterval(startTimeout)
        while !emulatorStarted {
            if let startFailure { throw ZError.vm(startFailure) }
            if !host.isPageLoaded { throw ZError.vm("the web content process ended while the machine was starting") }
            if Date() > deadline { throw ZError.vm("the emulator did not start within \(Int(startTimeout)) s") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        startedFromState = initial
        if initial != nil, syncClockAfterRestore { Task { await self.syncGuestClock() } }
        if spec.shareDirectory != nil, spec.enable9p {
            Task {
                do { try await self.seedShare() } catch { self.lastError = "share: \(error)" }
            }
        }
    }

    // MARK: Events

    private func handle(_ event: EmuHostEvent) {
        switch event {
        case .serial(let data):
            console.publish(data)
        case .screenSize(let w, let h, let bpp):
            let mode: EmuScreenMode = bpp > 0 ? .graphical(width: w, height: h, bpp: bpp) : .text(cols: w, rows: h)
            if mode != screenMode {
                screenMode = mode
                screenGeneration += 1
            }
        case .absoluteMouse(let on):
            absoluteMouseActive = on
        case .started:
            emulatorStarted = true
        case .error(let message):
            lastError = message
            if state == .starting { startFailure = message }
        case .bootAssist(let ok, let detail):
            bootAssistResult = (ok ? "ok: " : "failed: ") + detail
        case .processTerminated:
            recoverFromTermination()
        case .pageLoaded, .ready, .loaded, .stopped, .progress, .log:
            break
        }
        eventBroadcaster.yield(event)
    }

    /// WebKit killed the web-content process (memory): reload the page and resume the last autosave (or the spec's
    /// starting point).
    private func recoverFromTermination() {
        guard !recovering, state == .running || state == .paused || state == .saving else { return }
        recovering = true
        lastError = "the emulator's web content process ended (memory pressure?); restarting from the last autosave"
        stopAutosaveTimer()
        setState(.starting)
        Task { [weak self] in
            guard let self else { return }
            defer { self.recovering = false }
            do {
                try await self.host.reloadPage()
                try await self.launch(stateOverride: nil, fresh: false)
                self.setState(.running)
                self.startAutosaveTimer()
            } catch {
                self.setState(.error("restart after a web content crash failed: \(error)"))
            }
        }
    }

    private func setState(_ new: EmuRunState) {
        state = new
        stateBroadcaster.yield(new)
    }

    func requireActive() throws {
        guard state == .running || state == .paused || state == .saving else {
            throw ZError.vm("the machine is \(state.label.lowercased())")
        }
    }

    func requireRunning() throws {
        guard state == .running || state == .saving else {
            throw ZError.vm("the machine is \(state.label.lowercased()), not running")
        }
    }

    // MARK: Serial input (ordered)

    private func sendSerial(_ data: Data) {
        serialOutbox.append(data)
        guard serialPump == nil else { return }
        serialPump = Task { [weak self] in
            while let self, !self.serialOutbox.isEmpty {
                var chunk = Data()
                for d in self.serialOutbox { chunk.append(d) }
                self.serialOutbox.removeAll()
                _ = try? await self.host.call("serialSend", [.string(chunk.base64EncodedString())])
            }
            self?.serialPump = nil
        }
    }

    // MARK: Guest helpers

    /// Sets the guest clock from the host after a restore (states resume with the clock of the moment they were
    /// saved). Best effort, only when a shell already answers on the console.
    private func syncGuestClock() async {
        guard spec.serial, state == .running else { return }
        guard await shell.probe(timeout: 6) else { return }
        let now = Int(Date().timeIntervalSince1970)
        // Choose sudo by uid, not by date's exit status: BusyBox `date -s` run by a normal user prints "can't set
        // date" but still exits 0 (Z Alpine Desktop's serial console is a shell of user z).
        let set = "date -s @\(now)"
        _ = try? await shell.run("{ if [ \"$(id -u)\" = 0 ]; then \(set); else sudo -n \(set); fi; } >/dev/null 2>&1",
                                 timeout: 20)
    }

    /// Copies `shareDirectory` into the 9p filesystem (files that are not there yet; at most 256 MB).
    private func seedShare() async throws {
        guard let dir = spec.shareDirectory else { return }
        let scoped = dir.startAccessingSecurityScopedResource()
        defer { if scoped { dir.stopAccessingSecurityScopedResource() } }
        for (relative, url) in Self.shareFiles(in: dir, budget: 256 << 20) {
            guard state.isActive else { return }
            if try await ninePExists(path: relative) { continue }
            try await ninePWrite(path: relative, data: try Data(contentsOf: url))
        }
    }

    /// Regular files under `dir` (relative paths starting with "/"), up to `budget` bytes in all.
    nonisolated static func shareFiles(in dir: URL, budget: Int) -> [(String, URL)] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                         options: [.skipsHiddenFiles]) else { return [] }
        var remaining = budget
        let base = dir.standardizedFileURL.path
        var files: [(String, URL)] = []
        while let next = walker.nextObject() as? URL {
            let values = try? next.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            let size = values?.fileSize ?? 0
            guard size <= remaining else { continue }
            let path = next.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            remaining -= size
            files.append((String(path.dropFirst(base.count)), next))
        }
        return files
    }

    // MARK: Page commands used by EmuSurface

    func sendKeys(_ groups: [[UInt8]], delayMs: Int) async throws {
        guard !groups.isEmpty else { return }
        try requireRunning()
        try await host.call("keys", [try JSONValue(encoding: groups), .number(Double(delayMs))])
    }

    func sendMouseDeltas(_ deltas: [MouseDelta], delayMs: Int) async throws {
        guard !deltas.isEmpty else { return }
        try requireRunning()
        let pairs: [[Int]] = deltas.map { [$0.dx, $0.dy] }
        try await host.call("mouseDeltas", [try JSONValue(encoding: pairs), .number(Double(delayMs))])
    }

    func sendMouseAbsolute(_ p: PixelPoint) async throws {
        try requireRunning()
        let args = CursorTracker.absoluteArguments(for: p, screen: displaySize).map { JSONValue.number($0) }
        try await host.call("mouseAbsolute", args)
    }

    func sendMouseButtons(left: Bool, middle: Bool, right: Bool) async throws {
        try requireRunning()
        try await host.call("mouseButtons", [.bool(left), .bool(middle), .bool(right)])
    }

    func sendWheel(ticks: Int, delayMs: Int) async throws {
        guard ticks != 0 else { return }
        try requireRunning()
        try await host.call("wheel", [.number(Double(ticks)), .number(Double(delayMs))])
    }

    func pageScreenshot() async throws -> EmuPageScreenshot {
        try requireActive()
        let reply = try await host.call("screenshot")
        var png: Data?
        if let dataURL = reply["dataURL"]?.stringValue, let comma = dataURL.firstIndex(of: ",") {
            png = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
        }
        let size = PixelSize(width: reply["width"]?.intValue ?? displaySize.width,
                             height: reply["height"]?.intValue ?? displaySize.height)
        return EmuPageScreenshot(png: png, graphical: reply["graphical"]?.boolValue ?? screenMode.isGraphical, size: size)
    }

    /// The VGA text screen, one string per row (meaningful in text modes).
    public func textScreen() async throws -> [String] {
        try requireActive()
        let reply = try await host.call("textScreen")
        return reply["lines"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    func ninePExists(path: String) async throws -> Bool {
        try await host.call("fsExists", [.string(path)]).boolValue ?? false
    }

    func ninePWrite(path: String, data: Data) async throws {
        try requireActive()
        let chunk = 2 << 20
        var offset = 0
        var first = true
        repeat {
            let end = min(data.count, offset + chunk)
            let piece = data.subdata(in: data.startIndex + offset ..< data.startIndex + end)
            try await host.call("fsPut", [.string(path), .string(piece.base64EncodedString()), .bool(first)])
            first = false
            offset = end
        } while offset < data.count
        try await host.call("fsCommit", [.string(path)])
    }

    func ninePRead(path: String) async throws -> Data {
        try requireActive()
        let total = try await host.call("fsRead", [.string(path)]).intValue ?? 0
        var out = Data()
        out.reserveCapacity(total)
        let chunk = 2 << 20
        var offset = 0
        do {
            while offset < total {
                let length = min(chunk, total - offset)
                let reply = try await host.call("fileChunk", [.number(Double(offset)), .number(Double(length))])
                guard let text = reply.stringValue, let data = Data(base64Encoded: text) else {
                    throw ZError.vm("9p read of \(path) failed at byte \(offset)")
                }
                out.append(data)
                offset += length
            }
        } catch {
            _ = try? await host.call("releaseFile")
            throw error
        }
        _ = try? await host.call("releaseFile")
        return out
    }

    func ninePMkdir(path: String) async throws {
        try await host.call("fsMkdir", [.string(path)])
    }

    func ninePDelete(path: String) async throws {
        try await host.call("fsDelete", [.string(path)])
    }
}
