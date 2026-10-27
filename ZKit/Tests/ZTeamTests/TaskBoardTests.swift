import Foundation
import XCTest
import ZCore
import ZAgent
@testable import ZTeam

final class TaskBoardTests: XCTestCase {
    func testDependenciesGateClaiming() async throws {
        let board = TaskBoard()
        let tasks = await board.plan(from: [
            TaskDraft(title: "Install"),
            TaskDraft(title: "Configure", dependsOn: ["1"]),
            TaskDraft(title: "Test", dependsOn: ["Configure"]),
        ])
        XCTAssertEqual(tasks.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(tasks[1].dependsOn, ["1"])
        XCTAssertEqual(tasks[2].dependsOn, ["2"])

        let first = await board.claimNext(for: "a")
        XCTAssertEqual(first?.id, "1")
        XCTAssertEqual(first?.status, .doing)
        XCTAssertEqual(first?.assignee, "a")
        XCTAssertEqual(first?.attempts, 1)
        let none = await board.claimNext(for: "b")
        XCTAssertNil(none, "task 2 waits for task 1")
        let satisfied = await board.dependenciesSatisfied("2")
        XCTAssertFalse(satisfied)

        // b waits for work; finishing task 1 wakes it and hands it task 2.
        let waiter = Task { await board.nextClaim(for: "b") }
        try await Task.sleep(nanoseconds: 50_000_000)
        await board.finishAttempt("1", success: true, result: "installed")
        let second = await waiter.value
        XCTAssertEqual(second?.id, "2")
        XCTAssertEqual(second?.assignee, "b")

        let early = await board.claimNext(for: "a")
        XCTAssertNil(early, "task 3 waits for task 2")
        await board.finishAttempt("2", success: true, result: "configured")
        let third = await board.claimNext(for: "a")
        XCTAssertEqual(third?.id, "3")
        await board.finishAttempt("#3", success: true, result: "tested")

        let more = await board.nextClaim(for: "a")
        XCTAssertNil(more, "no work left: nextClaim returns at once")
        let allDone = await board.allDone
        XCTAssertTrue(allDone)
        let results = await board.tasks.map { $0.result ?? "" }
        XCTAssertEqual(results, ["installed", "configured", "tested"])
    }

    func testAssignedTasksGoOnlyToTheirMember() async {
        let board = TaskBoard()
        await board.plan(from: [TaskDraft(title: "For Bob", assignee: "bob"), TaskDraft(title: "Anyone")])
        let ann = await board.claimNext(for: "ann")
        XCTAssertEqual(ann?.title, "Anyone")
        let annAgain = await board.claimNext(for: "ann")
        XCTAssertNil(annAgain)
        let bob = await board.claimNext(for: "bob")
        XCTAssertEqual(bob?.title, "For Bob")
    }

    func testFailedTaskIsRetriedOnceThenBlocksItsDependents() async throws {
        let board = TaskBoard(maxAttempts: 2)
        await board.plan(from: [TaskDraft(title: "Build"), TaskDraft(title: "Ship", dependsOn: ["1"])])

        let attempt1 = await board.claimNext(for: "a")
        XCTAssertEqual(attempt1?.attempts, 1)
        let afterFirst = await board.finishAttempt("1", success: false, result: "compiler crashed")
        XCTAssertEqual(afterFirst?.status, .todo, "a failed task gets one more attempt")
        XCTAssertNil(afterFirst?.assignee, "anyone may retry it")
        XCTAssertEqual(afterFirst?.history, ["Attempt 1 failed: compiler crashed"])

        let attempt2 = await board.claimNext(for: "b")
        XCTAssertEqual(attempt2?.id, "1")
        XCTAssertEqual(attempt2?.attempts, 2)
        let final = await board.finishAttempt("1", success: false, result: "still broken")
        XCTAssertEqual(final?.status, .failed)
        XCTAssertEqual(final?.result, "still broken")

        let ship = await board.task("2")
        XCTAssertEqual(ship?.status, .blocked)
        XCTAssertEqual(ship?.blockedByDependency, true)
        let next = await board.nextClaim(for: "a")
        XCTAssertNil(next, "nothing can be done any more")

        // Reopening the failed task unblocks its dependent.
        let reopened = try await board.reopen("1", feedback: "use the other compiler")
        XCTAssertEqual(reopened.status, .todo)
        XCTAssertEqual(reopened.attempts, 0)
        XCTAssertEqual(reopened.reopenCount, 1)
        let shipAgain = await board.task("2")
        XCTAssertEqual(shipAgain?.status, .todo)

        _ = await board.claimNext(for: "a")
        await board.finishAttempt("1", success: true, result: "built")
        do {
            _ = try await board.reopen("1", feedback: "again")
            XCTFail("a task can be reopened only once")
        } catch {
            XCTAssertTrue("\(error)".contains("already reopened"), "\(error)")
        }
    }

    func testAgentStatusesAreKeptWhenTheAttemptEnds() async throws {
        let board = TaskBoard()
        await board.plan(from: [TaskDraft(title: "Done early"), TaskDraft(title: "Stuck")])
        _ = await board.claimNext(for: "a")
        _ = await board.claimNext(for: "b")
        try await board.update("1", status: .done, result: "finished via board_update", by: "a")
        try await board.update("2", status: .blocked, result: "needs a password", by: "b")
        let one = await board.finishAttempt("1", success: false, result: "run ended oddly")
        XCTAssertEqual(one?.status, .done)
        XCTAssertEqual(one?.result, "finished via board_update")
        let two = await board.finishAttempt("2", success: false, result: "gave up")
        XCTAssertEqual(two?.status, .blocked)
        XCTAssertEqual(two?.result, "needs a password")
        XCTAssertEqual(two?.attempts, 1)
    }

    func testDependencyCycleIsBlocked() async {
        let board = TaskBoard()
        let tasks = await board.plan(from: [TaskDraft(title: "A", dependsOn: ["2"]), TaskDraft(title: "B", dependsOn: ["1"]),
                                            TaskDraft(title: "C", dependsOn: ["C", "99"])])
        XCTAssertEqual(tasks.map(\.status), [.blocked, .blocked, .todo])
        XCTAssertEqual(tasks[2].dependsOn, [], "self and unknown references are dropped")
        let claim = await board.claimNext(for: "a")
        XCTAssertEqual(claim?.title, "C")
    }

    func testChangesAreReportedAsTeamEventsAndBusNotes() async {
        let bus = EventBus()
        let reporter = TeamReporter(hub: TeamEventHub(), bus: bus, agentID: "team", agentName: "Team",
                                    roster: TeamRoster([teamMember("ann", .worker)]))
        let board = TaskBoard(reporter: reporter)
        let stream = board.events()
        await board.add(title: "Write docs")
        _ = await board.claimNext(for: "ann")

        var iterator = stream.makeAsyncIterator()
        let e1 = await iterator.next()
        let e2 = await iterator.next()
        if case .taskAdded(let t)? = e1 { XCTAssertEqual(t.title, "Write docs") } else { XCTFail("\(String(describing: e1))") }
        if case .taskUpdated(let t)? = e2 { XCTAssertEqual(t.status, .doing) } else { XCTFail("\(String(describing: e2))") }

        let notes = bus.history.compactMap { e -> String? in if case .note(let n) = e.event { return n } else { return nil } }
        XCTAssertTrue(notes.contains { $0.contains("Task #1") && $0.contains("doing") && $0.contains("Ann") }, "\(notes)")
        XCTAssertTrue(bus.history.allSatisfy { $0.agentID == "team" && $0.agentName == "Team" })
    }

    func testDraftParsingIsLenient() {
        let json: JSONValue = ["tasks": .array([
            ["title": "Install nginx", "detail": "apt install nginx", "depends_on": .array([])],
            ["name": "Configure", "description": "edit the conf", "dependsOn": .array([1]), "assignee": "Bob"],
            .string("Test it"),
        ])]
        let drafts = TaskDraft.parse(json)
        XCTAssertEqual(drafts.map(\.title), ["Install nginx", "Configure", "Test it"])
        XCTAssertEqual(drafts[0].detail, "apt install nginx")
        XCTAssertEqual(drafts[1].detail, "edit the conf")
        XCTAssertEqual(drafts[1].dependsOn, ["1"])
        XCTAssertEqual(drafts[1].assignee, "Bob")

        let fromString = TaskDraft.parse(.string(#"[{"title":"A"},{"title":"B","after":"1"}]"#))
        XCTAssertEqual(fromString.map(\.title), ["A", "B"])
        XCTAssertEqual(fromString[1].dependsOn, ["1"])

        let list = TaskDraft.parseList("Plan:\n1. Install it\n2) **Configure** it\n- Test it\nThanks")
        XCTAssertEqual(list.map(\.title), ["Install it", "Configure it", "Test it"])
        XCTAssertEqual(TaskStatus(lenient: "In Progress"), .doing)
        XCTAssertEqual(TaskStatus(lenient: "completed"), .done)
        XCTAssertNil(TaskStatus(lenient: "maybe"))
    }

    func testSpecCodingAndRoles() throws {
        let spec = TeamSpec(members: [teamMember("ada", .lead), teamMember("bob", .custom("tester"))], goal: "Ship it",
                            defaultPolicy: quietPolicy())
        let back = try JSONDecoder().decode(TeamSpec.self, from: JSONEncoder().encode(spec))
        XCTAssertEqual(back, spec)
        XCTAssertEqual(back.lead?.id, "ada")
        XCTAssertEqual(back.workers.map(\.id), ["bob"])
        XCTAssertNil(back.reviewer)
        XCTAssertEqual(back.duties(of: "ada"), [.plan])
        XCTAssertEqual(back.duties(of: "bob"), [.work])
        XCTAssertEqual(TeamRole(rawValue: " Reviewer "), .reviewer)
        XCTAssertEqual(TeamRole(rawValue: "tester"), .custom("tester"))

        let minimal = #"{"members":[{"name":"Solo","model":{"provider":"mock","model":"m"}}],"goal":"x"}"#
        let decoded = try JSONDecoder().decode(TeamSpec.self, from: Data(minimal.utf8))
        XCTAssertEqual(decoded.maxParallelWorkers, 2)
        XCTAssertFalse(decoded.shellOutsideLease)
        XCTAssertEqual(decoded.members.first?.role, .worker)
        // A lone member plans and works.
        let solo = try XCTUnwrap(decoded.members.first)
        XCTAssertEqual(decoded.duties(of: solo.id), [.plan, .work])
        XCTAssertNoThrow(try decoded.validate())
        XCTAssertThrowsError(try TeamSpec(members: [], goal: "x").validate())
    }
}
