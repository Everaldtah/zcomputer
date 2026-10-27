import CoreGraphics
import Foundation
import Observation
import ZCore

/// One user input for the machine, in guest pixels.
enum MachineInputAction: Sendable {
    case click(x: Int, y: Int, button: MouseButton)
    case move(x: Int, y: Int)
    case down(x: Int, y: Int)
    case up(x: Int, y: Int)
    case scroll(x: Int, y: Int, dx: Int, dy: Int)
    case text(String)
    case keys(String)
}

/// Turns touches and the on-screen keyboard into `ComputerSurface` calls, in order (a drag's down / moves / up must
/// not overtake each other), with one-shot Ctrl / Alt modifiers from the key row.
@Observable
@MainActor
final class MachineInput {
    /// Sticky modifiers for the next key or character ("ctrl", "alt").
    private(set) var modifiers: Set<String> = []
    private(set) var lastError: String?

    @ObservationIgnored private var continuation: AsyncStream<MachineInputAction>.Continuation?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private(set) var displaySize = PixelSize(width: 1024, height: 768)

    /// Starts sending to `surface` (nil: inputs are dropped, e.g. while the machine is off).
    func attach(_ surface: (any ComputerSurface)?) {
        worker?.cancel()
        continuation?.finish()
        guard let surface else { return }
        let (stream, continuation) = AsyncStream<MachineInputAction>.makeStream(bufferingPolicy: .bufferingNewest(256))
        self.continuation = continuation
        worker = Task { [weak self] in
            let size = await surface.displaySize
            if size.width > 1, size.height > 1 { self?.displaySize = size }
            for await action in stream {
                do {
                    try await Self.perform(action, on: surface)
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

    private static func perform(_ action: MachineInputAction, on surface: any ComputerSurface) async throws {
        switch action {
        case .click(let x, let y, let button): try await surface.click(x: x, y: y, button: button, count: 1)
        case .move(let x, let y): try await surface.mouseMove(x: x, y: y)
        case .down(let x, let y): try await surface.mouseDown(x: x, y: y, button: .left)
        case .up(let x, let y): try await surface.mouseUp(x: x, y: y, button: .left)
        case .scroll(let x, let y, let dx, let dy): try await surface.scroll(x: x, y: y, dx: dx, dy: dy)
        case .text(let text): try await surface.typeText(text)
        case .keys(let combo): try await surface.pressKeys(combo)
        }
    }

    // MARK: Pointer (positions are fractions of the screen, 0...1)

    func tap(at point: CGPoint, button: MouseButton = .left) {
        let (x, y) = pixel(point)
        send(.click(x: x, y: y, button: button))
    }

    func dragBegan(at point: CGPoint) {
        let (x, y) = pixel(point)
        send(.move(x: x, y: y))
        send(.down(x: x, y: y))
    }

    func dragMoved(to point: CGPoint) {
        let (x, y) = pixel(point)
        send(.move(x: x, y: y))
    }

    func dragEnded(at point: CGPoint) {
        let (x, y) = pixel(point)
        send(.up(x: x, y: y))
    }

    /// Wheel ticks at a point; positive `dy` scrolls down.
    func scroll(at point: CGPoint, dx: Int, dy: Int) {
        guard dx != 0 || dy != 0 else { return }
        let (x, y) = pixel(point)
        send(.scroll(x: x, y: y, dx: dx, dy: dy))
    }

    private func pixel(_ point: CGPoint) -> (Int, Int) {
        let x = Int((min(max(point.x, 0), 1) * CGFloat(displaySize.width - 1)).rounded())
        let y = Int((min(max(point.y, 0), 1) * CGFloat(displaySize.height - 1)).rounded())
        return (x, y)
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
