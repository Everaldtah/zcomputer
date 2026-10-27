import Foundation
import ZCore

// MARK: - Tool

/// A capability the model can call. Tools are values (structs) and must be `Sendable`;
/// any mutable state lives in an actor the tool holds.
public protocol Tool: Sendable {
    /// What is advertised to the model.
    var spec: ToolSpec { get }

    /// How risky this particular call is. The `ApprovalGate` decides from this whether the user
    /// must approve the call first. Default: `.normal` with the tool name as the approval kind.
    func risk(of call: ToolCall) -> ToolRisk

    /// Runs the call. Throwing is fine: `ToolRegistry.execute` turns errors into error results the model can read.
    func invoke(_ call: ToolCall, ctx: ToolContext) async throws -> ToolResult
}

public extension Tool {
    func risk(of call: ToolCall) -> ToolRisk { .normal(spec.name) }
}

// MARK: - Risk

/// Risk classification of one tool call, used by the approval gate.
public struct ToolRisk: Hashable, Sendable, Codable {
    public enum Level: Int, Hashable, Sendable, Codable, Comparable {
        /// Looks at things only (screenshot, read a file, search memory). Never needs approval.
        case readOnly = 0
        /// Changes something (click, type, run a command, write a file). Needs approval in `.always` mode.
        case normal = 1
        /// Could destroy data or the machine (rm -rf, mkfs, dd, shutdown, curl | sh ...).
        /// Needs approval in `.destructiveOnly` and `.always` modes.
        case destructive = 2

        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    public var level: Level
    /// Grouping key for "always allow this kind" (e.g. "computer", "shell", "shell:rm -r").
    public var kind: String
    /// Human-readable reason shown on the approval card ("recursive delete", "formats a disk").
    public var reason: String?

    public init(level: Level, kind: String, reason: String? = nil) {
        self.level = level; self.kind = kind; self.reason = reason
    }

    public static func readOnly(_ kind: String) -> ToolRisk { .init(level: .readOnly, kind: kind) }
    public static func normal(_ kind: String, reason: String? = nil) -> ToolRisk { .init(level: .normal, kind: kind, reason: reason) }
    public static func destructive(_ kind: String, reason: String) -> ToolRisk { .init(level: .destructive, kind: kind, reason: reason) }
}

// MARK: - Context

/// Everything a tool may use while it runs. Built by the runner for every call.
public struct ToolContext: Sendable {
    public var agentID: String
    public var agentName: String
    public var surface: (any ComputerSurface)?
    public var memory: (any MemoryStore)?
    public var emitter: AgentEmitter
    public var approval: ApprovalGate
    /// A per-agent scratch folder on the host (created lazily by tools that need it).
    public var scratchDirectory: URL
    /// Lets `ask_user` wait for the user's reply. Nil for headless agents (team workers without a human).
    public var userInput: UserInputChannel?
    /// Lets tools end the run (`task_complete`). Nil outside a run.
    public var control: RunControl?

    public init(agentID: String,
                agentName: String? = nil,
                surface: (any ComputerSurface)? = nil,
                memory: (any MemoryStore)? = nil,
                emitter: AgentEmitter,
                approval: ApprovalGate,
                scratchDirectory: URL? = nil,
                userInput: UserInputChannel? = nil,
                control: RunControl? = nil) {
        self.agentID = agentID
        self.agentName = agentName ?? emitter.agentName
        self.surface = surface
        self.memory = memory
        self.emitter = emitter
        self.approval = approval
        self.scratchDirectory = scratchDirectory
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("zagent-\(agentID)", isDirectory: true)
        self.userInput = userInput
        self.control = control
    }

    /// The surface, or a tool error explaining that no machine is attached.
    public func requireSurface(for tool: String) throws -> any ComputerSurface {
        guard let surface else { throw ZError.tool(name: tool, message: "No machine is attached to this agent.") }
        return surface
    }

