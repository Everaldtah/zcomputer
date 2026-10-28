import Foundation
import ZCore

/// An emulated machine as a ZCore `ComputerSurface`, so ZAgent drives v86 exactly like a ZVM virtual machine:
///
/// * **screenshots:** v86's own framebuffer (`screen_make_screenshot` after refreshing the canvas, so it works while
///   the view is not on screen); VGA text modes come from v86's text renderer, or from `screen_get_text`-style rows
///   rendered here when that is blank;
/// * **keyboard:** PS/2 scan code set 1 (`ScanCodes`), US layout; text a US keyboard cannot type goes through
///   `xdotool type` on the serial shell when the guest has a desktop;
/// * **mouse:** v86's VMware absolute pointer when the guest enabled it (`mouse-absolute` + a `mouse-click` that
///   raises IRQ 12); otherwise the relative PS/2 mouse with host-side cursor tracking (`CursorTracker`: home to
///   (0, 0), then move by the distance); or `xdotool` on the serial shell when chosen with `setMouseRoute`;
/// * **shell and files:** the sentinel serial shell on COM1 (`EmuSerialShell`), logging in with `credentials` when
///   needed; file transfers use v86's 9p filesystem (mounted at `/mnt/host`, tag `host9p`) when the guest can mount
///   it, else base64 over the serial line.
///
/// Coordinates are guest display pixels (`displaySize`; 9x16 pixels per character in text modes).
public actor EmuSurface: ComputerSurface {
    /// How pointer positions reach the guest.
    public enum MouseRoute: String, Sendable, Hashable, Codable {
        /// The VMware absolute pointer when the guest uses it, else relative tracking.
        case automatic
        case vmwareAbsolute
        case relative
        /// `xdotool mousemove/click` over the serial shell (X desktops; exact but slower).
        case guestXdotool
    }

    private let controller: EmuController
    private let shellChannel: EmuSerialShell
    private var tracker: CursorTracker
    private var trackerGeneration = -1
    private var preferAbsolute = true
    public private(set) var mouseRoute: MouseRoute = .automatic
    public private(set) var credentials: EmuCredentials?
    /// How the last pointer move was done ("vmware-absolute", "relative", "xdotool"), for the activity feed.
    public private(set) var lastMouseMethod = ""
    /// How the last screenshot was taken ("framebuffer", "text-render").
    public private(set) var lastScreenshotMethod = ""
    /// Milliseconds between typed keystrokes.
    public private(set) var typingDelayMs = 8
    /// Milliseconds between relative mouse packets.
    public private(set) var mouseStepDelayMs = 4
    /// Re-home the relative pointer before every move (no accumulated error; costs ~20 extra packets).
    public private(set) var rehomeEveryMove = true
    private var buttons: (left: Bool, middle: Bool, right: Bool) = (false, false, false)
    private var desktopCache: (value: Bool, at: Date)?
    private var ninePReady: Bool?
    private var ninePGeneration = -1
    private var shellBusy = false
    private var probedShell = false

    public init(controller: EmuController, credentials: EmuCredentials? = nil, sensitivity: Double = 1.0,
                screen: PixelSize = PixelSize(width: 1024, height: 768)) {
        self.controller = controller
        self.shellChannel = controller.shell
        self.credentials = credentials
        self.tracker = CursorTracker(screen: screen, sensitivity: sensitivity)
    }

    // MARK: Settings

    /// Use the VMware absolute pointer when the guest supports it (default true); false forces relative tracking.
    public func setAbsoluteMouse(_ enabled: Bool) { preferAbsolute = enabled }
    public func setMouseRoute(_ route: MouseRoute) { mouseRoute = route }
    /// Guest pixels per PS/2 count for relative tracking.
    public func setMouseSensitivity(_ sensitivity: Double) {
        tracker.sensitivity = sensitivity > 0 ? sensitivity : 1
        tracker.invalidate()
    }
    public func setCredentials(_ credentials: EmuCredentials?) { self.credentials = credentials }
    public func setTypingDelay(milliseconds: Int) { typingDelayMs = max(0, milliseconds) }
    public func setRehomeEveryMove(_ value: Bool) { rehomeEveryMove = value }

    /// The relative tracker's current estimate (nil before the first move).
    public var estimatedCursor: PixelPoint? { tracker.position }

    // MARK: Info

    public var info: SurfaceInfo {
        get async {
            let spec = await controller.spec
            let mode = await controller.screenMode
            let absolute = await controller.absoluteMouseActive
            let running = await controller.state == .running
            var shellReady = await shellChannel.isReady
            if !shellReady, running, spec.serial, !probedShell, !shellBusy {
                probedShell = true
                shellReady = await shellChannel.probe(timeout: 3)
            }
            let desktop = await detectDesktop()
            var notes: [String] = ["32-bit x86 PC emulated by v86 (WebAssembly JIT, no hardware virtualisation): "
                + "expect a few hundred MIPS at best, so give programs time and prefer light tools."]
            switch mode {
            case .text(let cols, let rows):
                notes.append("Display: VGA text mode \(cols)x\(rows) (screenshots \(cols * 9)x\(rows * 16) px).")
            case .graphical(let w, let h, let bpp):
                notes.append("Display \(w)x\(h)x\(bpp).")
            }
            notes.append(absolute ? "Pointer: absolute (VMware), exact."
                                  : "Pointer: relative PS/2 mouse; positions are estimated (check screenshots).")
            if spec.serial {
                notes.append(shellReady || credentials != nil
                    ? "Shell commands run on the serial console ttyS0 (slower than a terminal, stdout and stderr merged)."
                    : "No shell on the serial console yet: use the screen, mouse and keyboard.")
            }
            notes.append("Typing uses a US keyboard layout.")
            return SurfaceInfo(name: spec.name, osFamily: "linux", architecture: "x86",
                               shellAvailable: spec.serial && (shellReady || credentials != nil),
                               hasDesktop: desktop, notes: notes.joined(separator: " "))
        }
    }

    public var displaySize: PixelSize {
        get async { await controller.displaySize }
    }

    // MARK: Screen

    public func screenshot() async throws -> ImageData {
        let shot = try await controller.pageScreenshot()
        if let png = shot.png, let image = EmuImageTools.decode(png), shot.graphical || !EmuImageTools.isBlank(image) {
            lastScreenshotMethod = "framebuffer"
            return ImageData(mime: "image/png", data: png, width: image.width, height: image.height)
        }
        if !shot.graphical {
            let lines = try await controller.textScreen()
            if !lines.isEmpty {
                lastScreenshotMethod = "text-render"
                let cols = lines.map(\.count).max() ?? 80
                return try EmuImageTools.renderText(lines, cols: max(cols, 1))
            }
        }
        if let png = shot.png {
            lastScreenshotMethod = "framebuffer (blank)"
            return ImageData(mime: "image/png", data: png, width: shot.size.width, height: shot.size.height)
        }
        throw ZError.vm("the emulator returned no screenshot")
    }

    /// The VGA text screen as text (text modes; empty rows trimmed at the end).
    public func screenText() async throws -> String {
        var lines = try await controller.textScreen().map { $0.replacingOccurrences(of: "\u{0}", with: " ") }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }.joined(separator: "\n")
    }

    // MARK: Mouse

    public func mouseMove(x: Int, y: Int) async throws {
        try await moveTo(x, y)
    }

    public func click(x: Int, y: Int, button: MouseButton, count: Int) async throws {
        let route = try await moveTo(x, y)
        let n = max(1, count)
        if route == .guestXdotool {
            try await xdotool("click --repeat \(n) --delay 80 \(Self.xButton(button))")
            return
        }
        for i in 0..<n {
            try await setButton(button, down: true)
            try await Task.sleep(nanoseconds: 40_000_000)
            try await setButton(button, down: false)
            if i < n - 1 { try await Task.sleep(nanoseconds: 80_000_000) }
        }
    }

    public func mouseDown(x: Int, y: Int, button: MouseButton) async throws {
        let route = try await moveTo(x, y)
        if route == .guestXdotool { return try await xdotool("mousedown \(Self.xButton(button))") }
        try await setButton(button, down: true)
    }

    public func mouseUp(x: Int, y: Int, button: MouseButton) async throws {
        let route = try await moveTo(x, y)
        if route == .guestXdotool { return try await xdotool("mouseup \(Self.xButton(button))") }
        try await setButton(button, down: false)
    }

    public func drag(fromX: Int, fromY: Int, toX: Int, toY: Int) async throws {
        let route = try await moveTo(fromX, fromY)
        if route == .guestXdotool {
            try await xdotool("mousedown 1 mousemove --sync \(toX) \(toY) mouseup 1")
            return
        }
        try await setButton(.left, down: true)
        try await Task.sleep(nanoseconds: 60_000_000)
        let steps = 12
        for i in 1...steps {
            let x = fromX + (toX - fromX) * i / steps
            let y = fromY + (toY - fromY) * i / steps
            try await moveTo(x, y)
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        try await Task.sleep(nanoseconds: 60_000_000)
        try await setButton(.left, down: false)
    }

    public func scroll(x: Int, y: Int, dx: Int, dy: Int) async throws {
        let route = try await moveTo(x, y)
        let vertical = max(-50, min(50, dy)), horizontal = max(-50, min(50, dx))
        if route == .guestXdotool {
            if vertical != 0 { try await xdotool("click --repeat \(abs(vertical)) \(vertical > 0 ? 5 : 4)") }
            if horizontal != 0 { try await xdotool("click --repeat \(abs(horizontal)) \(horizontal > 0 ? 7 : 6)") }
            return
        }
        if vertical != 0 { try await controller.sendWheel(ticks: vertical, delayMs: 20) }
        if horizontal != 0 {
            // PS/2 wheels are vertical only; Shift+wheel scrolls sideways in GTK, Qt and browsers.
            try await controller.sendKeys([ScanCodes.leftShift.make], delayMs: 0)
            try await controller.sendWheel(ticks: horizontal, delayMs: 20)
            try await controller.sendKeys([ScanCodes.leftShift.release], delayMs: 0)
        }
    }

    /// Moves the pointer; returns the route used.
    @discardableResult
    private func moveTo(_ x: Int, _ y: Int) async throws -> MouseRoute {
        try await controller.requireRunning()
        let size = await controller.displaySize
        let generation = await controller.screenGeneration
        if size != tracker.screen || generation != trackerGeneration {
            tracker.screen = size
            tracker.invalidate()
            trackerGeneration = generation
        }
        let target = tracker.clamp(PixelPoint(x: x, y: y))
        let route = await resolvedRoute()
        switch route {
        case .vmwareAbsolute:
            try await controller.sendMouseAbsolute(target)
            tracker.assume(target)
            lastMouseMethod = "vmware-absolute"
        case .guestXdotool:
            try await xdotool("mousemove --sync \(target.x) \(target.y)")
            tracker.assume(target)
            lastMouseMethod = "xdotool"
        case .relative, .automatic:
            // Never re-home while a button is held: that would drag to the corner.
            let anyDown = buttons.left || buttons.middle || buttons.right
            let packets = tracker.move(to: target, rehome: rehomeEveryMove && !anyDown)
            try await controller.sendMouseDeltas(packets, delayMs: mouseStepDelayMs)
            lastMouseMethod = "relative"
        }
        return route
    }

    private func resolvedRoute() async -> MouseRoute {
        guard mouseRoute == .automatic else { return mouseRoute }
        if preferAbsolute, await controller.absoluteMouseActive { return .vmwareAbsolute }
        return .relative
    }

    private func setButton(_ button: MouseButton, down: Bool) async throws {
        switch button {
        case .left: buttons.left = down
        case .middle: buttons.middle = down
        case .right: buttons.right = down
        }
        try await controller.sendMouseButtons(left: buttons.left, middle: buttons.middle, right: buttons.right)
    }

    static func xButton(_ button: MouseButton) -> Int {
        switch button {
        case .left: return 1
        case .middle: return 2
        case .right: return 3
        }
    }

    // MARK: Keyboard

    public func typeText(_ text: String) async throws {
        try await controller.requireRunning()
        guard !text.isEmpty else { return }
        let untypable = ScanCodes.untypableCharacters(in: text)
        if !untypable.isEmpty {
            if await detectDesktop(), await shellAnswers() {
                let b64 = Data(text.utf8).base64EncodedString()
                try await xdotoolScript("printf %s '\(b64)' | base64 -d | xdotool type --delay 15 --file -")
                return
            }
            throw ZError.unsupported("cannot type \(untypable.map { "\"\($0)\"" }.joined(separator: ", ")) with the "
                + "emulated US keyboard and no desktop shell is available for xdotool")
        }
        let groups = try ScanCodes.typing(text)
        var index = 0
        while index < groups.count {
            let end = min(groups.count, index + 200)
            try await controller.sendKeys(Array(groups[index..<end]), delayMs: typingDelayMs)
            index = end
            if index < groups.count { try await Task.sleep(nanoseconds: UInt64(typingDelayMs) * 1_000_000) }
        }
    }

    public func pressKeys(_ combo: String) async throws {
        try await controller.requireRunning()
        try await controller.sendKeys(try ScanCodes.scancodes(forKeys: combo), delayMs: 30)
    }

    public func keyDown(_ key: String) async throws {
        try await controller.requireRunning()
        guard let k = ScanCodes.anyKey(named: key) else { throw ZError.invalidArgument("unknown key \"\(key)\"") }
        try await controller.sendKeys([k.make], delayMs: 0)
    }

    public func keyUp(_ key: String) async throws {
        try await controller.requireRunning()
        guard let k = ScanCodes.anyKey(named: key) else { throw ZError.invalidArgument("unknown key \"\(key)\"") }
        guard !k.release.isEmpty else { return }
        try await controller.sendKeys([k.release], delayMs: 0)
    }

    // MARK: Shell and files

    public func shell(_ command: String, timeout: TimeInterval) async throws -> ShellResult {
        try await controller.requireRunning()
        return try await exclusive {
            try await self.ensureShell()
            return try await self.shellChannel.run(command, timeout: max(5, timeout))
        }
    }

    public func readFile(path: String) async throws -> Data {
        try await controller.requireRunning()
        return try await exclusive {
            try await self.ensureShell()
            if await self.ninePAvailable() {
                let name = "/.zx/r" + Self.nonce()
                let r = try await self.shellChannel.run("cp -- \(emuShellQuote(path)) /mnt/host\(name)", timeout: 300)
                guard r.exitCode == 0 else { throw ZError.vm("cannot read \(path): \(r.stdout.prefix(300))") }
                do {
                    let data = try await self.controller.ninePRead(path: name)
                    try? await self.controller.ninePDelete(path: name)
                    return data
                } catch {
                    try? await self.controller.ninePDelete(path: name)
                }
            }
            return try await self.shellChannel.readFile(path: path)
        }
    }

    public func writeFile(path: String, data: Data) async throws {
        try await controller.requireRunning()
        try await exclusive {
            try await self.ensureShell()
            if await self.ninePAvailable() {
                let name = "/.zx/w" + Self.nonce()
                let q = emuShellQuote(path)
                var staged = false
                do {
                    try await self.controller.ninePWrite(path: name, data: data)
                    staged = true
                } catch {
                    staged = false
                }
                if staged {
                    let r = try await self.shellChannel.run(
                        "mkdir -p \"$(dirname \(q))\" && cp -- /mnt/host\(name) \(q); s=$?; rm -f /mnt/host\(name); exit $s",
                        timeout: 300)
                    guard r.exitCode == 0 else { throw ZError.vm("cannot write \(path): \(r.stdout.prefix(300))") }
                    return
                }
            }
            try await self.shellChannel.writeFile(path: path, data: data)
        }
    }

    /// Runs `body` with the serial shell to itself (the agent may call tools concurrently; the console is one line).
    private func exclusive<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        while shellBusy { try await Task.sleep(nanoseconds: 20_000_000) }
        shellBusy = true
        defer { shellBusy = false }
        return try await body()
    }

    /// Makes sure a shell answers on the serial console, logging in when credentials are known.
    private func ensureShell() async throws {
        guard await controller.spec.serial else { throw ZError.unsupported("this machine has no serial console") }
        if await shellChannel.probe(timeout: 3) { return }
        guard let credentials else {
            throw ZError.unsupported("no shell answers on the serial console (ttyS0) and no login is configured; "
                + "use the screen, mouse and keyboard")
        }
        try await shellChannel.login(user: credentials.user, password: credentials.password, timeout: 150)
    }

    private func shellAnswers() async -> Bool {
        guard await controller.spec.serial else { return false }
        if await shellChannel.isReady { return true }
        return (try? await exclusive { try await self.ensureShell() }) != nil
    }

    /// Mounts v86's 9p filesystem at /mnt/host when needed; true when it is mounted (cached per guest session).
    private func ninePAvailable() async -> Bool {
        guard await controller.spec.enable9p else { return false }
        let generation = await controller.screenGeneration
        if let ninePReady, ninePGeneration == generation { return ninePReady }
        try? await controller.ninePMkdir(path: "/.zx")
        let command = "mountpoint -q /mnt/host 2>/dev/null || { S=; [ \"$(id -u)\" = 0 ] || S='sudo -n'; "
            + "$S mkdir -p /mnt/host && $S mount -t 9p -o trans=virtio,version=9p2000.L host9p /mnt/host; } >/dev/null 2>&1; "
            + "[ -d /mnt/host/.zx ] && echo Z9P_OK"
        let r = try? await shellChannel.run(command, timeout: 30)
        let ok = r?.stdout.contains("Z9P_OK") ?? false
        ninePReady = ok
        ninePGeneration = generation
        return ok
    }

    /// True when an X server runs in the guest (`pgrep -x Xorg`), else whether the display is in a graphics mode.
    private func detectDesktop() async -> Bool {
        if let cache = desktopCache, Date().timeIntervalSince(cache.at) < 30 { return cache.value }
        var value = await controller.screenMode.isGraphical
        if await shellChannel.isReady, !shellBusy,
           let r = try? await exclusive({
               try await self.shellChannel.run("pgrep -x Xorg >/dev/null 2>&1 || pgrep -x X >/dev/null 2>&1; echo Z_X=$?", timeout: 15)
           }) {
            value = r.stdout.contains("Z_X=0")
        }
        desktopCache = (value, Date())
        return value
    }

    private func xdotool(_ arguments: String) async throws {
        try await xdotoolScript("xdotool \(arguments)")
    }

    /// Runs an xdotool command line on the serial shell with the desktop's DISPLAY / XAUTHORITY.
    private func xdotoolScript(_ script: String) async throws {
        let env = "export DISPLAY=${DISPLAY:-:0}; if [ -z \"$XAUTHORITY\" ]; then for f in \"$HOME/.Xauthority\" /home/*/.Xauthority; "
            + "do [ -f \"$f\" ] && export XAUTHORITY=\"$f\" && break; done; fi; "
        let r = try await exclusive {
            try await self.ensureShell()
            return try await self.shellChannel.run(env + script, timeout: 60)
        }
        guard r.exitCode == 0 else { throw ZError.vm("xdotool failed (\(r.exitCode)): \(r.stdout.prefix(300))") }
    }

    static func nonce() -> String { String(UInt64.random(in: 0...UInt64.max), radix: 36) }
}
