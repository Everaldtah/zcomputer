import Foundation
import ZCore
import ZAgent

// MARK: - Tasks

public enum TaskStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case todo, doing, blocked, done, failed

    /// Lenient parsing of model-written statuses ("in_progress", "completed", "error" ...).
    public init?(lenient text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        switch t {
        case "todo", "to_do", "open", "pending", "queued", "new", "reopen", "reopened": self = .todo
        case "doing", "in_progress", "inprogress", "started", "working", "active", "running": self = .doing
        case "blocked", "stuck", "waiting", "on_hold": self = .blocked
        case "done", "complete", "completed", "finished", "success", "succeeded", "ok", "resolved": self = .done
        case "failed", "fail", "failure", "error", "errored", "cancelled", "canceled", "abandoned": self = .failed
        default: return nil
        }
    }

    /// Done or failed: nobody will work on it again (unless the reviewer reopens it).
    public var isTerminal: Bool { self == .done || self == .failed }
}

/// One task on the board. Ids are short sequential numbers ("1", "2", ...) so models can type them.
public struct TeamTask: Identifiable, Codable, Sendable, Hashable {
    public var id: String
    public var title: String
    public var detail: String
    public var status: TaskStatus
    /// Member id working on it (or the member the lead gave it to while it is still `todo`).
    public var assignee: String?
    /// Ids of tasks that must be done first.
    public var dependsOn: [String]
    public var result: String?
    /// Times the task was claimed.
    public var attempts: Int
    /// Times the reviewer reopened it.
    public var reopenCount: Int
    /// Failed attempts and review feedback, oldest first (shown to the next worker).
    public var history: [String]
    /// True when the board blocked the task because a dependency cannot finish; it goes back to `todo` by itself
    /// when that changes. False for tasks an agent marked blocked.
    public var blockedByDependency: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, title: String, detail: String = "", status: TaskStatus = .todo, assignee: String? = nil,
                dependsOn: [String] = [], result: String? = nil, attempts: Int = 0, reopenCount: Int = 0,
                history: [String] = [], blockedByDependency: Bool = false, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.title = title; self.detail = detail; self.status = status; self.assignee = assignee
        self.dependsOn = dependsOn; self.result = result; self.attempts = attempts; self.reopenCount = reopenCount
        self.history = history; self.blockedByDependency = blockedByDependency
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

/// A task as the lead plans it (before it gets an id).
public struct TaskDraft: Codable, Sendable, Hashable {
    public var title: String
    public var detail: String
    /// Ids of tasks already on the board, or 1-based positions / titles of tasks in the same plan.
    public var dependsOn: [String]
    /// Member id to give the task to (the runner resolves names before planning).
    public var assignee: String?

    public init(title: String, detail: String = "", dependsOn: [String] = [], assignee: String? = nil) {
        self.title = title; self.detail = detail; self.dependsOn = dependsOn; self.assignee = assignee
    }

    /// Drafts from model-written JSON: an array of task objects (or strings), an object with a "tasks" array,
    /// a single task object, or any of those encoded as a JSON string. Lenient about key names.
    public static func parse(_ value: JSONValue) -> [TaskDraft] {
        var v = value
        if case .string(let s) = v {
            if let parsed = try? JSONValue.parse(s), parsed.arrayValue != nil || parsed.objectValue != nil {
                v = parsed
            } else {
                let items = parseList(s)
                if !items.isEmpty { return items }
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? [] : [TaskDraft(title: trimmed)]
            }
        }
        if let inner = v["tasks"] ?? v["plan"] { return parse(inner) }
        if let items = v.arrayValue { return items.compactMap(draft(from:)) }
        return draft(from: v).map { [$0] } ?? []
    }

