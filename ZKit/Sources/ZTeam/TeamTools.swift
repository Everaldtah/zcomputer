import Foundation
import ZCore
import ZAgent

/// What a member does in a run of the team: plan (and report), work on tasks, review.
public struct TeamDuties: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let plan = TeamDuties(rawValue: 1 << 0)
    public static let work = TeamDuties(rawValue: 1 << 1)
    public static let review = TeamDuties(rawValue: 1 << 2)
}

public extension TeamSpec {
    /// The duties of a member: the lead plans, workers (or the lead when there are none) work, the reviewer reviews.
    func duties(of memberID: String) -> TeamDuties {
        var d: TeamDuties = []
        if lead?.id == memberID { d.insert(.plan) }
        if workers.contains(where: { $0.id == memberID }) { d.insert(.work) }
        if reviewer?.id == memberID { d.insert(.review) }
        return d
    }
}

/// The shared state the team tools work on. The calling member is `ToolContext.agentID` (= its member id).
public struct TeamToolbox: Sendable {
    public let board: TaskBoard
    public let messages: MessageBus
    public let roster: TeamRoster
    /// Duties per member id (who may plan, who may update any task).
    public let duties: [String: TeamDuties]

    public init(board: TaskBoard, messages: MessageBus, roster: TeamRoster, duties: [String: TeamDuties] = [:]) {
        self.board = board; self.messages = messages; self.roster = roster; self.duties = duties
    }

    /// The tools for a member's duties: messaging and `board_list` for everyone, `board_plan` for the lead,
    /// `board_claim` / `board_update` for workers, `board_reopen` for the reviewer.
    public func tools(for duties: TeamDuties, allowReopen: Bool = true) -> [any Tool] {
        var tools: [any Tool] = [TeamSendTool(toolbox: self), TeamBroadcastTool(toolbox: self), TeamInboxTool(toolbox: self),
                                 BoardListTool(toolbox: self)]
        if duties.contains(.plan) { tools.append(BoardPlanTool(toolbox: self)) }
        if duties.contains(.work) {
            tools.append(BoardClaimTool(toolbox: self))
            tools.append(BoardUpdateTool(toolbox: self))
        }
        if duties.contains(.review), allowReopen { tools.append(BoardReopenTool(toolbox: self)) }
        return tools
    }

    /// Every team tool (for tests and custom setups).
    public var allTools: [any Tool] { tools(for: [.plan, .work, .review]) }

    /// "\n(You have 2 unread team messages: call team_inbox.)" or "".
    func unreadNote(for member: String) async -> String {
        let n = await messages.unreadCount(for: member)
        guard n > 0 else { return "" }
        return "\n(You have \(n) unread team message\(n == 1 ? "" : "s"): call team_inbox to read \(n == 1 ? "it" : "them").)"
    }

    func describeTaskForWorker(_ t: TeamTask) async -> String {
        var s = "Task #\(t.id): \(t.title)"
        if !t.detail.isEmpty { s += "\n\(t.detail)" }
        let tasks = await board.tasks
        let deps = t.dependsOn.compactMap { id in tasks.first { $0.id == id } }
        if !deps.isEmpty {
            s += "\nResults of the tasks it builds on:"
            for d in deps { s += "\n- #\(d.id) \(d.title): \(d.result ?? "(no result)")" }
        }
        if !t.history.isEmpty { s += "\nEarlier: " + t.history.joined(separator: " | ") }
        return s
    }
}

// MARK: - Messaging tools

/// `team_send(to, text)`.
public struct TeamSendTool: Tool {
    public static let toolName = "team_send"
    public let toolbox: TeamToolbox
    public init(toolbox: TeamToolbox) { self.toolbox = toolbox }

    public var spec: ToolSpec {
        ToolSpec(name: Self.toolName,
                 description: "Send a message to one teammate (by name or role). They read it with team_inbox. Team: \(toolbox.roster.summary).",
                 parameters: Schema.object([
                    "to": Schema.string("The teammate's name or role (lead, reviewer)."),
                    "text": Schema.string("The message, self-contained."),
                 ], required: ["to", "text"]))
    }

