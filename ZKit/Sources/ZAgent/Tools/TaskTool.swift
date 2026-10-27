import Foundation
import ZCore

/// `task_complete(summary, success)` ends a run explicitly; `ask_user(question)` waits for the human's reply.
public struct TaskTool: Tool {
    public enum Operation: String, Sendable, CaseIterable, Hashable {
        case complete = "task_complete"
        case askUser = "ask_user"
    }

    public let operation: Operation

    public init(_ operation: Operation) { self.operation = operation }

    public static var all: [any Tool] { Operation.allCases.map { TaskTool($0) } }

    public var spec: ToolSpec {
        switch operation {
        case .complete:
            return ToolSpec(name: operation.rawValue,
                            description: "Finish the task. Call this exactly once when the task is done, or when it cannot be done, with a short summary for the user.",
                            parameters: Schema.object([
                                "summary": Schema.string("What was done and the result, for the user."),
                                "success": Schema.boolean("True when the task was accomplished."),
                            ], required: ["summary"]))
        case .askUser:
            return ToolSpec(name: operation.rawValue,
                            description: "Ask the user a question and wait for the answer. Use only when you cannot continue without their input.",
                            parameters: Schema.object([
                                "question": Schema.string("The question, self-contained."),
                            ], required: ["question"]))
        }
    }

    public func risk(of call: ToolCall) -> ToolRisk { .readOnly(operation.rawValue) }

    public func invoke(_ call: ToolCall, ctx: ToolContext) async throws -> ToolResult {
        let args = ToolArguments(call)
        switch operation {
        case .complete:
            let summary = args.string(["summary", "result", "message", "text"]) ?? "Task complete."
            let success = args.bool("success") ?? true
            await ctx.control?.complete(summary: summary, success: success)
            return ToolResult(callID: call.id, text: success ? "Task marked complete." : "Task marked as not accomplished.")

        case .askUser:
            guard let question = args.string(["question", "text", "message"]), !question.isEmpty else {
                throw ZError.invalidArgument("ask_user needs a 'question'.")
            }
            guard let channel = ctx.userInput else {
                return ToolResult(callID: call.id,
                                  text: "No user is available to answer. Make a reasonable assumption, state it, and continue.",
                                  isError: true)
            }
            ctx.emitter.emit(.note("Waiting for the user to answer: \(question)"))
            let answer = try await channel.ask(question)
            return ToolResult(callID: call.id, text: "The user answered: \(answer)")
        }
    }
}
