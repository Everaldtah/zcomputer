import Foundation
import XCTest
import ZCore
import ZAgent
@testable import ZTeam

final class TeamRunnerTests: XCTestCase {
    /// A worker that runs `echo <task>` in the shell, then completes with "Did #<task>".
    private func shellWorker(_ name: String) -> ScriptedClient {
        ScriptedClient(name: name) { req in
            let n = taskNumber(in: req.lastUserText)
            if req.isNewRun { return toolTurn("s\(req.index)", "shell", ["command": .string("echo \(n)")]) }
            return completeTurn("c\(req.index)", "Did #\(n)")
        }
    }

    private func phases(_ team: TeamRunner) -> [TeamPhase] {
        team.hub.history.compactMap { if case .phase(let p) = $0 { return p } else { return nil } }
    }

    func testLeadWorkerAndReviewerFinishATwoTaskGoal() async throws {
        let surface = MockSurface()
        let lead = ScriptedClient.script([
            toolTurn("p1", "board_plan", ["tasks": .array([
                ["title": "Write file A", "detail": "Create /tmp/a"],
                ["title": "Write file B", "detail": "Create /tmp/b"],
            ])]),
            completeTurn("p2", "Planned two tasks"),
            completeTurn("r1", "Report: both files written"),
        ], name: "lead")
        let worker = shellWorker("worker")
        let reviewer = ScriptedClient.script([toolTurn("v1", "board_list"), completeTurn("v2", "Looks good")], name: "reviewer")
        let spec = TeamSpec(members: [teamMember("lead", .lead), teamMember("worker", .worker), teamMember("reviewer", .reviewer)],
                            goal: "Write two files", defaultPolicy: quietPolicy())
        let bus = EventBus()
        let team = TeamRunner(id: "t1", spec: spec, surface: surface, bus: bus,
                              clientFactory: factory(["lead": lead, "worker": worker, "reviewer": reviewer]))

        let outcome = await runTeam(team)

        XCTAssertTrue(outcome.success, outcome.report)
        XCTAssertFalse(outcome.stopped)
        XCTAssertEqual(outcome.report, "Report: both files written")
        XCTAssertEqual(outcome.review, "Looks good")
        XCTAssertEqual(outcome.tasks.map(\.title), ["Write file A", "Write file B"])
        XCTAssertEqual(outcome.tasks.map(\.status), [.done, .done])
        XCTAssertEqual(outcome.results, ["1": "Did #1", "2": "Did #2"])
        XCTAssertEqual(outcome.tasks.map(\.assignee), ["worker", "worker"])
        XCTAssertEqual(outcome.tasks.map(\.attempts), [1, 1])
        // Lead 3 turns + worker 4 + reviewer 2, each 10 in / 2 out.
        XCTAssertEqual(outcome.usage, Usage(inputTokens: 90, outputTokens: 18))
        XCTAssertEqual(outcome.usageByMember["worker"], Usage(inputTokens: 40, outputTokens: 8))
        let commands = await surface.shellCommands
        XCTAssertEqual(Set(commands), ["echo 1", "echo 2"])
        XCTAssertEqual(phases(team), [.planning, .working, .reviewing, .reporting, .finished])
        let phase = await team.phase
        XCTAssertEqual(phase, .finished)

        // The reviewer saw the results; the lead's report prompt carried the verdict.
        let reviewPrompt = reviewer.requests.first?.lastUserText ?? ""
        XCTAssertTrue(reviewPrompt.contains("Did #1") && reviewPrompt.contains("Did #2"), reviewPrompt)
        let reportPrompt = lead.requests.last?.lastUserText ?? ""
        XCTAssertTrue(reportPrompt.contains("Looks good"), reportPrompt)

        // Each member got the tools of its duties, and the team instructions.
        XCTAssertTrue(lead.requests[0].tools.contains { $0.name == "board_plan" })
        XCTAssertFalse(worker.requests[0].tools.contains { $0.name == "board_plan" })
        XCTAssertTrue(worker.requests[0].tools.contains { $0.name == "board_update" })
        XCTAssertTrue(worker.requests[0].tools.contains { $0.name == "team_send" })
        XCTAssertTrue(reviewer.requests[0].tools.contains { $0.name == "board_reopen" })
        let system = worker.requests[0].messages.first?.text ?? ""
        XCTAssertTrue(system.contains("You are Worker, the worker of a team"), system)

        // Board changes reached the activity panel as notes from the Team pseudo-agent.
        let notes = bus.history.filter { $0.agentID == "team:t1" }
            .compactMap { e -> String? in if case .note(let n) = e.event { return n } else { return nil } }
        XCTAssertTrue(notes.contains { $0.contains("Task #2") && $0.contains("done") }, "\(notes)")
        // Members' own events carry their member ids.
        XCTAssertTrue(bus.history.contains { $0.agentID == "worker" && $0.agentName == "Worker" })

        let statuses = await team.memberStatuses()
        XCTAssertEqual(statuses, ["lead": .finished, "worker": .finished, "reviewer": .finished])
    }