    public func risk(of call: ToolCall) -> ToolRisk { .readOnly("team") }

    public func invoke(_ call: ToolCall, ctx: ToolContext) async throws -> ToolResult {
        let args = ToolArguments(call)
        guard let to = args.string(["to", "recipient", "member", "name"]) else {
            throw ZError.invalidArgument("team_send needs 'to' (a teammate's name). Team: \(toolbox.roster.summary).")
        }
        let text = try args.requiredString("text")
        let message = try await toolbox.messages.send(from: ctx.agentID, to: to, text: text)
        let who = message.to.map { toolbox.roster.name(of: $0) } ?? "everyone"
        return ToolResult(callID: call.id, text: "Sent to \(who)." + (await toolbox.unreadNote(for: ctx.agentID)))
    }
}

/// `team_broadcast(text)`.
public struct TeamBroadcastTool: Tool {
    public static let toolName = "team_broadcast"
    public let toolbox: TeamToolbox
    public init(toolbox: TeamToolbox) { self.toolbox = toolbox }

    public var spec: ToolSpec {
        ToolSpec(name: Self.toolName, description: "Send a message to every teammate.",
                 parameters: Schema.object(["text": Schema.string("The message, self-contained.")], required: ["text"]))
    }

    public func risk(of call: ToolCall) -> ToolRisk { .readOnly("team") }

    public func invoke(_ call: ToolCall, ctx: ToolContext) async throws -> ToolResult {
        let text = try ToolArguments(call).requiredString("text")
        try await toolbox.messages.broadcast(from: ctx.agentID, text: text)
        let others = toolbox.roster.members.filter { $0.id != ctx.agentID }.count
        return ToolResult(callID: call.id, text: "Sent to everyone (\(others) teammate\(others == 1 ? "" : "s"))."
                          + (await toolbox.unreadNote(for: ctx.agentID)))
    }
}

/// `team_inbox()`: unread messages, marked read.
public struct TeamInboxTool: Tool {
    public static let toolName = "team_inbox"
    public let toolbox: TeamToolbox
    public init(toolbox: TeamToolbox) { self.toolbox = toolbox }

    public var spec: ToolSpec {
        ToolSpec(name: Self.toolName, description: "Read the messages teammates sent you since you last looked.",
                 parameters: Schema.object([:]))
    }

    public func risk(of call: ToolCall) -> ToolRisk { .readOnly("team") }

    public func invoke(_ call: ToolCall, ctx: ToolContext) async throws -> ToolResult {
        let unread = await toolbox.messages.inbox(for: ctx.agentID)
        guard !unread.isEmpty else { return ToolResult(callID: call.id, text: "No new messages.") }
        let lines = unread.map { toolbox.messages.format($0) }
        return ToolResult(callID: call.id, text: lines.joined(separator: "\n"))
    }
}

// MARK: - Board tools

/// `board_list()`: the whole board.
public struct BoardListTool: Tool {
    public static let toolName = "board_list"
    public let toolbox: TeamToolbox
    public init(toolbox: TeamToolbox) { self.toolbox = toolbox }

    public var spec: ToolSpec {
        ToolSpec(name: Self.toolName, description: "Show the team's task board: every task with its status, owner and result.",
                 parameters: Schema.object([:]))
    }

    public func risk(of call: ToolCall) -> ToolRisk { .readOnly("team") }

    public func invoke(_ call: ToolCall, ctx: ToolContext) async throws -> ToolResult {
        let text = await toolbox.board.summary()
        return ToolResult(callID: call.id, text: text + (await toolbox.unreadNote(for: ctx.agentID)))
    }
}

/// `board_plan(tasks[])`: the lead puts the plan on the board.
public struct BoardPlanTool: Tool {
    public static let toolName = "board_plan"
    public let toolbox: TeamToolbox
    public init(toolbox: TeamToolbox) { self.toolbox = toolbox }