    static func draft(from item: JSONValue) -> TaskDraft? {
        if let s = item.stringValue {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : TaskDraft(title: t)
        }
        guard item.objectValue != nil else { return nil }
        let args = ToolArguments(item, toolName: "board_plan")
        let detail = (args.string(["detail", "details", "description", "desc", "instructions", "body"]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var title = (args.string(["title", "name", "task", "summary", "goal"]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            let firstLine = detail.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            title = String(firstLine.prefix(100))
        }
        guard !title.isEmpty else { return nil }
        var deps: [String] = []
        for key in ["depends_on", "dependsOn", "dependencies", "deps", "after", "requires"] {
            if let list = args.stringArray(key) { deps = list; break }
            if let one = args.string(key) { deps = [one]; break }
        }
        let assignee = args.string(["assignee", "assign_to", "assignTo", "owner", "worker", "member"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return TaskDraft(title: title, detail: detail, dependsOn: deps,
                         assignee: (assignee?.isEmpty ?? true) ? nil : assignee)
    }

    /// Drafts from a numbered or bulleted list in plain text ("1. Do X", "- Do Y"); other lines are ignored.
    public static func parseList(_ text: String) -> [TaskDraft] {
        var out: [TaskDraft] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            guard var item = listItem(raw.trimmingCharacters(in: .whitespaces)) else { continue }
            item = item.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { continue }
            if item.count > 120 {
                out.append(TaskDraft(title: String(item.prefix(117)) + "…", detail: item))
            } else {
                out.append(TaskDraft(title: item))
            }
        }
        return out
    }

    /// The text of a list item line, or nil when the line is not one.
    static func listItem(_ line: String) -> String? {
        guard let first = line.first else { return nil }
        if first == "-" || first == "*" || first == "•" {
            let rest = line.dropFirst()
            guard rest.first == " " else { return nil }
            let body = rest.trimmingCharacters(in: .whitespaces)
            return body.isEmpty ? nil : body
        }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let sep = rest.first, sep == "." || sep == ")" else { return nil }
        let after = rest.dropFirst()
        guard after.first == " " else { return nil }
        let body = after.trimmingCharacters(in: .whitespaces)
        return body.isEmpty ? nil : body
    }
}

// MARK: - Board

/// The team's shared task list.
///
/// * A task is claimable by a member when it is `todo`, unassigned or assigned to that member, and every task it
///   depends on is `done`. Claiming makes it `doing` and counts an attempt.
/// * `finishAttempt` ends an attempt: success → `done`; failure → back to `todo` for another attempt (anyone may
///   take it) until `maxAttempts`, then `failed`.
/// * Tasks whose dependencies can no longer finish (failed, blocked, or a cycle) are blocked automatically and
///   unblocked when that changes (e.g. the reviewer reopens the dependency).
/// * Every change is reported as a `TeamEvent` (`events()`) and mirrored onto the `EventBus` as a `.note` by the
///   reporter.
public actor TaskBoard {
    public nonisolated let maxAttempts: Int
    public nonisolated let maxReopens: Int
    public nonisolated let reporter: TeamReporter

    private var items: [TeamTask] = []
    private var nextNumber = 1
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// Closed boards hand out no more tasks and wake everyone waiting (the team was stopped).
    public private(set) var isClosed = false

    public init(maxAttempts: Int = 2, maxReopens: Int = 1, reporter: TeamReporter = TeamReporter()) {
        self.maxAttempts = max(1, maxAttempts)
        self.maxReopens = max(0, maxReopens)
        self.reporter = reporter
    }

    /// Task additions and updates as they happen. The stream ends when the consumer is cancelled.
    public nonisolated func events() -> AsyncStream<TeamEvent> {
        let upstream = reporter.hub.subscribe()
        return AsyncStream { continuation in
            let pump = Task {
                for await event in upstream {
                    switch event {
                    case .taskAdded, .taskUpdated: continuation.yield(event)
                    default: break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    // MARK: Reading

    public var tasks: [TeamTask] { items }
    public var isEmpty: Bool { items.isEmpty }
    public func task(_ id: String) -> TeamTask? { items.first { $0.id == Self.normalizeID(id) } }

    public func count(_ status: TaskStatus) -> Int { items.filter { $0.status == status }.count }

    /// True while some task is `todo` or `doing`.
    public var hasOpenWork: Bool { items.contains { $0.status == .todo || $0.status == .doing } }

    /// True when there are tasks and all of them are done.
    public var allDone: Bool { !items.isEmpty && items.allSatisfy { $0.status == .done } }

    /// True when every task `id` depends on is done (false for an unknown id).
    public func dependenciesSatisfied(_ id: String) -> Bool {
        guard let t = task(id) else { return false }
        return depsDone(t)
    }

    /// True when `member` could claim the task now.
    public func isClaimable(_ id: String, by member: String) -> Bool {
        guard let t = task(id) else { return false }
        return claimable(t, by: member)
    }

    // MARK: Planning

    /// Adds the drafts as tasks (ids continue the board's numbering) and returns them. Dependencies may name tasks
    /// already on the board (by id or title) or other drafts of this plan (by 1-based position or title);
    /// unknown references and self-references are dropped.
    @discardableResult
    public func plan(from drafts: [TaskDraft]) -> [TeamTask] {
        guard !drafts.isEmpty else { return [] }
        let first = nextNumber
        nextNumber += drafts.count
        let newIDs = drafts.indices.map { String(first + $0) }
        let now = Date()
        var created: [TeamTask] = []
        for (i, draft) in drafts.enumerated() {
            let id = newIDs[i]
            var deps: [String] = []
            for ref in draft.dependsOn {
                if let dep = resolveDependency(ref, drafts: drafts, newIDs: newIDs), dep != id, !deps.contains(dep) {
                    deps.append(dep)
                }
            }
            let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let assignee = draft.assignee?.trimmingCharacters(in: .whitespacesAndNewlines)
            created.append(TeamTask(id: id, title: title.isEmpty ? "Task \(id)" : title,
                                    detail: draft.detail.trimmingCharacters(in: .whitespacesAndNewlines),
                                    assignee: (assignee?.isEmpty ?? true) ? nil : assignee,
                                    dependsOn: deps, createdAt: now, updatedAt: now))
        }
        items += created
        for t in created { reporter.report(.taskAdded(t)) }
        commit()
        return created.map { t in items.first { $0.id == t.id } ?? t }
    }

    /// Adds one task.
    @discardableResult
    public func add(title: String, detail: String = "", dependsOn: [String] = [], assignee: String? = nil) -> TeamTask {
        let draft = TaskDraft(title: title, detail: detail, dependsOn: dependsOn, assignee: assignee)
        let created = plan(from: [draft])
        // `plan` always creates one task per draft.
        return created.first ?? TeamTask(id: String(nextNumber - 1), title: title)
    }

    /// Gives a task to a member (nil = anyone may claim it).
    @discardableResult
    public func assign(_ id: String, to member: String?) throws -> TeamTask {
        let i = try index(of: id)
        items[i].assignee = member
        items[i].updatedAt = Date()
        reportUpdate(i)
        commit()
        return items[i]
    }

    // MARK: Claiming

    /// Claims the next ready task for `member` (tasks assigned to it first, then unassigned ones in board order),
    /// or nil when none is ready right now.
    public func claimNext(for member: String) -> TeamTask? {
        guard !isClosed else { return nil }
        let ready = items.indices.filter { claimable(items[$0], by: member) }
        guard let i = ready.first(where: { items[$0].assignee == member }) ?? ready.first else { return nil }
        items[i].status = .doing
        items[i].assignee = member
        items[i].attempts += 1
        items[i].updatedAt = Date()
        reportUpdate(i)
        commit()
        return items[i]
    }

    /// Returns true at once when `member` can claim a task; otherwise waits for the next board change while work
    /// may still come its way (another task is in progress) and returns true after it. Returns false when no work
    /// can come for this member any more, the board is closed, or the calling task is cancelled.
    public func waitForWork(for member: String) async -> Bool {
        if isClosed || Task.isCancelled { return false }
        if items.contains(where: { claimable($0, by: member) }) { return true }
        guard mayGetWork(member) else { return false }
        await waitForChange()
        return !isClosed && !Task.isCancelled
    }

    /// Claims the next task for `member`, waiting for dependencies and retries; nil when no work is left for it.
    public func nextClaim(for member: String) async -> TeamTask? {
        while true {
            if let t = claimNext(for: member) { return t }
            guard await waitForWork(for: member) else { return nil }
        }
    }

    // MARK: Updating

    /// Sets the status and/or result (agents' `board_update`, the app). Setting `doing` on an unassigned task
    /// assigns it to `member`.
    @discardableResult
    public func update(_ id: String, status: TaskStatus? = nil, result: String? = nil, by member: String? = nil) throws -> TeamTask {
        let i = try index(of: id)
        if let status {
            items[i].status = status
            items[i].blockedByDependency = false
            if status == .doing, items[i].assignee == nil { items[i].assignee = member }
        }
        if let result {
            let r = result.trimmingCharacters(in: .whitespacesAndNewlines)
            items[i].result = r.isEmpty ? nil : r
        }
        items[i].updatedAt = Date()
        reportUpdate(i)
        commit()
        return items[i]
    }

    /// Ends the current attempt of a task after its worker's run. A task the agent already marked `done` or
    /// `blocked` keeps that status; otherwise success makes it `done` and failure puts it back to `todo` for
    /// another attempt, or marks it `failed` after `maxAttempts`.
    @discardableResult
    public func finishAttempt(_ id: String, success: Bool, result: String) -> TeamTask? {
        guard let i = items.firstIndex(where: { $0.id == Self.normalizeID(id) }) else { return nil }
        let summary = result.trimmingCharacters(in: .whitespacesAndNewlines)
        var t = items[i]
        if t.status == .todo {
            // Reopened or requeued while it ran (those clear the assignee): leave it. A worker that put its own
            // task back to todo ended the attempt without finishing it: count it like any other attempt.
            guard t.assignee != nil else { return t }
            t.status = .doing
        }
        switch t.status {
        case .todo:
            return t
        case .done, .blocked:
            if (t.result ?? "").isEmpty, !summary.isEmpty { t.result = summary }
        case .doing, .failed:
            if t.status == .doing, success {
                t.status = .done
                t.result = summary.isEmpty ? "Done." : summary
            } else {
                var reason = summary
                if t.status == .failed, let r = t.result, !r.isEmpty { reason = r }
                if reason.isEmpty { reason = "No details." }
                t.history.append("Attempt \(t.attempts) failed: \(reason)")
                if t.attempts < maxAttempts {
                    t.status = .todo
                    t.assignee = nil
                    t.result = nil
                } else {
                    t.status = .failed
                    t.result = reason
                }
            }
        }
        t.blockedByDependency = false
        t.updatedAt = Date()
        items[i] = t
        reportUpdate(i)
        commit()
        return items[i]
    }

    /// Puts an interrupted task back to `todo` without counting the attempt (the team was stopped mid-task).
    @discardableResult
    public func requeue(_ id: String, note: String = "Interrupted.") -> TeamTask? {
        guard let i = items.firstIndex(where: { $0.id == Self.normalizeID(id) }), items[i].status == .doing else { return nil }
        items[i].status = .todo
        items[i].assignee = nil
        items[i].attempts = max(0, items[i].attempts - 1)
        items[i].history.append(note)
        items[i].updatedAt = Date()
        reportUpdate(i)
        commit()
        return items[i]
    }

    /// Sends a finished (or blocked / failed) task back for more work with the reviewer's feedback, at most
    /// `maxReopens` times per task. The attempt count starts over.
    @discardableResult
    public func reopen(_ id: String, feedback: String) throws -> TeamTask {
        let i = try index(of: id)
        let t = items[i]
        guard t.status != .todo, t.status != .doing else {
            throw ZError.invalidArgument("Task #\(t.id) is \(t.status.rawValue); only finished, failed or blocked tasks can be reopened.")
        }
        guard t.reopenCount < maxReopens else {
            throw ZError.invalidArgument("Task #\(t.id) was already reopened; it cannot be reopened again.")
        }
        let note = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.result, !r.isEmpty { items[i].history.append("Previous result: \(r)") }
        items[i].history.append("Reopened by the reviewer: \(note.isEmpty ? "needs more work" : note)")
        items[i].reopenCount += 1
        items[i].status = .todo
        items[i].assignee = nil
        items[i].attempts = 0
        items[i].result = nil
        items[i].blockedByDependency = false
        items[i].updatedAt = Date()
        reportUpdate(i)
        commit()
        return items[i]
    }

    /// Stops handing out tasks and wakes everyone waiting (used when the team stops).
    public func close() {
        isClosed = true
        wakeAll()
    }

    // MARK: Text

    /// The board as text for prompts and the `board_list` tool.
    public func summary(includeDetails: Bool = true) -> String {
        guard !items.isEmpty else { return "The task board is empty." }
        return items.map { describe($0, includeDetails: includeDetails) }.joined(separator: "\n")
    }

    func describe(_ t: TeamTask, includeDetails: Bool) -> String {
        var line = "#\(t.id) [\(t.status.rawValue)] \(t.title)"
        if let a = t.assignee { line += " — \(reporter.roster.name(of: a))" }
        if !t.dependsOn.isEmpty { line += " (after #\(t.dependsOn.joined(separator: ", #")))" }
        if includeDetails, !t.detail.isEmpty { line += "\n   Detail: \(TeamReporter.clip(t.detail, 600))" }
        if let r = t.result, !r.isEmpty { line += "\n   Result: \(TeamReporter.clip(r, 800))" }
        if includeDetails, !t.history.isEmpty {
            line += "\n   History: " + t.history.map { TeamReporter.clip($0, 300) }.joined(separator: " | ")
        }
        return line
    }

    // MARK: Internals

    /// "#3", "task 3", " 3 " → "3".
    static func normalizeID(_ id: String) -> String {
        var s = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("task") {
            let rest = s.dropFirst(4).trimmingCharacters(in: .whitespaces)
            let digits = rest.hasPrefix("#") ? String(rest.dropFirst()) : rest
            if Int(digits) != nil { s = digits }
        }
        while s.hasPrefix("#") { s.removeFirst() }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private func index(of id: String) throws -> Int {
        let key = Self.normalizeID(id)
        guard let i = items.firstIndex(where: { $0.id == key }) else {
            let known = items.map { "#\($0.id)" }.joined(separator: ", ")
            throw ZError.notFound("task #\(key) (the board has \(known.isEmpty ? "no tasks" : known))")
        }
        return i
    }

    private func resolveDependency(_ ref: String, drafts: [TaskDraft], newIDs: [String]) -> String? {
        let r = Self.normalizeID(ref)
        guard !r.isEmpty else { return nil }
        if items.contains(where: { $0.id == r }) { return r }
        if let n = Int(r), n >= 1, n <= drafts.count { return newIDs[n - 1] }
        let lower = r.lowercased()
        if let i = drafts.firstIndex(where: { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == lower }) {
            return newIDs[i]
        }
        return items.first { $0.title.lowercased() == lower }?.id
    }

    private func depsDone(_ t: TeamTask) -> Bool {
        t.dependsOn.allSatisfy { dep in items.first { $0.id == dep }.map { $0.status == .done } ?? true }
    }

    private func claimable(_ t: TeamTask, by member: String) -> Bool {
        t.status == .todo && (t.assignee == nil || t.assignee == member) && depsDone(t)
    }

    /// Whether waiting can bring `member` work: something is in progress, and either a task it could take is
    /// still waiting, or a task in progress may come back for another attempt.
    private func mayGetWork(_ member: String) -> Bool {
        let running = items.filter { $0.status == .doing }
        guard !running.isEmpty else { return false }
        let pending = items.contains {
            ($0.status == .todo || ($0.status == .blocked && $0.blockedByDependency))
                && ($0.assignee == nil || $0.assignee == member)
        }
        return pending || running.contains { $0.attempts < maxAttempts }
    }

    private func reportUpdate(_ i: Int) {
        reporter.report(.taskUpdated(items[i]))
    }

    /// After every change: recompute dependency blocks and wake waiters.
    private func commit() {
        refreshDependencyBlocks()
        wakeAll()
    }

    /// Blocks `todo` tasks that can never become ready (a dependency failed, is blocked, or there is a cycle) and
    /// unblocks the ones the board blocked earlier once their dependencies can finish again.
    private func refreshDependencyBlocks() {
        let ids = Set(items.map(\.id))
        var progressable = Set(items.filter { $0.status == .done || $0.status == .doing }.map(\.id))
        let candidates = items.filter { $0.status == .todo || ($0.status == .blocked && $0.blockedByDependency) }
        var grew = true
        while grew {
            grew = false
            for t in candidates where !progressable.contains(t.id) {
                if t.dependsOn.allSatisfy({ progressable.contains($0) || !ids.contains($0) }) {
                    progressable.insert(t.id)
                    grew = true
                }
            }
        }
        for i in items.indices {
            let t = items[i]
            if t.status == .todo, !progressable.contains(t.id) {
                let stuck = t.dependsOn.filter { ids.contains($0) && !progressable.contains($0) }
                let names = stuck.map { dep -> String in
                    let status = items.first { $0.id == dep }?.status.rawValue ?? "unknown"
                    return "#\(dep) (\(status))"
                }
                items[i].status = .blocked
                items[i].blockedByDependency = true
                items[i].result = "Waiting on \(names.joined(separator: ", ")), which cannot finish."
                items[i].updatedAt = Date()
                reportUpdate(i)
            } else if t.status == .blocked, t.blockedByDependency, progressable.contains(t.id) {
                items[i].status = .todo
                items[i].blockedByDependency = false
                items[i].result = nil
                items[i].updatedAt = Date()
                reportUpdate(i)
            }
        }
    }

    private func waitForChange() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                if isClosed || Task.isCancelled {
                    c.resume()
                } else {
                    waiters[id] = c
                }
            }
        } onCancel: {
            Task { await self.wake(id) }
        }
    }

    private func wake(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }

    private func wakeAll() {
        let all = waiters
        waiters.removeAll()
        for c in all.values { c.resume() }
    }
}
