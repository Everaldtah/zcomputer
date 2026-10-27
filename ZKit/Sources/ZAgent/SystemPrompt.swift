import Foundation
import ZCore

/// Builds the agent's system prompt: who it is, the machine, the memory block, how to use the tools.
public struct SystemPromptBuilder: Sendable {
    public var agentName: String
    /// Extra instructions (team role, user's custom instructions).
    public var instructions: String?
    public var surfaceInfo: SurfaceInfo?
    /// Screenshot size in model coordinates (what the computer tool's x/y refer to).
    public var screenSize: PixelSize?
    public var memoryContext: String?
    public var tools: [ToolSpec]
    /// True when tools are called through fenced JSON blocks instead of native tool calling.
    public var textToolMode: Bool
    public var vision: Bool
    /// True when the provider's native computer tool is declared (it defines its own coordinate space).
    public var nativeComputer: Bool
    public var date: Date

    public init(agentName: String, instructions: String? = nil, surfaceInfo: SurfaceInfo? = nil, screenSize: PixelSize? = nil,
                memoryContext: String? = nil, tools: [ToolSpec] = [], textToolMode: Bool = false, vision: Bool = true,
                nativeComputer: Bool = false, date: Date = Date()) {
        self.agentName = agentName; self.instructions = instructions; self.surfaceInfo = surfaceInfo
        self.screenSize = screenSize; self.memoryContext = memoryContext; self.tools = tools
        self.textToolMode = textToolMode; self.vision = vision; self.nativeComputer = nativeComputer; self.date = date
    }

    public func build() -> String {
        let names = Set(tools.map(\.name))
        var s = "You are \(agentName), an AI agent that operates a computer for the user inside Z Computer. "
        s += "You act by calling tools; you see the machine through tool results. Today is \(Self.dayString(date))."

        if let info = surfaceInfo {
            s += "\n\n## The machine\n"
            s += "- Name: \(info.name)\n"
            s += "- OS: \(info.osFamily) (\(info.architecture))\n"
            s += "- Shell: " + (info.shellAvailable ? "available through the `shell` tool" : "not available (use the screen)") + "\n"
            s += "- Desktop: " + (info.hasDesktop ? "graphical desktop running" : "no graphical desktop detected") + "\n"
            if let size = screenSize, names.contains(ComputerTool.toolName) {
                if nativeComputer {
                    s += "- Screen: screenshots are \(size.width)x\(size.height) pixels.\n"
                } else {
                    s += "- Screen: \(size.width)x\(size.height) pixels in screenshot coordinates (origin top-left). "
                    s += "x/y you pass to `computer` are in this space.\n"
                }
            }
            if !info.notes.isEmpty { s += "- Notes: \(info.notes)\n" }
        }

        s += "\n## How to work\n"
        s += "- Work step by step towards the goal and check the result of each step before the next.\n"
        if names.contains(ShellTool.toolName) {
            s += "- Prefer `shell` for files, installs and anything scriptable; use the screen for graphical apps.\n"
        }
        if names.contains(ComputerTool.toolName) {
            if vision {
                s += "- Take a screenshot before acting on the screen unless you just got one; every `computer` action returns a fresh screenshot.\n"
                s += "- Click the centre of buttons and fields. If something did not react, wait briefly and look again instead of repeating blindly.\n"
            } else {
                s += "- This model cannot see images: screenshots are omitted. Rely on the shell and text output.\n"
            }
        }
        s += "- If an approach fails twice, try a different one. Destructive actions wait for the user's approval; if one is denied, do not retry it.\n"
        if names.contains(TaskTool.Operation.askUser.rawValue) {
            s += "- If you cannot continue without information only the user has, call `ask_user`.\n"
        }
        if names.contains(TaskTool.Operation.complete.rawValue) {
            s += "- When the task is done, or cannot be done, call `task_complete` with a short summary and success true/false.\n"
        }

        if let memory = memoryContext?.trimmingCharacters(in: .whitespacesAndNewlines), !memory.isEmpty {
            s += "\n## What you remember about the user\n\(memory)\n"
            if names.contains(MemoryTool.Operation.search.rawValue) {
                s += "Use `memory_search` for more, and `memory_save` for durable facts the user would want remembered (never secrets).\n"
            }
        } else if names.contains(MemoryTool.Operation.search.rawValue) {
            s += "\n## Memory\nThe user's library is searchable with `memory_search`; save durable facts with `memory_save` (never secrets).\n"
        }

        if let extra = instructions?.trimmingCharacters(in: .whitespacesAndNewlines), !extra.isEmpty {
            s += "\n## Instructions\n\(extra)\n"
        }

        if textToolMode {
            s += "\n" + TextToolCallParser.formatInstructions(tools: tools) + "\n"
        }
        return s
    }

    static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