    public var spec: ToolSpec {
        let workers = toolbox.roster.members.filter { toolbox.duties[$0.id]?.contains(.work) ?? false }.map(\.name)
        let task = Schema.object([
            "title": Schema.string("Short imperative title."),
            "detail": Schema.string("What exactly to do and what counts as done."),
            "depends_on": Schema.array(of: .object(["type": .string("string")]),
                                       "Numbers of tasks (in this list, 1-based, or already on the board) that must be done first."),
            "assignee": Schema.string("Optional: the worker who should do it\(workers.isEmpty ? "" : " (\(workers.joined(separator: ", ")))")."),
        ], required: ["title"])
        return ToolSpec(name: Self.toolName,
                        description: "Put tasks on the team's board. Tasks without dependencies are worked on in parallel.",
                        parameters: Schema.object(["tasks": Schema.array(of: task, "The tasks, in order.")], required: ["tasks"]))
    }

    public func risk(of call: ToolCall) -> ToolRisk { .readOnly("team") }

    public func invoke(_ call: ToolCall, ctx: ToolContext) async throws -> ToolResult {
        let args = ToolArguments(call)
        var drafts = TaskDraft.parse(args["tasks"] ?? args["plan"] ?? .null)
        if drafts.isEmpty, args.raw.arrayValue != nil { drafts = TaskDraft.parse(args.raw) }
        guard !drafts.isEmpty else {
            throw ZError.invalidArgument("board_plan needs a non-empty 'tasks' array of {title, detail, depends_on, assignee}.")
        }
        var ignored: [String] = []
        for i in drafts.indices {
            guard let name = drafts[i].assignee else { continue }
            if let m = toolbox.roster.resolve(name), toolbox.duties[m.id]?.contains(.work) ?? false {
                drafts[i].assignee = m.id
            } else {
                ignored.append(name)
                drafts[i].assignee = nil
            }
        }
        let created = await toolbox.board.plan(from: drafts)
        var text = "Added \(created.count) task\(created.count == 1 ? "" : "s"):\n"
        text += created.map { t in
            var line = "#\(t.id) \(t.title)"
            if !t.dependsOn.isEmpty { line += " (after #\(t.dependsOn.joined(separator: ", #")))" }
            if let a = t.assignee { line += " → \(toolbox.roster.name(of: a))" }
            return line
        }.joined(separator: "\n")
        if !ignored.isEmpty {
            text += "\nIgnored assignees that are not workers: \(ignored.joined(separator: ", ")) (anyone may take those tasks)."
        }
        return ToolResult(callID: call.id, text: text)
    }
}

/// `board_claim()`: take the next ready task.
public struct BoardClaimTool: Tool {
    public static let toolName = "board_claim"
    public let toolbox: TeamToolbox
    public init(toolbox: TeamToolbox) { self.toolbox = toolbox }

    public var spec: ToolSpec {
        ToolSpec(name: Self.toolName,
                 description: "Claim the next ready task on the board (it is assigned to you). Only when you have no task.",
                 parameters: Schema.object([:]))
    }

    public func risk(of call: ToolCall) -> ToolRisk { .readOnly("team") }

    public func invoke(_ call: ToolCall, ctx: ToolContext) async throws -> ToolResult {
        if let task = await toolbox.board.claimNext(for: ctx.agentID) {
            let text = "You claimed it. " + (await toolbox.describeTaskForWorker(task))
                + "\nWhen it is done, call board_update with status done and the result."
            return ToolResult(callID: call.id, text: text + (await toolbox.unreadNote(for: ctx.agentID)))
        }
        let tasks = await toolbox.board.tasks
        let waiting = tasks.filter { $0.status == .todo }.count
        let running = tasks.filter { $0.status == .doing }.count
        return ToolResult(callID: call.id,
                          text: "No task is ready for you right now (\(waiting) waiting, \(running) in progress)."
                            + (await toolbox.unreadNote(for: ctx.agentID)))
    }
}

/// `board_update(id, status, result)`.
public struct BoardUpdateTool: Tool {
    public static let toolName = "board_update"
    public let toolbox: TeamToolbox
    public init(toolbox: TeamToolbox) { self.toolbox = toolbox }

