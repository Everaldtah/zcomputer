import Foundation

public struct PixelSize: Hashable, Codable, Sendable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
}

public enum MouseButton: String, Codable, Sendable, Hashable {
    case left, right, middle
}

public struct ShellResult: Hashable, Codable, Sendable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32
    public var truncated: Bool
    public var durationSeconds: Double
    public init(stdout: String, stderr: String = "", exitCode: Int32 = 0, truncated: Bool = false, durationSeconds: Double = 0) {
        self.stdout = stdout; self.stderr = stderr; self.exitCode = exitCode; self.truncated = truncated; self.durationSeconds = durationSeconds
    }
}

/// Information about what is behind a surface (shown in the UI and given to the model in the system prompt).
public struct SurfaceInfo: Hashable, Codable, Sendable {
    public var name: String
    /// "linux" | "macos" | "unknown"
    public var osFamily: String
    public var architecture: String
    /// True when a structured channel (guest agent / serial console) can run shell commands.
    public var shellAvailable: Bool
    /// True when a graphical desktop is believed to be running (affects which tools the agent prefers).
    public var hasDesktop: Bool
    public var notes: String
    public init(name: String, osFamily: String = "unknown", architecture: String = "unknown", shellAvailable: Bool = false,
                hasDesktop: Bool = true, notes: String = "") {
        self.name = name; self.osFamily = osFamily; self.architecture = architecture; self.shellAvailable = shellAvailable
        self.hasDesktop = hasDesktop; self.notes = notes
    }
}

/// Everything an agent can see and do on a machine. ZVM implements this for real VMs; tests use mocks.
/// All coordinates are in the surface's own pixel space (see `displaySize`); callers scale screenshots
/// for the model and scale model coordinates back before calling these methods.
public protocol ComputerSurface: AnyObject, Sendable {
    var info: SurfaceInfo { get async }
    var displaySize: PixelSize { get async }

    /// PNG screenshot of the current display.
    func screenshot() async throws -> ImageData

    func mouseMove(x: Int, y: Int) async throws
    func click(x: Int, y: Int, button: MouseButton, count: Int) async throws
    func mouseDown(x: Int, y: Int, button: MouseButton) async throws
    func mouseUp(x: Int, y: Int, button: MouseButton) async throws
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int) async throws
    /// Scroll by wheel ticks at a position; positive dy scrolls down, positive dx scrolls right.
    func scroll(x: Int, y: Int, dx: Int, dy: Int) async throws
    /// Types literal text (unicode allowed).
    func typeText(_ text: String) async throws
    /// Presses a key combination, xdotool-style: "Return", "ctrl+c", "cmd+space", "alt+F4", "Escape".
    func pressKeys(_ combo: String) async throws
    /// Holds / releases a key (xdotool key name, e.g. "shift", "ctrl", "a") so modifier-held clicks are possible.
    /// Default implementations throw `ZError.unsupported`; surfaces that can do it override both.
    func keyDown(_ key: String) async throws
    func keyUp(_ key: String) async throws

    /// Runs a shell command inside the machine (guest agent or serial console). Throws `ZError.unsupported` when none.
    func shell(_ command: String, timeout: TimeInterval) async throws -> ShellResult
    func readFile(path: String) async throws -> Data
    func writeFile(path: String, data: Data) async throws
}

public extension ComputerSurface {
    func click(x: Int, y: Int) async throws { try await click(x: x, y: y, button: .left, count: 1) }
    func doubleClick(x: Int, y: Int) async throws { try await click(x: x, y: y, button: .left, count: 2) }
    func rightClick(x: Int, y: Int) async throws { try await click(x: x, y: y, button: .right, count: 1) }
    func keyDown(_ key: String) async throws { throw ZError.unsupported("keyDown is not supported by this surface") }
    func keyUp(_ key: String) async throws { throw ZError.unsupported("keyUp is not supported by this surface") }
}