    func testTwoWorkersShareTheScreenWithoutInterleavingInput() async {
        let surface = MockSurface(inputDelayMilliseconds: 20)
        let lead = ScriptedClient.script([
            toolTurn("p1", "board_plan", ["tasks": .array([
                ["title": "Type one", "assignee": "Ann"],
                ["title": "Type two", "assignee": "Bob"],
            ])]),
            completeTurn("p2", "Planned"),
            completeTurn("r1", "Both typed"),
        ])
        func typist(_ name: String) -> ScriptedClient {
            ScriptedClient(name: name) { req in
                let n = taskNumber(in: req.lastUserText)
                if req.isNewRun {
                    return toolTurn("t\(req.index)", "computer", ["action": "type", "text": .string("\(name)-\(n)")])
                }
                return completeTurn("c\(req.index)", "Typed \(n)")
            }
        }
        let spec = TeamSpec(members: [teamMember("lead", .lead), teamMember("ann", .worker), teamMember("bob", .worker)],
                            goal: "Type two things", maxParallelWorkers: 2, defaultPolicy: quietPolicy())
        let team = TeamRunner(spec: spec, surface: surface,
                              clientFactory: factory(["lead": lead, "ann": typist("ann"), "bob": typist("bob")]))

        let outcome = await runTeam(team)

        XCTAssertTrue(outcome.success, outcome.report)
        XCTAssertEqual(outcome.tasks.map(\.assignee), ["ann", "bob"])
        // Each agent's typing is followed by its own follow-up screenshot before the other agent types.
        let calls = await surface.calls
        XCTAssertEqual(calls.count, 4, "\(calls)")
        if calls.count == 4 {
            XCTAssertEqual(calls[1], .screenshot)
            XCTAssertEqual(calls[3], .screenshot)
            XCTAssertEqual(Set([calls[0], calls[2]]), [.type("ann-1"), .type("bob-2")])
        }
    }

    func testDependentTaskWaitsAndSeesTheEarlierResult() async {
        let lead = ScriptedClient.script([
            toolTurn("p1", "board_plan", ["tasks": .array([
                ["title": "Find the port"],
                ["title": "Open the firewall", "depends_on": .array(["1"])],
            ])]),
            completeTurn("p2", "Planned"),
            completeTurn("r1", "Done"),
        ])
        let ann = shellWorker("ann")
        let bob = shellWorker("bob")
        let spec = TeamSpec(members: [teamMember("lead", .lead), teamMember("ann", .worker), teamMember("bob", .worker)],
                            goal: "Open the port", maxParallelWorkers: 2, defaultPolicy: quietPolicy())
        let team = TeamRunner(spec: spec, surface: MockSurface(), clientFactory: factory(["lead": lead, "ann": ann, "bob": bob]))

        let outcome = await runTeam(team)

        XCTAssertTrue(outcome.success, outcome.report)
        XCTAssertEqual(outcome.tasks[1].dependsOn, ["1"])
        let prompts = (ann.requests + bob.requests).map(\.lastUserText).filter { $0.contains("Task #2") }
        XCTAssertFalse(prompts.isEmpty)
        XCTAssertTrue(prompts.allSatisfy { $0.contains("Did #1") }, "task 2 starts after task 1 with its result: \(prompts)")
    }