    public var spec: ToolSpec {
        ToolSpec(name: Self.toolName,
                 description: "Update one of your tasks: its status (doing, blocked, done, failed) and/or its result.",
                 parameters: Schema.object([
                    "id": Schema.string("The task number."),
                    "status": Schema.string("New status.", oneOf: ["doing", "blocked", "done", "failed"]),
                    "result": Schema.string("What was done / found, or why it is blocked or failed."),
                 ], required: ["id"]))
    }

    public func risk(of call: ToolCall) -> ToolRisk { .readOnly("team") }

    public func invoke(_ call: ToolCall, ctx: ToolContext) async throws -> ToolResult {
        let args = ToolArguments(call)
        guard let id = args.string(["id", "task", "task_id", "taskId", "number"]) else {
            throw ZError.invalidArgument("board_update needs the task 'id'.")
        }
        var status: TaskStatus?
        if let raw = args.string(["status", "state"]) {
            guard let s = TaskStatus(lenient: raw) else {
                throw ZError.invalidArgument("Unknown status '\(raw)'. Use doing, blocked, done or failed.")
            }
            status = s
        }
        let result = args.string(["result", "summary", "note", "notes", "text"])
        guard status != nil || result != nil else {
            throw ZError.invalidArgument("board_update needs a 'status' and/or a 'result'.")
        }
        guard let task = await toolbox.board.task(id) else {
            throw ZError.notFound("task #\(TaskBoard.normalizeID(id)). Call board_list to see the board.")
        }
        let mine = task.assignee == nil || task.assignee == ctx.agentID
        let mayUpdateAny = !(toolbox.duties[ctx.agentID] ?? []).isDisjoint(with: [.plan, .review])
        guard mine || mayUpdateAny else {
            let owner = task.assignee.map { toolbox.roster.name(of: $0) } ?? "someone else"
            throw ZError.invalidArgument("Task #\(task.id) belongs to \(owner); update only your own tasks (message them instead).")
        }
        let updated = try await toolbox.board.update(id, status: status, result: result, by: ctx.agentID)
        return ToolResult(callID: call.id, text: "Task #\(updated.id) is \(updated.status.rawValue)."
                          + (await toolbox.unreadNote(for: ctx.agentID)))
    }
}

/// `board_reopen(id, feedback)`: the reviewer sends a task back for more work (once per task).
public struct BoardReopenTool: Tool {
    public static let toolName = "board_reopen"
    public let toolbox: TeamToolbox
    public init(toolbox: TeamToolbox) { self.toolbox = toolbox }

    public var spec: ToolSpec {
        ToolSpec(name: Self.toolName,
                 description: "Send a finished, failed or blocked task back to the workers with feedback (each task can be reopened once).",
                 parameters: Schema.object([
                    "id": Schema.string("The task number."),
                    "feedback": Schema.string("What is wrong or missing, concretely."),
                 ], required: ["id", "feedback"]))
    }

    public func risk(of call: ToolCall) -> ToolRisk { .readOnly("team") }

    public func invoke(_ call: ToolCall, ctx: ToolContext) async throws -> ToolResult {
        let args = ToolArguments(call)
        guard let id = args.string(["id", "task", "task_id", "taskId", "number"]) else {
            throw ZError.invalidArgument("board_reopen needs the task 'id'.")
        }
        let feedback = args.string(["feedback", "reason", "result", "text", "note"]) ?? ""
        let task = try await toolbox.board.reopen(id, feedback: feedback)
        return ToolResult(callID: call.id, text: "Task #\(task.id) is reopened; a worker will do it again with your feedback.")
    }
}