    public func requireMemory(for tool: String) throws -> any MemoryStore {
        guard let memory else { throw ZError.tool(name: tool, message: "No memory library is available to this agent.") }
        return memory
    }
}

// MARK: - Run control

/// Per-run signals that tools can raise (today: completion via `task_complete`).
public actor RunControl {
    public struct Completion: Hashable, Sendable {
        public var summary: String
        public var success: Bool
        public init(summary: String, success: Bool) { self.summary = summary; self.success = success }
    }

    public private(set) var completion: Completion?

    public init() {}

    /// Marks the run as finished; the runner stops after the current batch of tool calls.
    public func complete(summary: String, success: Bool) {
        completion = Completion(summary: summary, success: success)
    }
}

// MARK: - User input

/// A one-question-at-a-time channel between the agent (`ask_user`) and the human (`AgentRunner.send`).
public actor UserInputChannel {
    private var waiting: (id: UUID, question: String, continuation: CheckedContinuation<String, Error>)?

    public init() {}

    /// The question currently waiting for an answer, if any.
    public var pendingQuestion: String? { waiting?.question }
    public var isWaiting: Bool { waiting != nil }

    /// Suspends until `answer(_:)` is called. Throws `CancellationError` when cancelled or when `cancel()` is called,
    /// and `ZError.invalidArgument` when another question is already waiting.
    public func ask(_ question: String) async throws -> String {
        if Task.isCancelled { throw CancellationError() }
        guard waiting == nil else { throw ZError.invalidArgument("Another question is already waiting for the user.") }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
                waiting = (id, question, c)
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    /// Delivers the user's reply. Returns false when no question was waiting.
    @discardableResult
    public func answer(_ text: String) -> Bool {
        guard let w = waiting else { return false }
        waiting = nil
        w.continuation.resume(returning: text)
        return true
    }

    /// Cancels the waiting question (the run was stopped).
    public func cancel() {
        guard let w = waiting else { return }
        waiting = nil
        w.continuation.resume(throwing: CancellationError())
    }

    private func cancel(id: UUID) {
        guard let w = waiting, w.id == id else { return }
        cancel()
    }
}

// MARK: - Arguments

/// Lenient accessors over a tool call's JSON arguments (numbers given as strings, arguments given as a JSON string...).
public struct ToolArguments: Sendable {
    public let raw: JSONValue
    public let toolName: String

    public init(_ call: ToolCall) { self.init(call.arguments, toolName: call.name) }

    public init(_ value: JSONValue, toolName: String) {
        self.toolName = toolName
        if case .string(let s) = value, let parsed = try? JSONValue.parse(s), parsed.objectValue != nil {
            raw = parsed
        } else {
            raw = value
        }
    }

    public subscript(key: String) -> JSONValue? {
        guard let v = raw[key], !v.isNull else { return nil }
        return v
    }

    public func string(_ key: String) -> String? { self[key]?.lenientString }
    public func int(_ key: String) -> Int? { self[key]?.lenientInt }
    public func double(_ key: String) -> Double? { self[key]?.lenientDouble }
    public func bool(_ key: String) -> Bool? { self[key]?.lenientBool }

    public func stringArray(_ key: String) -> [String]? {
        guard let v = self[key] else { return nil }
        if let a = v.arrayValue { return a.compactMap { $0.lenientString } }
        if let s = v.stringValue {
            return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return nil
    }

    /// First non-nil string among several accepted spellings.
    public func string(_ keys: [String]) -> String? {
        for k in keys { if let s = string(k) { return s } }
        return nil
    }

    public func requiredString(_ key: String) throws -> String {
        guard let s = string(key) else { throw ZError.invalidArgument("\(toolName) needs a '\(key)' string argument.") }
        return s
    }

    public func requiredInt(_ key: String) throws -> Int {
        guard let i = int(key) else { throw ZError.invalidArgument("\(toolName) needs an integer '\(key)' argument.") }
        return i
    }
}

extension JSONValue {
    /// Numbers, or strings that hold numbers.
    var lenientDouble: Double? {
        switch self {
        case .number(let n): return n.isFinite ? n : nil
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    var lenientInt: Int? {
        guard let d = lenientDouble, d.isFinite, abs(d) < 1e15 else { return nil }
        return Int(d.rounded())
    }

    var lenientBool: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s):
            switch s.lowercased().trimmingCharacters(in: .whitespaces) {
            case "true", "yes", "1", "y": return true
            case "false", "no", "0", "n": return false
            default: return nil
            }
        default: return nil
        }
    }

    var lenientString: String? {
        switch self {
        case .string(let s): return s
        case .number(let n):
            if n.rounded() == n, abs(n) < 1e15 { return String(Int(n)) }
            return String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }
}

// MARK: - Text helpers

enum TextLimits {
    /// Keeps the head and tail of a long text, with a marker in the middle.
    static func truncate(_ text: String, max: Int) -> (text: String, truncated: Bool) {
        guard max > 0, text.count > max else { return (text, false) }
        let head = max * 2 / 3
        let tail = max - head
        let start = text.prefix(head)
        let end = text.suffix(tail)
        let omitted = text.count - head - tail
        return ("\(start)\n…[\(omitted) characters omitted]…\n\(end)", true)
    }

    /// Single-quotes a string for a POSIX shell.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