    func testFailedTaskIsRetriedOnce() async {
        let lead = ScriptedClient.script([
            toolTurn("p1", "board_plan", ["tasks": .array([["title": "Flaky download"]])]),
            completeTurn("p2", "Planned"),
            completeTurn("r1", "Downloaded on the second try"),
        ])
        let worker = ScriptedClient(name: "worker") { req in
            req.index == 0 ? completeTurn("a", "network down", success: false) : completeTurn("b", "worked the second time")
        }
        let spec = TeamSpec(members: [teamMember("lead", .lead), teamMember("worker", .worker)], goal: "Download it",
                            defaultPolicy: quietPolicy())
        let team = TeamRunner(spec: spec, clientFactory: factory(["lead": lead, "worker": worker]))

        let outcome = await runTeam(team)

        XCTAssertTrue(outcome.success, outcome.report)
        let task = outcome.tasks.first
        XCTAssertEqual(task?.status, .done)
        XCTAssertEqual(task?.attempts, 2)
        XCTAssertEqual(task?.result, "worked the second time")
        XCTAssertEqual(task?.history, ["Attempt 1 failed: network down"])
        // The retry prompt told the worker about the failed attempt.
        XCTAssertTrue(worker.requests.last?.lastUserText.contains("network down") ?? false)
        XCTAssertEqual(phases(team), [.planning, .working, .reporting, .finished])
    }

    func testTaskFailingTwiceIsMarkedFailed() async {
        let lead = ScriptedClient.script([
            toolTurn("p1", "board_plan", ["tasks": .array([["title": "Impossible"]])]),
            completeTurn("p2", "Planned"),
            [.finished(.stop)],   // the report run fails (empty reply)
        ])
        let worker = ScriptedClient(name: "worker") { req in completeTurn("x\(req.index)", "no luck \(req.index)", success: false) }
        let spec = TeamSpec(members: [teamMember("lead", .lead), teamMember("worker", .worker)], goal: "Do the impossible",
                            defaultPolicy: quietPolicy())
        let team = TeamRunner(spec: spec, clientFactory: factory(["lead": lead, "worker": worker]))

        let outcome = await runTeam(team)

        XCTAssertFalse(outcome.success)
        XCTAssertEqual(outcome.tasks.first?.status, .failed)
        XCTAssertEqual(outcome.tasks.first?.attempts, 2)
        XCTAssertEqual(worker.requests.count, 2, "exactly one retry")
        XCTAssertTrue(outcome.report.hasPrefix("0 of 1 task done for: Do the impossible"),
                      "the lead's failed report run falls back to a summary: \(outcome.report)")
        XCTAssertTrue(outcome.report.contains("#1 Impossible: failed"), outcome.report)
        let phase = await team.phase
        XCTAssertEqual(phase, .failed)
    }

    func testStopEndsEveryone() async throws {
        let lead = ScriptedClient.script([
            toolTurn("p1", "board_plan", ["tasks": .array([["title": "Slow one"], ["title": "Slow two"]])]),
            completeTurn("p2", "Planned"),
        ])
        let slow: @Sendable (ScriptedClient.Request) async -> [StreamEvent] = { _ in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            return [.textDelta("too late"), .finished(.stop)]
        }
        let ann = ScriptedClient(name: "ann", handler: slow)
        let bob = ScriptedClient(name: "bob", handler: slow)
        let spec = TeamSpec(members: [teamMember("lead", .lead), teamMember("ann", .worker), teamMember("bob", .worker)],
                            goal: "Take forever", maxParallelWorkers: 2, defaultPolicy: quietPolicy())
        let team = TeamRunner(spec: spec, surface: MockSurface(), clientFactory: factory(["lead": lead, "ann": ann, "bob": bob]))

        try await team.start()
        await waitUntil {
            let a = await team.status(of: "ann")
            let b = await team.status(of: "bob")
            return a == .thinking && b == .thinking
        }
        let stopAt = Date()
        await team.stop()
        let outcome = await team.waitForCompletion()

        XCTAssertLessThan(Date().timeIntervalSince(stopAt), 5)
        XCTAssertEqual(outcome?.stopped, true)
        XCTAssertEqual(outcome?.success, false)
        XCTAssertEqual(outcome?.report, "Stopped by the user.")
        XCTAssertEqual(outcome?.tasks.map(\.status), [.todo, .todo], "interrupted tasks go back to the board")
        XCTAssertEqual(outcome?.tasks.map(\.attempts), [0, 0])
        for id in ["lead", "ann", "bob"] {
            let running = await team.runner(for: id)?.isRunning
            XCTAssertEqual(running, false, id)
        }
        let annStatus = await team.status(of: "ann")
        XCTAssertEqual(annStatus, .stopped)
        let phase = await team.phase
        XCTAssertEqual(phase, .stopped)
        let held = await team.lease?.isHeld
        XCTAssertEqual(held, false)
    }

