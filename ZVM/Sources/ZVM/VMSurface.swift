import Foundation
import ZCore

/// The VM as a ZCore `ComputerSurface`, combining the layers of docs/research/virtualization.md §4.7:
/// * screenshots: hidden-view capture (works in firmware, installers and any desktop); the guest agent's
///   `screenshot` when preferred or when the capture stays blank;
/// * mouse/keyboard: synthetic events into the hidden view; text the US keymap cannot type goes through the
///   guest agent (`input` op, unicode via xdotool/wtype) when it is connected, or everything does when preferred;
/// * shell/files: the guest agent over vsock, else the serial console (`SerialShell`, logging in with
///   `credentials` when needed).
/// Coordinates are guest display pixels (`displaySize`).
public actor VMSurface: ComputerSurface {
    /// Login for the serial-console fallback.
    public struct Credentials: Sendable, Hashable {
        public var user: String
        public var password: String?
        public init(user: String, password: String?) { self.user = user; self.password = password }
    }

    /// Which channel to use for screenshots or input.
    public enum Route: String, Sendable, Hashable {
        /// Host-side display capture / synthetic input, with the guest agent as fallback.
        case automatic
        /// Host-side only.
        case display
        /// Guest agent only.
        case guestAgent
    }

    private let controller: VMController
    private let agent: GuestAgentClient
    private let serial: SerialShell
    private let name: String
    private let guest: GuestOS
    public private(set) var credentials: Credentials?
    public private(set) var screenshotRoute: Route = .automatic
    public private(set) var inputRoute: Route = .automatic
    /// How the last screenshot was taken ("cacheDisplay", "screenCaptureKit", "guest-agent:<tool>"), for the feed.
    public private(set) var lastScreenshotMethod = ""
    private var sysinfo: AgentSysInfo?

    public init(controller: VMController, agent: GuestAgentClient, serial: SerialShell, name: String, guest: GuestOS,
                credentials: Credentials? = nil) {
        self.controller = controller
        self.agent = agent
        self.serial = serial
        self.name = name
        self.guest = guest
        self.credentials = credentials
    }

    public func setCredentials(_ credentials: Credentials?) { self.credentials = credentials }
    public func setScreenshotRoute(_ route: Route) { screenshotRoute = route }
    public func setInputRoute(_ route: Route) { inputRoute = route }

    // MARK: Info

    public var info: SurfaceInfo {
        get async {
            let agentUp = await agent.isReachable()
            var architecture = GuestArchitecture.host.unameName
            var hasDesktop = true
            var notes: [String] = []
            if agentUp {
                if sysinfo == nil { sysinfo = try? await agent.sysinfo() }
                if let s = sysinfo {
                    if !s.arch.isEmpty { architecture = s.arch }
                    if let display = s.display { hasDesktop = display.hasSession }
                    notes.append("\(s.os.isEmpty ? "Linux" : s.os), kernel \(s.kernel), \(s.cpus) CPUs, \(s.memTotal >> 20) MiB RAM, hostname \(s.hostname).")
                }
                notes.append("Guest agent connected: shell commands, files, screenshots and unicode typing are available.")
            } else {
                sysinfo = nil
                if credentials != nil {
                    notes.append("No guest agent; shell commands go through the serial console (slower, stdout and stderr merged).")
                } else {
                    notes.append("No guest agent and no console login: use the screen, mouse and keyboard.")
                }
            }
            notes.append("Typing uses a US keyboard layout.")
            let display = await controller.displayHost.displayPixels
            notes.append("Display \(display.width)x\(display.height).")
            return SurfaceInfo(name: name, osFamily: guest == .macOS ? "macos" : "linux", architecture: architecture,
                               shellAvailable: agentUp || credentials != nil, hasDesktop: hasDesktop,
                               notes: notes.joined(separator: " "))
        }
    }

    public var displaySize: PixelSize {
        get async { await controller.displayHost.displayPixels }
    }

    // MARK: Screenshot

    public func screenshot() async throws -> ImageData {
        try await requireRunning()
        switch screenshotRoute {
        case .guestAgent:
            return try await agentScreenshot()
        case .display:
            return try await displayScreenshot(agentFallback: false)
        case .automatic:
            return try await displayScreenshot(agentFallback: true)
        }
    }

    private func displayScreenshot(agentFallback: Bool) async throws -> ImageData {
        let frame: CapturedFrame
        do {
            frame = try await controller.displayHost.capture()
        } catch {
            if agentFallback, await agent.isReachable() { return try await agentScreenshot() }
            throw error
        }
        if frame.blank, agentFallback, await agent.isReachable(), let shot = try? await agentScreenshot() {
            return shot
        }
        lastScreenshotMethod = frame.method + (frame.blank ? " (blank)" : "")
        return ImageData(mime: "image/png", data: frame.png, width: frame.width, height: frame.height)
    }

    private func agentScreenshot() async throws -> ImageData {
        do {
            let shot = try await agent.screenshot()
            lastScreenshotMethod = "guest-agent:\(shot.tool)"
            return ImageData(mime: "image/png", data: shot.png, width: shot.width, height: shot.height)
        } catch let error as GuestAgentError {
            throw error.zError
        }
    }

    // MARK: Input

    private func useAgent(forText text: String? = nil) async -> Bool {
        switch inputRoute {
        case .display:
            return false
        case .guestAgent:
            return true
        case .automatic:
            guard let text, !KeyCodes.untypableCharacters(in: text).isEmpty else { return false }
            return await agent.isReachable()
        }
    }

    private func agentInput(_ actions: [AgentInputAction]) async throws {
        do {
            try await agent.input(actions)
        } catch let error as GuestAgentError {
            throw error.zError
        }
    }

    public func mouseMove(x: Int, y: Int) async throws {
        try await requireRunning()
        if await useAgent() { return try await agentInput([.mouseMove(x: x, y: y)]) }
        try await controller.displayHost.input.mouseMove(x: x, y: y)
    }

    public func click(x: Int, y: Int, button: MouseButton, count: Int) async throws {
        try await requireRunning()
        if await useAgent() { return try await agentInput([.click(x: x, y: y, button: button, count: max(1, count))]) }
        try await controller.displayHost.input.click(x: x, y: y, button: button, count: count)
    }

    public func mouseDown(x: Int, y: Int, button: MouseButton) async throws {
        try await requireRunning()
        if await useAgent() { return try await agentInput([.mouseDown(x: x, y: y, button: button)]) }
        try await controller.displayHost.input.mouseDown(x: x, y: y, button: button)
    }

    public func mouseUp(x: Int, y: Int, button: MouseButton) async throws {
        try await requireRunning()
        if await useAgent() { return try await agentInput([.mouseUp(x: x, y: y, button: button)]) }
        try await controller.displayHost.input.mouseUp(x: x, y: y, button: button)
    }

    public func drag(fromX: Int, fromY: Int, toX: Int, toY: Int) async throws {
        try await requireRunning()
        if await useAgent() { return try await agentInput([.drag(x: fromX, y: fromY, toX: toX, toY: toY)]) }
        try await controller.displayHost.input.drag(fromX: fromX, fromY: fromY, toX: toX, toY: toY, steps: 12)
    }

    public func scroll(x: Int, y: Int, dx: Int, dy: Int) async throws {
        try await requireRunning()
        if await useAgent() {
            return try await agentInput([.scroll(x: x, y: y, dx: max(-100, min(100, dx)), dy: max(-100, min(100, dy)))])
        }
        try await controller.displayHost.input.scroll(x: x, y: y, dx: dx, dy: dy)
    }

    public func typeText(_ text: String) async throws {
        try await requireRunning()
        guard !text.isEmpty else { return }
        if await useAgent(forText: text) { return try await agentInput([.type(text)]) }
        try await controller.displayHost.input.typeText(text)
    }

    public func pressKeys(_ combo: String) async throws {
        try await requireRunning()
        if inputRoute == .guestAgent { return try await agentInput([.key(combo)]) }
        try await controller.displayHost.input.pressKeys(combo)
    }

    /// Held keys always use synthetic input (the agent protocol has no key-down op).
    public func keyDown(_ key: String) async throws {
        try await requireRunning()
        try await controller.displayHost.input.keyDown(key)
    }

    public func keyUp(_ key: String) async throws {
        try await requireRunning()
        try await controller.displayHost.input.keyUp(key)
    }

    // MARK: Shell and files

    public func shell(_ command: String, timeout: TimeInterval) async throws -> ShellResult {
        try await requireRunning()
        if await agent.isReachable() {
            do {
                return try await agent.exec(command, timeout: timeout).shellResult
            } catch let error as GuestAgentError {
                throw error.zError
            }
        }
        try await ensureSerialShell()
        return try await serial.run(command, timeout: max(5, timeout))
    }

    public func readFile(path: String) async throws -> Data {
        try await requireRunning()
        if await agent.isReachable() {
            do {
                return try await agent.readWholeFile(path: path)
            } catch let error as GuestAgentError {
                throw error.zError
            }
        }
        try await ensureSerialShell()
        return try await serial.readFile(path: path)
    }

    public func writeFile(path: String, data: Data) async throws {
        try await requireRunning()
        if await agent.isReachable() {
            do {
                try await agent.writeFile(path: path, data: data, mkdir: true)
                return
            } catch let error as GuestAgentError {
                throw error.zError
            }
        }
        try await ensureSerialShell()
        try await serial.writeFile(path: path, data: data)
    }

    // MARK: Helpers

    private func requireRunning() async throws {
        let state = await controller.state
        guard state == .running else { throw ZError.vm("the VM is \(state), not running") }
    }

    /// Makes sure a shell answers on the serial console, logging in when credentials are known.
    private func ensureSerialShell() async throws {
        if await serial.probe(timeout: 2) { return }
        guard let credentials else {
            throw ZError.unsupported("no guest agent is running and no serial-console login is configured")
        }
        try await serial.login(user: credentials.user, password: credentials.password, timeout: 120)
    }
}
