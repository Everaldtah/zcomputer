import Foundation
import ZCore

/// An ordered set of tools by name, plus the approval-aware executor the runner uses.
public struct ToolRegistry: Sendable {
    private var byName: [String: any Tool] = [:]
    private var order: [String] = []

    public init(_ tools: [any Tool] = []) {
        for t in tools { register(t) }
    }

    /// Adds a tool, replacing any tool with the same name (keeping its position).
    public mutating func register(_ tool: any Tool) {
        let name = tool.spec.name
        if byName[name] == nil { order.append(name) }
        byName[name] = tool
    }

    public mutating func register(_ tools: [any Tool]) {
        for t in tools { register(t) }
    }

    public mutating func remove(named name: String) {
        byName[name] = nil
        order.removeAll { $0 == name }
    }

    public func tool(named name: String) -> (any Tool)? { byName[name] }
    public func contains(_ name: String) -> Bool { byName[name] != nil }
    public var names: [String] { order }
    public var tools: [any Tool] { order.compactMap { byName[$0] } }
    public var specs: [ToolSpec] { tools.map(\.spec) }
    public var isEmpty: Bool { order.isEmpty }

    /// The standard tool set for an agent: computer + shell + files when a machine is attached,
    /// memory tools when a library is attached, and the task tools always.
    public static func standard(computer: ComputerTool?, hasSurface: Bool, hasMemory: Bool,
                                shell: ShellTool = ShellTool()) -> ToolRegistry {
        var r = ToolRegistry()
        if hasSurface {
            if let computer { r.register(computer) }
            r.register(shell)
            r.register(FileTool.all)
        }
        if hasMemory { r.register(MemoryTool.all) }
        r.register(TaskTool.all)
        return r
    }

    /// The tool a call is routed to: the exact name, else the namespace before the first "." — native computer
    /// members arrive as "computer.left_click" (Anthropic toolset) or "computer.click" (Gemini) and go to "computer".
    public func resolve(_ name: String) -> (any Tool)? {
        if let t = byName[name] { return t }
        if let dot = name.firstIndex(of: "."), let t = byName[String(name[..<dot])] { return t }
        return nil
    }

    /// Name of the registered tool a call name routes to.
    public func resolvedName(_ name: String) -> String? { resolve(name)?.spec.name }

    /// Risk of a call (unknown tools are `.normal`).
    public func risk(of call: ToolCall) -> ToolRisk {
        resolve(call.name)?.risk(of: call) ?? .normal(call.name)
    }

    /// Runs one call: routing → batch check → approval (when the gate requires it) → invoke.
    /// Never throws: failures, denials and cancellation come back as error results the model can read.
    /// `onApprovalWait(true)` is called just before waiting for the user, `onApprovalWait(false)` after the decision.
    public func execute(_ call: ToolCall, ctx: ToolContext,
                        onApprovalWait: (@Sendable (Bool) async -> Void)? = nil) async -> ToolResult {
        guard let tool = resolve(call.name) else {
            let available = order.joined(separator: ", ")
            return ToolResult(callID: call.id, text: "Unknown tool '\(call.name)'. Available tools: \(available).", isError: true)
        }
        let stopsBatch = tool.stopsBatchOnFailure
        if stopsBatch, let batch = ctx.batch, await batch.state.failed {
            return ToolResult(callID: call.id, text: ToolBatch.notExecutedMessage, isError: true)
        }
        let risk = tool.risk(of: call)
        if await ctx.approval.needsApproval(risk) {
            let summary = Self.approvalSummary(call: call, risk: risk)
            let request = ApprovalRequest(id: call.id, agentID: ctx.agentID, toolName: call.name, summary: summary,
                                          arguments: call.arguments)
            await onApprovalWait?(true)
            let decision = await ctx.approval.request(request, kind: risk.kind, mandatory: risk.mandatory, emitter: ctx.emitter)
            await onApprovalWait?(false)
            if decision == .deny {
                if stopsBatch { await ctx.batch?.state.markFailed() }
                if risk.mandatory {
                    await ctx.control?.halt(reason: "The user declined a safety confirmation: \(risk.reason ?? call.name).")
                }
                return ToolResult(callID: call.id,
                                  text: "The user denied this \(call.name) call (\(risk.reason ?? risk.kind)). Do not retry it; choose another approach or ask the user.",
                                  isError: true)
            }
        }
        if Task.isCancelled {
            return ToolResult(callID: call.id, text: "Cancelled before \(call.name) ran.", isError: true)
        }
        var result: ToolResult
        do {
            result = try await tool.invoke(call, ctx: ctx)
            result.callID = call.id
        } catch is CancellationError {
            result = ToolResult(callID: call.id, text: "\(call.name) was cancelled.", isError: true)
        } catch let e as ZError {
            result = ToolResult(callID: call.id, text: e.description, isError: true)
        } catch {
            result = ToolResult(callID: call.id, text: "\(call.name) failed: \(error)", isError: true)
        }
        if result.isError, stopsBatch { await ctx.batch?.state.markFailed() }
        return result
    }

    /// One line for the approval card.
    static func approvalSummary(call: ToolCall, risk: ToolRisk) -> String {
        let args = ToolArguments(call)
        var what: String
        switch call.name {
        case ShellTool.toolName:
            what = "Run `\(args.string("command") ?? "?")`"
        case FileTool.Operation.writeFile.rawValue:
            what = "Write \(args.string("path") ?? "?")"
        case ComputerTool.toolName:
            what = "Computer: \(args.string("action") ?? "?")"
        case _ where call.name.hasPrefix(ComputerTool.toolName + "."):
            what = "Computer: \(call.name.dropFirst(ComputerTool.toolName.count + 1))"
        default:
            let json = call.arguments.jsonString()
            what = "\(call.name) \(json.count > 200 ? String(json.prefix(200)) + "…" : json)"
        }
        if let reason = risk.reason { what += " — \(reason)" }
        return what
    }
}