    func testMessagesReachATeammateThroughTheInbox() async {
        let lead = ScriptedClient.script([
            toolTurn("m1", "team_send", ["to": "Worker", "text": "Use tabs, not spaces."]),
            toolTurn("p1", "board_plan", ["tasks": .array([["title": "Format the code"]])]),
            completeTurn("p2", "Planned"),
            completeTurn("r1", "Formatted"),
        ])
        let worker = ScriptedClient(name: "worker") { req in
            if req.isNewRun { return toolTurn("i\(req.index)", "team_inbox") }
            return completeTurn("c\(req.index)", "Inbox: \(req.lastToolResultText)")
        }
        let spec = TeamSpec(members: [teamMember("lead", .lead), teamMember("worker", .worker)], goal: "Format",
                            defaultPolicy: quietPolicy())
        let team = TeamRunner(spec: spec, clientFactory: factory(["lead": lead, "worker": worker]))

        let outcome = await runTeam(team)

        XCTAssertTrue(outcome.success, outcome.report)
        XCTAssertEqual(outcome.tasks.first?.result, "Inbox: From Lead: Use tabs, not spaces.")
        let prompt = worker.requests.first?.lastUserText ?? ""
        XCTAssertTrue(prompt.contains("1 unread team message"), prompt)
        let log = await team.messages.messages
        XCTAssertEqual(log.map(\.to), ["worker"])
        let delivered = team.hub.history.contains { if case .message(let m) = $0 { return m.from == "lead" } else { return false } }
        XCTAssertTrue(delivered)
    }

    func testApprovalsPassThroughToTheMemberThatAsked() async throws {
        let surface = MockSurface()
        let lead = ScriptedClient.script([
            toolTurn("p1", "board_plan", ["tasks": .array([["title": "Clean the build"]])]),
            completeTurn("p2", "Planned"),
            completeTurn("r1", "Cleaned"),
        ])
        let worker = ScriptedClient(name: "worker") { req in
            if req.isNewRun { return toolTurn("rm\(req.index)", "shell", ["command": "rm -rf /tmp/build"]) }
            return completeTurn("c\(req.index)", "Removed the build folder")
        }
        let spec = TeamSpec(members: [teamMember("lead", .lead), teamMember("worker", .worker)], goal: "Clean up",
                            defaultPolicy: quietPolicy(.destructiveOnly))
        let team = TeamRunner(spec: spec, surface: surface, clientFactory: factory(["lead": lead, "worker": worker]))

        try await team.start()
        await waitUntil { await team.pendingApprovals().count == 1 }
        let pending = await team.pendingApprovals()
        XCTAssertEqual(pending.first?.agentID, "worker")
        let notYet = await surface.shellCommands
        XCTAssertEqual(notYet, [])
        let wrongMember = await team.approve(id: pending[0].id, decision: .approve, memberID: "lead")
        XCTAssertFalse(wrongMember)
        let approved = await team.approve(id: pending[0].id, decision: .approve)
        XCTAssertTrue(approved)

        let outcome = await runTeam(team)
        XCTAssertTrue(outcome.success, outcome.report)
        let commands = await surface.shellCommands
        XCTAssertEqual(commands, ["rm -rf /tmp/build"])
    }

