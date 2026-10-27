import Foundation
import ZCore
import ZAgent

/// The text the team gives its agents: per-member instructions (system prompt) and the task of each run.
public enum TeamPrompts {
    /// Added to a member's system prompt ("## Instructions").
    public static func instructions(for member: TeamMember, duties: TeamDuties, roster: TeamRoster, sharedScreen: Bool,
                                    allowReopen: Bool = true) -> String {
        var s = "You are \(member.name), the \(member.role.rawValue) of a team of AI agents working together on one goal."
        let others = roster.members.filter { $0.id != member.id }
        if !others.isEmpty {
            s += "\nYour teammates: " + others.map { "\($0.name) (\($0.role.rawValue))" }.joined(separator: ", ") + "."
        }
        if duties.contains(.plan) {
            s += "\n- As the lead you plan: you split the goal into concrete tasks on the task board with `board_plan`, "
            s += "and at the end you write the final report for the user. You do not do the tasks yourself."
        }
        if duties.contains(.work) {
            s += "\n- You do tasks from the task board. Each run gives you one task: do it, check it worked, then call "
            s += "`task_complete` with what you did and the result (success true or false). If you cannot go on without "
            s += "something only a teammate can provide, `board_update` the task to blocked with the reason."
        }
        if duties.contains(.review) {
            s += "\n- As the reviewer you check the workers' results against the goal and tell the lead your verdict."
            if allowReopen { s += " Use `board_reopen` for a task that is not acceptable (once per task)." }
        }
        s += "\n- Use `team_send` to message a teammate, `team_broadcast` to tell everyone and `team_inbox` to read "
        s += "messages sent to you. `board_list` shows the task board."
        if sharedScreen {
            s += "\n- The machine is shared: other agents may click and type between your actions. Take a fresh "
            s += "screenshot before acting on the screen, keep screen actions short, and prefer the shell when it can do the job."
        }
        let extra = member.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { s += "\n\n\(extra)" }
        return s
    }

    /// The lead's planning run.
    public static func plan(goal: String, workers: [TeamMember], roster: TeamRoster) -> String {
        var s = "Team goal: \(goal)\n\n"
        s += "Plan the work. Call `board_plan` once with the tasks: each with a short title and a detail that says "
        s += "exactly what to do and what counts as done; use `depends_on` (task numbers) when a task needs the result "
        s += "of another. Tasks without dependencies are done in parallel"
        if workers.count > 1 {
            s += " by \(workers.map(\.name).joined(separator: ", ")); you may name an `assignee`"
        }
        s += ". Prefer a few self-contained tasks over many small ones. Do not do the tasks yourself. "
        s += "When the plan is on the board, call `task_complete` with a one-line summary of the plan."
        return s
    }

    /// A worker's run on one task. `taskText` is `TeamToolbox.describeTaskForWorker`.
    public static func work(goal: String, taskText: String, unreadMessages: Int) -> String {
        var s = "Team goal: \(goal)\n\nYour task — \(taskText)\n\n"
        if unreadMessages > 0 {
            s += "You have \(unreadMessages) unread team message\(unreadMessages == 1 ? "" : "s"); read them with `team_inbox`.\n\n"
        }
        s += "Do this task only. When it is done (or cannot be done), call `task_complete` with a short summary of what "
        s += "you did and the result, and success true or false."
        return s
    }

    /// The reviewer's run.
    public static func review(goal: String, board: String, allowReopen: Bool) -> String {
        var s = "Team goal: \(goal)\n\nThe workers have finished. The task board:\n\(board)\n\n"
        s += "Check that the results really achieve the goal; look at the machine where that helps. "
        if allowReopen {
            s += "For a task that is not acceptable, call `board_reopen` with its number and concrete feedback "
            s += "(each task can be reopened once). "
        }
        s += "Then call `task_complete` with your verdict for the lead (success true when the goal is met)."
        return s
    }

    /// The lead's final run.
    public static func report(goal: String, board: String, review: String?) -> String {
        var s = "Team goal: \(goal)\n\nThe work is over. The final task board:\n\(board)\n\n"
        if let review = review?.trimmingCharacters(in: .whitespacesAndNewlines), !review.isEmpty {
            s += "The reviewer's verdict: \(review)\n\n"
        }
        s += "Write the final report for the user: what was achieved, what was not, and anything they need to do. "
        s += "Call `task_complete` with the report as the summary (success true when the goal was achieved)."
        return s
    }

    /// The report when the lead could not write one.
    public static func fallbackReport(goal: String, tasks: [TeamTask]) -> String {
        guard !tasks.isEmpty else { return "No tasks were done for: \(goal)" }
        let done = tasks.filter { $0.status == .done }.count
        var s = "\(done) of \(tasks.count) task\(tasks.count == 1 ? "" : "s") done for: \(goal)"
        for t in tasks {
            s += "\n- #\(t.id) \(t.title): \(t.status.rawValue)"
            if let r = t.result, !r.isEmpty { s += " — \(TeamReporter.clip(r, 300))" }
        }
        return s
    }
}
