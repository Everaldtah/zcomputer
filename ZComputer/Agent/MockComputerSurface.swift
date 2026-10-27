import Foundation
import ZCore

/// "Demo machine": a simulated Linux desktop for trying the agent without a VM (and the fallback on Macs where
/// `VMController.isSupported` is false). It renders a real PNG desktop (terminal + notes windows + dock) that reacts to
/// clicks, typing and keys, and runs a handful of simulated shell commands over an in-memory file system.
actor MockComputerSurface: ComputerSurface {
    static let screenSize = PixelSize(width: 1280, height: 800)
    static let home = "/home/demo"

    nonisolated let name = "Demo machine"

    private var state = DemoScreenState()
    private var files: [String: Data] = [
        "/home/demo/README.txt": Data("""
        This is Z Computer's demo machine. Nothing here is real: the desktop is drawn by the app and the shell \
        understands a few commands (help, ls, cat, echo, pwd, whoami, uname, date, hostname, touch, rm, clear).
        """.utf8),
        "/home/demo/todo.md": Data("- try the agent\n- create a real VM in Machines\n".utf8),
    ]
    private var heldKeys: Set<String> = []

    init() {
        state.terminalLines = [
            "Z Computer demo machine (simulated). Type `help` for the commands it knows.",
        ]
    }

    // MARK: ComputerSurface

    var info: SurfaceInfo {
        SurfaceInfo(name: name, osFamily: "linux", architecture: "arm64 (simulated)", shellAvailable: true,
                    hasDesktop: true,
                    notes: "A simulated machine for trying the agent before a VM is set up. The desktop has a Terminal "
                        + "window (left), a Notes window (right) and a dock. Shell commands are simulated.")
    }

    var displaySize: PixelSize { Self.screenSize }

    func screenshot() async throws -> ImageData {
        state.clock = Date()
        guard let png = DemoScreenRenderer.render(state, size: Self.screenSize) else {
            throw ZError.unsupported("the demo machine could not draw its screen")
        }
        return ImageData(mime: "image/png", data: png, width: Self.screenSize.width, height: Self.screenSize.height)
    }

    func mouseMove(x: Int, y: Int) async throws {
        state.cursor = clamp(x, y)
    }

    func click(x: Int, y: Int, button: MouseButton, count: Int) async throws {
        let point = clamp(x, y)
        state.cursor = point
        state.lastClick = point
        if let window = DemoScreenRenderer.window(at: point) { state.focus = window }
    }

    func mouseDown(x: Int, y: Int, button: MouseButton) async throws {
        state.cursor = clamp(x, y)
    }

    func mouseUp(x: Int, y: Int, button: MouseButton) async throws {
        try await click(x: x, y: y, button: button, count: 1)
    }

    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int) async throws {
        state.cursor = clamp(toX, toY)
    }

    func scroll(x: Int, y: Int, dx: Int, dy: Int) async throws {
        state.cursor = clamp(x, y)
    }

    func typeText(_ text: String) async throws {
        switch state.focus {
        case .terminal:
            for ch in text {
                if ch == "\n" { runTypedCommand() } else { state.typed.append(ch) }
            }
        case .notes:
            state.notes += text
        case .desktop:
            break
        }
    }

    func pressKeys(_ combo: String) async throws {
        let parts = combo.lowercased().split(separator: "+").map(String.init)
        let key = parts.last ?? ""
        let modifiers = Set(parts.dropLast()).union(heldKeys)
        if modifiers.contains("ctrl") && key == "c", state.focus == .terminal {
            state.terminalLines.append(DemoScreenState.prompt + state.typed + "^C")
            state.typed = ""
            return
        }
        if modifiers.contains("ctrl") && key == "l", state.focus == .terminal {
            state.terminalLines.removeAll()
            return
        }
        switch key {
        case "return", "enter", "kp_enter":
            if state.focus == .terminal { runTypedCommand() } else if state.focus == .notes { state.notes += "\n" }
        case "backspace":
            if state.focus == .terminal, !state.typed.isEmpty { state.typed.removeLast() }
            if state.focus == .notes, !state.notes.isEmpty { state.notes.removeLast() }
        case "tab":
            state.focus = state.focus == .terminal ? .notes : .terminal
        case "space":
            try await typeText(" ")
        default:
            break
        }
    }

    func keyDown(_ key: String) async throws { heldKeys.insert(key.lowercased()) }
    func keyUp(_ key: String) async throws { heldKeys.remove(key.lowercased()) }

    func shell(_ command: String, timeout: TimeInterval) async throws -> ShellResult {
        let started = Date()
        let (out, code) = execute(command)
        state.terminalLines.append(DemoScreenState.prompt + command)
        if !out.isEmpty { state.terminalLines.append(contentsOf: out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)) }
        trimTerminal()
        return ShellResult(stdout: code == 0 ? out : "", stderr: code == 0 ? "" : out, exitCode: code,
                           durationSeconds: Date().timeIntervalSince(started))
    }

    func readFile(path: String) async throws -> Data {
        let full = normalize(path)
        guard let data = files[full] else { throw ZError.notFound(full) }
        return data
    }

    func writeFile(path: String, data: Data) async throws {
        files[normalize(path)] = data
    }

    // MARK: Simulation

    private func runTypedCommand() {
        let command = state.typed
        state.typed = ""
        let (out, _) = execute(command)
        state.terminalLines.append(DemoScreenState.prompt + command)
        if !out.isEmpty { state.terminalLines.append(contentsOf: out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)) }
        trimTerminal()
    }

    private func trimTerminal() {
        if state.terminalLines.count > 400 { state.terminalLines.removeFirst(state.terminalLines.count - 400) }
    }

    /// Runs one simulated command; returns (output, exit code).
    private func execute(_ raw: String) -> (String, Int32) {
        var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return ("", 0) }
        var redirect: String?
        if let range = line.range(of: " > ") {
            redirect = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            line = String(line[..<range.lowerBound])
        }
        let words = line.split(separator: " ").map(String.init)
        let command = words.first ?? ""
        let args = Array(words.dropFirst())
        var output = ""
        var code: Int32 = 0
        switch command {
        case "help":
            output = "Commands: help ls cat echo pwd whoami hostname uname date touch rm clear notes (simulated)"
        case "echo":
            output = args.joined(separator: " ").replacingOccurrences(of: "\"", with: "")
        case "pwd":
            output = Self.home
        case "whoami":
            output = "demo"
        case "hostname":
            output = "zcomputer-demo"
        case "uname":
            output = args.contains("-a") ? "Linux zcomputer-demo 6.12.0-demo #1 SMP aarch64 GNU/Linux (simulated)" : "Linux"
        case "date":
            output = Date().formatted(date: .complete, time: .standard)
        case "ls":
            let dir = normalize(args.first(where: { !$0.hasPrefix("-") }) ?? Self.home)
            let prefix = dir.hasSuffix("/") ? dir : dir + "/"
            let names = Set(files.keys.filter { $0.hasPrefix(prefix) }.compactMap {
                $0.dropFirst(prefix.count).split(separator: "/").first.map(String.init)
            })
            output = names.sorted().joined(separator: "  ")
        case "cat":
            var parts: [String] = []
            for arg in args {
                let path = normalize(arg)
                if let data = files[path] {
                    parts.append(String(decoding: data, as: UTF8.self))
                } else {
                    parts.append("cat: \(arg): No such file or directory")
                    code = 1
                }
            }
            output = parts.joined(separator: "\n")
        case "touch":
            for arg in args where files[normalize(arg)] == nil { files[normalize(arg)] = Data() }
        case "rm":
            for arg in args where !arg.hasPrefix("-") { files[normalize(arg)] = nil }
        case "clear":
            state.terminalLines.removeAll()
        case "notes":
            output = state.notes
        default:
            output = "\(command): command not found (the demo machine simulates only a few commands; try `help`)"
            code = 127
        }
        if let redirect, code == 0 {
            files[normalize(redirect)] = Data((output + "\n").utf8)
            output = ""
        }
        return (output, code)
    }

    private func normalize(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespaces)
        if p == "~" { p = Self.home } else if p.hasPrefix("~/") { p = Self.home + String(p.dropFirst(1)) }
        if !p.hasPrefix("/") { p = Self.home + "/" + p }
        var parts: [String] = []
        for part in p.split(separator: "/") {
            if part == "." || part.isEmpty { continue }
            if part == ".." { _ = parts.popLast(); continue }
            parts.append(String(part))
        }
        return "/" + parts.joined(separator: "/")
    }

    private func clamp(_ x: Int, _ y: Int) -> DemoPoint {
        DemoPoint(x: min(max(0, x), Self.screenSize.width - 1), y: min(max(0, y), Self.screenSize.height - 1))
    }
}

struct DemoPoint: Hashable, Sendable {
    var x: Int
    var y: Int
}

enum DemoWindow: Hashable, Sendable {
    case terminal, notes, desktop
}

/// Everything the renderer draws.
struct DemoScreenState: Sendable {
    static let prompt = "demo@zcomputer:~$ "

    var cursor = DemoPoint(x: 640, y: 400)
    var lastClick: DemoPoint?
    var focus: DemoWindow = .terminal
    var terminalLines: [String] = []
    var typed = ""
    var notes = ""
    var clock = Date()
}
