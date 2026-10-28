import CoreGraphics
import Foundation
import Observation
import ZCore

/// A position on the machine's screen as a fraction of its width and height (0...1).
struct ScreenFraction: Sendable, Hashable {
    var x: Double
    var y: Double

    init(_ point: CGPoint) {
        x = Double(point.x)
        y = Double(point.y)
    }

    /// The guest pixel under this position on a display of `size`.
    func pixel(in size: PixelSize) -> (x: Int, y: Int) {
        let px = (min(max(x, 0), 1) * Double(max(size.width - 1, 0))).rounded()
        let py = (min(max(y, 0), 1) * Double(max(size.height - 1, 0))).rounded()
        return (Int(px), Int(py))
    }
}

/// One user input for the machine. Pointer positions are screen fractions, turned into guest pixels with the
/// display size current when the input is sent (the guest may switch video modes, e.g. text console → desktop).
enum MachineInputAction: Sendable {
    case click(ScreenFraction, button: MouseButton)
    case move(ScreenFraction)
    case down(ScreenFraction)
    case up(ScreenFraction)
    case scroll(ScreenFraction, dx: Int, dy: Int)
    case text(String)
    case keys(String)

    var isPointer: Bool {
        switch self {
        case .click, .move, .down, .up, .scroll: return true
        case .text, .keys: return false
        }
    }
}

/// Turns touches and the on-screen keyboard into `ComputerSurface` calls, in order (a drag's down / moves / up must
/// not overtake each other), with one-shot Ctrl / Alt modifiers from the key row. For an emulated machine the
/// surface is ZEmu's `EmuSurface`: pointer positions reach v86 as VMware absolute coordinates when the guest uses
/// that pointer (Z Alpine Desktop does), else as relative PS/2 movements; nothing here talks to the page directly.
@Observable
@MainActor
final class MachineInput {
    /// Sticky modifiers for the next key or character ("ctrl", "alt").
    private(set) var modifiers: Set<String> = []
    private(set) var lastError: String?

    @ObservationIgnored private var continuation: AsyncStream<MachineInputAction>.Continuation?
    @ObservationIgnored private var worker: Task<Void, Never>?

    /// Starts sending to `surface` (nil: inputs are dropped, e.g. while the machine is off).
    func attach(_ surface: (any ComputerSurface)?) {
        worker?.cancel()
        continuation?.finish()
        continuation = nil
        guard let surface else { return }
        let (stream, continuation) = AsyncStream<MachineInputAction>.makeStream(bufferingPolicy: .bufferingNewest(256))
        self.continuation = continuation
        worker = Task { [weak self] in
            var size = PixelSize(width: 1024, height: 768)
            for await action in stream {
                if action.isPointer {
                    let current = await surface.displaySize
                    if current.width > 1, current.height > 1 { size = current }
                }
                do {
                    try await Self.perform(action, size: size, on: surface)
                } catch {
                    self?.lastError = Format.describe(error)
                }
            }
        }
    }

    func detach() {
        worker?.cancel()
        worker = nil
        continuation?.finish()
        continuation = nil
    }

    private static func perform(_ action: MachineInputAction, size: PixelSize, on surface: any ComputerSurface) async throws {
        switch action {
        case .click(let at, let button):
            let p = at.pixel(in: size)
            try await surface.click(x: p.x, y: p.y, button: button, count: 1)
        case .move(let at):
            let p = at.pixel(in: size)
            try await surface.mouseMove(x: p.x, y: p.y)
        case .down(let at):
            let p = at.pixel(in: size)
            try await surface.mouseDown(x: p.x, y: p.y, button: .left)
        case .up(let at):
            let p = at.pixel(in: size)
            try await surface.mouseUp(x: p.x, y: p.y, button: .left)
        case .scroll(let at, let dx, let dy):
            let p = at.pixel(in: size)
            try await surface.scroll(x: p.x, y: p.y, dx: dx, dy: dy)
        case .text(let text): try await surface.typeText(text)
        case .keys(let combo): try await surface.pressKeys(combo)
        }
    }

    // MARK: Pointer (positions are fractions of the screen, 0...1)

    func tap(at point: CGPoint, button: MouseButton = .left) {
        send(.click(ScreenFraction(point), button: button))
    }

    func dragBegan(at point: CGPoint) {
        send(.move(ScreenFraction(point)))
        send(.down(ScreenFraction(point)))
    }

    func dragMoved(to point: CGPoint) {
        send(.move(ScreenFraction(point)))
    }

    func dragEnded(at point: CGPoint) {
        send(.up(ScreenFraction(point)))
    }

    /// Wheel ticks at a point; positive `dy` scrolls down.
    func scroll(at point: CGPoint, dx: Int, dy: Int) {
        guard dx != 0 || dy != 0 else { return }
        send(.scroll(ScreenFraction(point), dx: dx, dy: dy))
    }

    // MARK: Keyboard

    func toggleModifier(_ name: String) {
        if modifiers.contains(name) { modifiers.remove(name) } else { modifiers.insert(name) }
    }

    /// A key from the key row or a hardware key, xdotool name ("Escape", "Tab", "Up", "Return", "BackSpace").
    func key(_ name: String) {
        send(.keys(combo(name)))
    }

    /// Characters from the software keyboard. With Ctrl / Alt armed, the first character becomes a combo.
    func type(_ text: String) {
        guard !text.isEmpty else { return }
        if text == "\n" {
            key("Return")
            return
        }
        if !modifiers.isEmpty, let first = text.first {
            send(.keys(combo(String(first).lowercased())))
            let rest = String(text.dropFirst())
            if !rest.isEmpty { send(.text(rest)) }
            return
        }
        send(.text(text))
    }

    func deleteBackward() {
        key("BackSpace")
    }

    private func combo(_ key: String) -> String {
        let parts = ["ctrl", "alt"].filter { modifiers.contains($0) } + [key]
        modifiers.removeAll()
        return parts.joined(separator: "+")
    }

    private func send(_ action: MachineInputAction) {
        continuation?.yield(action)
    }
}