    func testReviewerReopensATaskOnce() async {
        let lead = ScriptedClient.script([
            toolTurn("p1", "board_plan", ["tasks": .array([["title": "Write the README"]])]),
            completeTurn("p2", "Planned"),
            completeTurn("r1", "README written with an install section"),
        ])
        let worker = ScriptedClient(name: "worker") { req in
            let reopened = req.lastUserText.contains("add an install section")
            return completeTurn("w\(req.index)", reopened ? "README v2 with install section" : "README v1")
        }
        let reviewer = ScriptedClient.script([
            toolTurn("v1", "board_reopen", ["id": "1", "feedback": "add an install section"]),
            completeTurn("v2", "Reopened #1 for the install section"),
        ])
        let spec = TeamSpec(members: [teamMember("lead", .lead), teamMember("worker", .worker), teamMember("reviewer", .reviewer)],
                            goal: "Document the project", defaultPolicy: quietPolicy())
        let team = TeamRunner(spec: spec, clientFactory: factory(["lead": lead, "worker": worker, "reviewer": reviewer]))

        let outcome = await runTeam(team)

        XCTAssertTrue(outcome.success, outcome.report)
        let task = outcome.tasks.first
        XCTAssertEqual(task?.result, "README v2 with install section")
        XCTAssertEqual(task?.reopenCount, 1)
        XCTAssertEqual(worker.requests.count, 2)
        XCTAssertEqual(reviewer.requests.count, 2, "one review round")
        XCTAssertEqual(phases(team), [.planning, .working, .reviewing, .working, .reporting, .finished])
    }

    func testPlanFallsBackToTheLeadsListOrTheWholeGoal() async {
        // A plain-text list becomes the plan.
        let listLead = ScriptedClient.script([
            [.textDelta("Plan:\n1. Install the server\n2. Start the server"), .finished(.stop)],
            completeTurn("r1", "Server running"),
        ])
        let listTeam = TeamRunner(spec: TeamSpec(members: [teamMember("lead", .lead), teamMember("worker", .worker)],
                                                 goal: "Run a server", defaultPolicy: quietPolicy()),
                                  surface: MockSurface(), clientFactory: factory(["lead": listLead, "worker": shellWorker("worker")]))
        let listOutcome = await runTeam(listTeam)
        XCTAssertTrue(listOutcome.success, listOutcome.report)
        XCTAssertEqual(listOutcome.tasks.map(\.title), ["Install the server", "Start the server"])

        // No plan at all: the goal is one task.
        let lazyLead = ScriptedClient.script([
            [.textDelta("I will leave it to the team."), .finished(.stop)],
            completeTurn("r1", "Done"),
        ])
        let lazyTeam = TeamRunner(spec: TeamSpec(members: [teamMember("lead", .lead), teamMember("worker", .worker)],
                                                 goal: "Tidy the desktop\nand empty the trash", defaultPolicy: quietPolicy()),
                                  surface: MockSurface(), clientFactory: factory(["lead": lazyLead, "worker": shellWorker("worker")]))
        let lazyOutcome = await runTeam(lazyTeam)
        XCTAssertTrue(lazyOutcome.success, lazyOutcome.report)
        XCTAssertEqual(lazyOutcome.tasks.map(\.title), ["Tidy the desktop"])
        XCTAssertEqual(lazyOutcome.tasks.first?.detail, "Tidy the desktop\nand empty the trash")
    }

    func testStartFailsForABadSpecOrClient() async {
        let empty = TeamRunner(spec: TeamSpec(members: [], goal: "x"), clientFactory: factory([:]))
        do {
            try await empty.start()
            XCTFail("an empty team cannot start")
        } catch {}
        let noClient = TeamRunner(spec: TeamSpec(members: [teamMember("lead", .lead)], goal: "x"), clientFactory: factory([:]))
        let outcome = await noClient.run()
        XCTAssertFalse(outcome.success)
        XCTAssertTrue(outcome.report.contains("could not start"), outcome.report)
    }

