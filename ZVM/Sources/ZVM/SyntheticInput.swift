import AppKit
@preconcurrency import Virtualization
import ZCore

/// Serialises async work on the main actor (one input sequence at a time, so key/mouse events never interleave).
@MainActor
final class MainActorGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Synthetic keyboard and mouse input into a `VZVirtualMachineView` (the hidden agent view of `VMDisplayHost`).
///
/// Events are built in-process and handed to the view or its window, so no Accessibility permission is needed
/// and the user's real cursor never moves (approach verified by zyvor-fluxvm on Debian; see
/// docs/research/virtualization.md (e)):
/// * keys: `view.keyDown/keyUp`; modifiers as `flagsChanged` carrying the device-dependent left-hand bit;
/// * left button, moves, drags: `window.sendEvent`;
/// * right/middle button: `CGEvent(.otherMouseDown, button)` → `NSEvent(cgEvent:)` → `view.otherMouseDown`;
/// * scroll: `CGEvent(scrollWheelEvent2Source:)` → `window.sendEvent`.
/// Coordinates are guest display pixels with a top-left origin. Typing assumes a US guest keyboard layout.
/// Synthetic input into **macOS** guests (trackpad device) is UNVERIFIED.
@MainActor
public final class SyntheticInput {
    public let view: VZVirtualMachineView
    private let fallbackSize: PixelSize
    private let gate = MainActorGate()
    private var heldModifiers: [KeyCodes.Modifier] = []
    private var heldButtons: Set<MouseButton> = []
    /// Pause between events (zyvor uses 4 ms).
    public var eventInterval: TimeInterval = 0.004

    public init(view: VZVirtualMachineView, fallbackSize: PixelSize) {
        self.view = view
        self.fallbackSize = fallbackSize
    }

    /// The guest display size in pixels (runtime size when the framework reports one).
    public var displayPixels: PixelSize {
        if let size = view.virtualMachine?.graphicsDevices.first?.displays.first?.sizeInPixels,
           size.width >= 1, size.height >= 1 {
            return PixelSize(width: Int(size.width), height: Int(size.height))
        }
        return fallbackSize
    }

    // MARK: Mouse

    public func mouseMove(x: Int, y: Int) async throws {
        await gate.acquire(); defer { gate.release() }
        try ensureWindow()
        let p = windowPoint(x: x, y: y)
        if heldButtons.contains(.left) {
            sendMouse(.leftMouseDragged, at: p)
        } else if heldButtons.contains(.right) {
            sendMouse(.rightMouseDragged, at: p)
        } else if heldButtons.contains(.middle) {
            sendMouse(.otherMouseDragged, at: p)
        } else {
            sendMouse(.mouseMoved, at: p)
        }
        await pause()
    }

    public func click(x: Int, y: Int, button: MouseButton = .left, count: Int = 1) async throws {
        await gate.acquire(); defer { gate.release() }
        try ensureWindow()
        let p = windowPoint(x: x, y: y)
        sendMouse(.mouseMoved, at: p)
        await pause()
        for n in 1...max(1, min(count, 10)) {
            switch button {
            case .left:
                sendMouse(.leftMouseDown, at: p, clickCount: n, pressure: 1)
                await pause()
                sendMouse(.leftMouseUp, at: p, clickCount: n)
            case .right, .middle:
                sendOtherButton(button, down: true, clickCount: n)
                await pause()
                sendOtherButton(button, down: false, clickCount: n)
            }
            await pause()
        }
    }

    public func mouseDown(x: Int, y: Int, button: MouseButton = .left) async throws {
        await gate.acquire(); defer { gate.release() }
        try ensureWindow()
        let p = windowPoint(x: x, y: y)
        sendMouse(.mouseMoved, at: p)
        await pause()
        if button == .left {
            sendMouse(.leftMouseDown, at: p, pressure: 1)
        } else {
            sendOtherButton(button, down: true)
        }
        heldButtons.insert(button)
        await pause()
    }

    public func mouseUp(x: Int, y: Int, button: MouseButton = .left) async throws {
        await gate.acquire(); defer { gate.release() }
        try ensureWindow()
        let p = windowPoint(x: x, y: y)
        if button == .left {
            sendMouse(.leftMouseDragged, at: p)
            await pause()
            sendMouse(.leftMouseUp, at: p)
        } else {
            sendOtherButton(button, down: false)
        }
        heldButtons.remove(button)
        await pause()
    }

