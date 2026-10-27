import Foundation
import ZCore

/// One agent's view of a shared `ComputerSurface`: input goes through the team's `SurfaceLease`, screenshots and
/// surface info never wait.
///
/// Input groups: an agent's input calls form a group that keeps the lease until the agent looks at the result —
/// its next `screenshot()` — or until `Options.groupIdleTimeout` passes without further input. So a click and the
/// follow-up screenshot of one `computer` call, a modifier-held click (key down, click, key up) or a native batch
/// (click, type, Enter) are never interleaved with another agent's input. Keys and mouse buttons held down keep the
/// lease until they are released (bounded by the lease's max hold time; on expiry they are released for the agent).
/// `withLease { }` holds the lease around any multi-step sequence explicitly.
///
/// Shell commands and file reads/writes take the lease per call, or skip it when `shellOutsideLease` is set.
public actor LeasedSurface: ComputerSurface {
    public struct Options: Sendable, Hashable {
        /// Shell commands and file operations do not take the lease.
        public var shellOutsideLease: Bool
        /// Keep the lease after screen input until this agent's next screenshot (see the type documentation).
        public var holdUntilScreenshot: Bool
        /// Release a kept lease after this many seconds without input from this agent (0 = only at the next
        /// screenshot or the lease's max hold time).
        public var groupIdleTimeout: TimeInterval

        public init(shellOutsideLease: Bool = false, holdUntilScreenshot: Bool = true, groupIdleTimeout: TimeInterval = 2) {
            self.shellOutsideLease = shellOutsideLease
            self.holdUntilScreenshot = holdUntilScreenshot
            self.groupIdleTimeout = groupIdleTimeout
        }
    }

    public nonisolated let base: any ComputerSurface
    public nonisolated let lease: SurfaceLease
    /// Lease holder id (the member id in a team).
    public nonisolated let holder: String
    public nonisolated let options: Options

    private struct PressedButton {
        var button: MouseButton
        var x: Int
        var y: Int
    }

    private var groupGrant: LeaseGrant?
    private var idleTask: Task<Void, Never>?
    private var heldKeys: [String] = []
    private var pressedButtons: [PressedButton] = []
    private var registered = false

    public init(base: any ComputerSurface, lease: SurfaceLease, holder: String, options: Options = Options()) {
        self.base = base
        self.lease = lease
        self.holder = holder
        self.options = options
    }

    // MARK: Never leased

    public nonisolated var info: SurfaceInfo {
        get async { await base.info }
    }

    public nonisolated var displaySize: PixelSize {
        get async { await base.displaySize }
    }

    /// Never waits for the lease; ends this agent's input group (it has now seen the result of its input).
    public nonisolated func screenshot() async throws -> ImageData {
        let image = try await base.screenshot()
        await endGroupAfterScreenshot()
        return image
    }

    // MARK: Screen input

    public func mouseMove(x: Int, y: Int) async throws {
        let base = self.base
        try await input(screen: true) { try await base.mouseMove(x: x, y: y) }
    }

    public func click(x: Int, y: Int, button: MouseButton, count: Int) async throws {
        let base = self.base
        try await input(screen: true) { try await base.click(x: x, y: y, button: button, count: count) }
    }

    public func mouseDown(x: Int, y: Int, button: MouseButton) async throws {
        let base = self.base
        try await input(screen: true, change: .buttonDown(PressedButton(button: button, x: x, y: y))) {
            try await base.mouseDown(x: x, y: y, button: button)
        }
    }

    public func mouseUp(x: Int, y: Int, button: MouseButton) async throws {
        let base = self.base
        try await input(screen: true, change: .buttonUp(button)) {
            try await base.mouseUp(x: x, y: y, button: button)
        }
    }

    public func drag(fromX: Int, fromY: Int, toX: Int, toY: Int) async throws {
        let base = self.base
        try await input(screen: true) { try await base.drag(fromX: fromX, fromY: fromY, toX: toX, toY: toY) }
    }

    public func scroll(x: Int, y: Int, dx: Int, dy: Int) async throws {
        let base = self.base
        try await input(screen: true) { try await base.scroll(x: x, y: y, dx: dx, dy: dy) }
    }

    public func typeText(_ text: String) async throws {
        let base = self.base
        try await input(screen: true) { try await base.typeText(text) }
    }

    public func pressKeys(_ combo: String) async throws {
        let base = self.base
        try await input(screen: true) { try await base.pressKeys(combo) }
    }

    public func keyDown(_ key: String) async throws {
        let base = self.base
        try await input(screen: true, change: .keyDown(key)) { try await base.keyDown(key) }
    }

    public func keyUp(_ key: String) async throws {
        let base = self.base
        try await input(screen: true, change: .keyUp(key)) { try await base.keyUp(key) }
    }

    // MARK: Shell and files

    public func shell(_ command: String, timeout: TimeInterval) async throws -> ShellResult {
        let base = self.base
        if options.shellOutsideLease { return try await base.shell(command, timeout: timeout) }
        return try await input(screen: false) { try await base.shell(command, timeout: timeout) }
    }

    public func readFile(path: String) async throws -> Data {
        let base = self.base
        if options.shellOutsideLease { return try await base.readFile(path: path) }
        return try await input(screen: false) { try await base.readFile(path: path) }
    }

    public func writeFile(path: String, data: Data) async throws {
        let base = self.base
        if options.shellOutsideLease { return try await base.writeFile(path: path, data: data) }
        try await input(screen: false) { try await base.writeFile(path: path, data: data) }
    }

    // MARK: Explicit groups

    /// Holds the lease for the whole of `body` (e.g. click a field, then type), so no other agent's input lands in
    /// between. Calls on this surface inside `body` do not wait again. Releases afterwards, also on error.
    public func withLease<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await registerExpiryHandler()
        cancelIdleRelease()
        let grant = try await lease.acquire(holder: holder)
        do {
            let value = try await body()
            await lease.release(grant)
            await endGroup()
            return value
        } catch {
            await lease.release(grant)
            await endGroup()
            throw error
        }
    }

    /// True while this agent keeps the lease between calls (an input group or held keys / buttons).
    public var isHoldingGroup: Bool {
        get async {
            guard let g = groupGrant else { return false }
            return await lease.isValid(g)
        }
    }

    /// Keys this agent holds down (key_down without key_up yet).
    public var keysHeld: [String] { heldKeys }

    /// Gives the lease back now (keys and buttons still held keep it).
    public func endInputGroup() async {
        await endGroup()
    }

    // MARK: Internals

    /// What an input call changes about the keys / buttons this agent holds down.
    private enum HeldChange {
        case none
        case keyDown(String)
        case keyUp(String)
        case buttonDown(PressedButton)
        case buttonUp(MouseButton)
    }

    /// Runs one input call holding the lease, records held keys / buttons (presses only when the call worked,
    /// releases always), then keeps or releases the lease.
    private func input<T: Sendable>(screen: Bool, change: HeldChange = .none,
                                    _ body: @Sendable () async throws -> T) async throws -> T {
        await registerExpiryHandler()
        cancelIdleRelease()
        let grant = try await lease.acquire(holder: holder)
        let value: T
        do {
            value = try await body()
        } catch {
            apply(change, succeeded: false)
            await finishCall(grant, screen: screen)
            throw error
        }
        apply(change, succeeded: true)
        await finishCall(grant, screen: screen)
        return value
    }

    private func apply(_ change: HeldChange, succeeded: Bool) {
        switch change {
        case .none:
            break
        case .keyDown(let key):
            if succeeded, !heldKeys.contains(key) { heldKeys.append(key) }
        case .keyUp(let key):
            heldKeys.removeAll { $0 == key }
        case .buttonDown(let pressed):
            if succeeded { pressedButtons.append(pressed) }
        case .buttonUp(let button):
            if let i = pressedButtons.lastIndex(where: { $0.button == button }) { pressedButtons.remove(at: i) }
        }
    }

    /// Keeps the call's reference as the group's (screen input with `holdUntilScreenshot`, or anything held down)
    /// or releases it.
    private func finishCall(_ grant: LeaseGrant, screen: Bool) async {
        let holdingSomething = !heldKeys.isEmpty || !pressedButtons.isEmpty
        let keep = (screen && options.holdUntilScreenshot) || holdingSomething
        guard keep else {
            await lease.release(grant)
            if groupGrant != nil { scheduleIdleRelease() }
            return
        }
        if let existing = groupGrant, existing.token == grant.token {
            // The group already holds a reference to this holding.
            await lease.release(grant)
        } else {
            if let stale = groupGrant { await lease.release(stale) }
            groupGrant = grant
        }
        scheduleIdleRelease()
    }

    private func endGroupAfterScreenshot() async {
        guard groupGrant != nil else { return }
        await endGroup()
    }

    /// Releases the group's reference unless keys or buttons are still held.
    private func endGroup() async {
        guard heldKeys.isEmpty, pressedButtons.isEmpty, let g = groupGrant else { return }
        groupGrant = nil
        cancelIdleRelease()
        await lease.release(g)
    }

    private func cancelIdleRelease() {
        idleTask?.cancel()
        idleTask = nil
    }

    private func scheduleIdleRelease() {
        cancelIdleRelease()
        guard let token = groupGrant?.token, heldKeys.isEmpty, pressedButtons.isEmpty,
              options.groupIdleTimeout > 0, options.groupIdleTimeout.isFinite else { return }
        let nanos = UInt64(min(options.groupIdleTimeout, 86_400) * 1_000_000_000)
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            await self?.idleExpired(token: token)
        }
    }

    private func idleExpired(token: UInt64) async {
        guard let g = groupGrant, g.token == token else { return }
        await endGroup()
    }

    private func registerExpiryHandler() async {
        guard !registered else { return }
        registered = true
        await lease.setExpiryHandler(for: holder) { [weak self] in
            await self?.leaseExpired()
        }
    }

    /// The lease was taken back: release what this agent still holds down, directly on the base surface (the
    /// lease waits for this before the next agent gets it).
    private func leaseExpired() async {
        let keys = heldKeys
        let buttons = pressedButtons
        heldKeys.removeAll()
        pressedButtons.removeAll()
        groupGrant = nil
        cancelIdleRelease()
        for b in buttons.reversed() { try? await base.mouseUp(x: b.x, y: b.y, button: b.button) }
        for k in keys.reversed() { try? await base.keyUp(k) }
    }
}