    func testUserMessagesGoToTheNamedMember() async throws {
        let gate = Gate()
        let lead = ScriptedClient.script([
            toolTurn("p1", "board_plan", ["tasks": .array([["title": "Wait for the user"]])]),
            completeTurn("p2", "Planned"),
            completeTurn("r1", "Done"),
        ])
        let worker = ScriptedClient(name: "worker") { req in
            if req.index == 0 {
                await gate.wait()
                return toolTurn("w0", "board_list")
            }
            return completeTurn("w\(req.index)", "User said: \(req.lastUserText)")
        }
        let spec = TeamSpec(members: [teamMember("lead", .lead), teamMember("worker", .worker)], goal: "Listen",
                            defaultPolicy: quietPolicy())
        let team = TeamRunner(spec: spec, clientFactory: factory(["lead": lead, "worker": worker]))
        try await team.start()
        await waitUntil { await team.status(of: "worker") == .thinking }
        let sent = await team.send(userMessage: "Use the blue theme", to: "Worker")
        XCTAssertTrue(sent)
        let unknown = await team.send(userMessage: "hello", to: "Nobody")
        XCTAssertFalse(unknown)
        await gate.open()

        let outcome = await runTeam(team)
        XCTAssertEqual(outcome.tasks.first?.result, "User said: Use the blue theme")
        let log = await team.messages.messages
        XCTAssertEqual(log.first?.from, TeamRoster.userID)
        let inbox = await team.messages.inbox(for: "worker")
        XCTAssertEqual(inbox, [], "user messages go straight to the agent, not to its inbox")
    }
}

extension TeamRunnerTests {
    func testPauseHoldsTheTeamUntilResume() async throws {
        let gate = Gate()
        let lead = ScriptedClient.script([
            toolTurn("p1", "board_plan", ["tasks": .array([["title": "Look at the board"]])]),
            completeTurn("p2", "Planned"),
            completeTurn("r1", "Done"),
        ])
        let worker = ScriptedClient(name: "worker") { req in
            if req.index == 0 {
                await gate.wait()
                return toolTurn("w0", "board_list")
            }
            return completeTurn("w\(req.index)", "Looked")
        }
        let spec = TeamSpec(members: [teamMember("lead", .lead), teamMember("worker", .worker)], goal: "Look",
                            defaultPolicy: quietPolicy())
        let team = TeamRunner(spec: spec, clientFactory: factory(["lead": lead, "worker": worker]))
        try await team.start()
        await waitUntil { await team.status(of: "worker") == .thinking }

        await team.pause()
        let paused = await team.isPaused
        XCTAssertTrue(paused)
        let status = await team.status(of: "worker")
        XCTAssertEqual(status, .paused)
        await gate.open()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(worker.requests.count, 1, "no new model call while paused")
        let phase = await team.phase
        XCTAssertEqual(phase, .working)

        await team.resume()
        let outcome = await runTeam(team)
        XCTAssertTrue(outcome.success, outcome.report)
        XCTAssertEqual(worker.requests.count, 2)
    }

    func testEventsMergeAgentAndTeamEvents() async {
        let lead = ScriptedClient.script([
            toolTurn("p1", "board_plan", ["tasks": .array([["title": "One thing"]])]),
            completeTurn("p2", "Planned"),
            completeTurn("r1", "Done"),
        ])
        let spec = TeamSpec(members: [teamMember("lead", .lead), teamMember("worker", .worker)], goal: "One thing",
                            defaultPolicy: quietPolicy())
        let team = TeamRunner(spec: spec, surface: MockSurface(), clientFactory: factory(["lead": lead, "worker": shellWorker("worker")]))
        let feed = team.events()
        let collector = Task { () async -> (agentIDs: Set<String>, teamEvents: Int) in
            var ids = Set<String>()
            var count = 0
            for await item in feed {
                switch item {
                case .agent(let envelope):
                    ids.insert(envelope.agentID)
                case .team(let event):
                    count += 1
                    if case .finished = event { return (ids, count) }
                }
            }
            return (ids, count)
        }
        let outcome = await runTeam(team)
        XCTAssertTrue(outcome.success, outcome.report)
        let seen = await collector.value
        XCTAssertEqual(seen.agentIDs, ["lead", "worker"], "agent events of the members (team notes come as team events)")
        XCTAssertGreaterThan(seen.teamEvents, 5)
    }
}

/// Suspends callers until opened.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let w = waiters
        waiters.removeAll()
        for c in w { c.resume() }
    }
}