    /// Left-button drag in `steps` intermediate moves.
    public func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, steps: Int = 12) async throws {
        await gate.acquire(); defer { gate.release() }
        try ensureWindow()
        let a = windowPoint(x: fromX, y: fromY)
        let b = windowPoint(x: toX, y: toY)
        sendMouse(.mouseMoved, at: a)
        await pause()
        sendMouse(.leftMouseDown, at: a, pressure: 1)
        await pause()
        let n = max(1, steps)
        for i in 1...n {
            let t = CGFloat(i) / CGFloat(n)
            sendMouse(.leftMouseDragged, at: NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            await pause()
        }
        sendMouse(.leftMouseUp, at: b)
        await pause()
    }

    /// Scrolls by wheel notches at a position: `dy > 0` down, `dx > 0` right.
    public func scroll(x: Int, y: Int, dx: Int, dy: Int) async throws {
        await gate.acquire(); defer { gate.release() }
        let window = try ensureWindow()
        sendMouse(.mouseMoved, at: windowPoint(x: x, y: y))
        await pause()
        // zyvor's verified scaling: 12 line units per notch, negative = down/right in AppKit's convention.
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                               wheel1: Int32(clamping: -dy * 12), wheel2: Int32(clamping: -dx * 12), wheel3: 0),
              let event = NSEvent(cgEvent: cg) else {
            throw ZError.vm("cannot create a scroll event")
        }
        window.sendEvent(event)
        await pause()
    }

    // MARK: Keyboard

    /// Types ASCII text with the US keymap. Throws (before sending anything) for characters outside the map.
    public func typeText(_ text: String) async throws {
        let missing = KeyCodes.untypableCharacters(in: text)
        guard missing.isEmpty else {
            throw ZError.unsupported("cannot type \(missing.map { String($0) }.joined()) with synthetic US-keyboard input; use the guest agent")
        }
        await gate.acquire(); defer { gate.release() }
        try ensureWindow()
        for ch in text {
            guard let key = KeyCodes.characters[ch] else { continue }
            await tap(key, extraModifiers: [])
        }
    }

    /// Presses xdotool-style combos, several separated by spaces ("ctrl+a Delete", "super", "alt+F4").
    public func pressKeys(_ sequence: String) async throws {
        let combos = try KeyCodes.parseSequence(sequence)
        await gate.acquire(); defer { gate.release() }
        try ensureWindow()
        for combo in combos {
            if let key = combo.key {
                await tap(key, extraModifiers: combo.modifiers)
            } else {
                // Modifier-only combo ("super"): press and release them.
                for m in combo.modifiers { await pressModifier(m) }
                for m in combo.modifiers.reversed() { await releaseModifier(m) }
            }
        }
    }

    /// Holds a key (modifier or ordinary key) until `keyUp`.
    public func keyDown(_ name: String) async throws {
        await gate.acquire(); defer { gate.release() }
        try ensureWindow()
        if let m = KeyCodes.modifier(named: name) {
            await pressModifier(m)
        } else if let key = KeyCodes.key(named: name) {
            sendKey(.keyDown, key: key)
            await pause()
        } else {
            throw ZError.invalidArgument("unknown key \"\(name)\"")
        }
    }

    public func keyUp(_ name: String) async throws {
        await gate.acquire(); defer { gate.release() }
        try ensureWindow()
        if let m = KeyCodes.modifier(named: name) {
            await releaseModifier(m)
        } else if let key = KeyCodes.key(named: name) {
            sendKey(.keyUp, key: key)
            await pause()
        } else {
            throw ZError.invalidArgument("unknown key \"\(name)\"")
        }
    }

    /// Releases every held modifier and mouse button.
    public func releaseAll() async {
        await gate.acquire(); defer { gate.release() }
        guard view.window != nil else { heldModifiers.removeAll(); heldButtons.removeAll(); return }
        for m in heldModifiers.reversed() { await releaseModifier(m) }
        for b in heldButtons {
            if b == .left { sendMouse(.leftMouseUp, at: lastPointOrCenter()) } else { sendOtherButton(b, down: false) }
        }
        heldButtons.removeAll()
    }

    /// A harmless Shift tap to wake a guest that blanked its screen (DPMS / screensaver).
    public func wake() async {
        await gate.acquire(); defer { gate.release() }
        guard view.window != nil, let shift = KeyCodes.modifier(named: "shift") else { return }
        await pressModifier(shift)
        await releaseModifier(shift)
    }

    // MARK: Event plumbing

    private var currentFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: heldModifiers.reduce(UInt(0)) { $0 | $1.flags })
    }

    private var timestamp: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func pause() async {
        let nanos = UInt64(max(0, eventInterval) * 1_000_000_000)
        if nanos > 0 { try? await Task.sleep(nanoseconds: nanos) }
    }

    @discardableResult
    private func ensureWindow() throws -> NSWindow {
        guard let window = view.window else {
            throw ZError.vm("the agent display view is not in a window (no VM attached to the display host?)")
        }
        return window
    }

    private var lastPoint: NSPoint?

    private func lastPointOrCenter() -> NSPoint {
        lastPoint ?? NSPoint(x: view.bounds.midX, y: view.bounds.midY)
    }

    /// Guest pixel (top-left origin) → window coordinates of the view.
    func windowPoint(x: Int, y: Int) -> NSPoint {
        let px = displayPixels
        let bounds = view.bounds
        let w = CGFloat(max(px.width, 1))
        let h = CGFloat(max(px.height, 1))
        let cx = (CGFloat(min(max(x, 0), max(px.width - 1, 0))) + 0.5) * bounds.width / w
        let cy = (CGFloat(min(max(y, 0), max(px.height - 1, 0))) + 0.5) * bounds.height / h
        let local = NSPoint(x: bounds.minX + cx, y: view.isFlipped ? bounds.minY + cy : bounds.maxY - cy)
        let p = view.convert(local, to: nil)
        lastPoint = p
        return p
    }

    private func sendMouse(_ type: NSEvent.EventType, at point: NSPoint, clickCount: Int = 1, pressure: Float = 0) {
        guard let window = view.window,
              let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: currentFlags, timestamp: timestamp,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: clickCount, pressure: pressure) else { return }
        window.sendEvent(event)
    }

    /// AppKit's synthesized mouse events always carry button 0, so right/middle go through CGEvent.
    private func sendOtherButton(_ button: MouseButton, down: Bool, clickCount: Int = 1) {
        let cgButton: CGMouseButton = button == .right ? .right : .center
        let type: CGEventType = down ? .otherMouseDown : .otherMouseUp
        guard let cg = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: cgButton) else { return }
        cg.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        guard let event = NSEvent(cgEvent: cg) else { return }
        if down { view.otherMouseDown(with: event) } else { view.otherMouseUp(with: event) }
    }

    private func sendKey(_ type: NSEvent.EventType, key: KeyCodes.Key) {
        let windowNumber = view.window?.windowNumber ?? 0
        guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: currentFlags, timestamp: timestamp,
                                           windowNumber: windowNumber, context: nil, characters: key.characters,
                                           charactersIgnoringModifiers: key.characters, isARepeat: false,
                                           keyCode: key.keyCode) else { return }
        if type == .keyDown { view.keyDown(with: event) } else { view.keyUp(with: event) }
    }

    private func sendFlagsChanged(keyCode: UInt16) {
        let windowNumber = view.window?.windowNumber ?? 0
        guard let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: currentFlags,
                                           timestamp: timestamp, windowNumber: windowNumber, context: nil,
                                           characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                                           keyCode: keyCode) else { return }
        view.flagsChanged(with: event)
    }

    private func pressModifier(_ m: KeyCodes.Modifier) async {
        guard !heldModifiers.contains(m) else { return }
        heldModifiers.append(m)
        sendFlagsChanged(keyCode: m.keyCode)
        await pause()
    }

    private func releaseModifier(_ m: KeyCodes.Modifier) async {
        guard let index = heldModifiers.firstIndex(of: m) else { return }
        heldModifiers.remove(at: index)
        sendFlagsChanged(keyCode: m.keyCode)
        await pause()
    }

    /// Presses and releases one key with modifiers (adds Shift when the character needs it).
    private func tap(_ key: KeyCodes.Key, extraModifiers: [KeyCodes.Modifier]) async {
        var mods = extraModifiers
        if key.shift, let shift = KeyCodes.modifier(named: "shift"), !mods.contains(where: { $0.flags & KeyCodes.shiftFlag != 0 }) {
            mods.append(shift)
        }
        var pressed: [KeyCodes.Modifier] = []
        for m in mods where !heldModifiers.contains(m) {
            await pressModifier(m)
            pressed.append(m)
        }
        sendKey(.keyDown, key: key)
        await pause()
        sendKey(.keyUp, key: key)
        await pause()
        for m in pressed.reversed() { await releaseModifier(m) }
    }
}
