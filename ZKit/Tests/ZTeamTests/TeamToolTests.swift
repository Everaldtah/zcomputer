import Foundation
import XCTest
import ZCore
import ZAgent
@testable import ZTeam

final class TeamToolTests: XCTestCase {
    private struct Fixture {
        let board: TaskBoard
        let messages: MessageBus
        let registry: ToolRegistry

        func run(_ name: String, _ arguments: JSONValue = [:], as member: String) async -> ToolResult {
            let emitter = AgentEmitter(agentID: member, agentName: member, sink: EventBus())
            let ctx = ToolContext(agentID: member, emitter: emitter, approval: ApprovalGate(mode: .never, emitter: emitter))
            return await registry.execute(ToolCall(id: UUID().uuidString, name: name, arguments: arguments), ctx: ctx)
        }
    }

    private func fixture() -> Fixture {
        let spec = TeamSpec(members: [teamMember("ada", .lead), teamMember("bob", .worker), teamMember("cy", .reviewer)], goal: "g")
        let roster = spec.roster
        let board = TaskBoard(reporter: TeamReporter(roster: roster))
        let messages = MessageBus(roster: roster)
        var duties: [String: TeamDuties] = [:]
        for m in spec.members { duties[m.id] = spec.duties(of: m.id) }
        let toolbox = TeamToolbox(board: board, messages: messages, roster: roster, duties: duties)
        return Fixture(board: board, messages: messages, registry: ToolRegistry(toolbox.allTools))
    }

    func testTeamSendInboxAndBroadcast() async {
        let f = fixture()
        let sent = await f.run("team_send", ["to": "Bob", "text": "Use port 8080"], as: "ada")
        XCTAssertFalse(sent.isError, sent.text)
        XCTAssertTrue(sent.text.contains("Bob"), sent.text)

        let inbox = await f.run("team_inbox", as: "bob")
        XCTAssertEqual(inbox.text, "From Ada: Use port 8080")
        let again = await f.run("team_inbox", as: "bob")
        XCTAssertEqual(again.text, "No new messages.")
        let notForAda = await f.run("team_inbox", as: "ada")
        XCTAssertEqual(notForAda.text, "No new messages.")

        let byRole = await f.run("team_send", ["to": "reviewer", "text": "Please check #1"], as: "bob")
        XCTAssertFalse(byRole.isError, byRole.text)
        let cyInbox = await f.run("team_inbox", as: "cy")
        XCTAssertEqual(cyInbox.text, "From Bob: Please check #1")

        let unknown = await f.run("team_send", ["to": "Zed", "text": "hi"], as: "ada")
        XCTAssertTrue(unknown.isError)
        XCTAssertTrue(unknown.text.contains("Zed"), unknown.text)
        let toSelf = await f.run("team_send", ["to": "ada", "text": "hi"], as: "ada")
        XCTAssertTrue(toSelf.isError)

        let broadcast = await f.run("team_broadcast", ["text": "Review done"], as: "cy")
        XCTAssertFalse(broadcast.isError, broadcast.text)
        let adaInbox = await f.run("team_inbox", as: "ada")
        XCTAssertEqual(adaInbox.text, "From Cy (to everyone): Review done")
        let bobInbox = await f.run("team_inbox", as: "bob")
        XCTAssertEqual(bobInbox.text, "From Cy (to everyone): Review done")
        let cyOwn = await f.run("team_inbox", as: "cy")
        XCTAssertEqual(cyOwn.text, "No new messages.", "the sender does not get its own broadcast")

        // Other team tools remind the agent of unread messages.
        _ = await f.run("team_send", ["to": "Bob", "text": "ping"], as: "ada")
        let list = await f.run("board_list", as: "bob")
        XCTAssertTrue(list.text.contains("1 unread team message"), list.text)
    }

    func testBoardToolsPlanClaimUpdateAndReopen() async {
        let f = fixture()
        let plan = await f.run("board_plan", ["tasks": .array([
            ["title": "Install", "assignee": "Bob"],
            ["title": "Configure", "depends_on": .array([1]), "assignee": "Cy"],
        ])], as: "ada")
        XCTAssertFalse(plan.isError, plan.text)
        XCTAssertTrue(plan.text.contains("Added 2 tasks"), plan.text)
        XCTAssertTrue(plan.text.contains("Ignored assignees that are not workers: Cy"), plan.text)
        let tasks = await f.board.tasks
        XCTAssertEqual(tasks.map(\.assignee), ["bob", nil])
        XCTAssertEqual(tasks[1].dependsOn, ["1"])

        let empty = await f.run("board_plan", ["tasks": .array([])], as: "ada")
        XCTAssertTrue(empty.isError)

        let claim = await f.run("board_claim", as: "bob")
        XCTAssertTrue(claim.text.contains("Task #1: Install"), claim.text)
        let nothing = await f.run("board_claim", as: "bob")
        XCTAssertTrue(nothing.text.contains("No task is ready"), nothing.text)

        // Workers update only their own tasks; the lead may update any.
        let notMine = await f.run("board_update", ["id": "1", "status": "done"], as: "dan")
        XCTAssertTrue(notMine.isError, notMine.text)
        let badStatus = await f.run("board_update", ["id": "1", "status": "maybe"], as: "bob")
        XCTAssertTrue(badStatus.isError)
        let done = await f.run("board_update", ["id": "#1", "status": "completed", "result": "nginx installed"], as: "bob")
        XCTAssertFalse(done.isError, done.text)
        XCTAssertEqual(done.text, "Task #1 is done.")
        let first = await f.board.task("1")
        XCTAssertEqual(first?.result, "nginx installed")

        let list = await f.run("board_list", as: "cy")
        XCTAssertTrue(list.text.contains("#1 [done] Install — Bob"), list.text)
        XCTAssertTrue(list.text.contains("#2 [todo] Configure (after #1)"), list.text)

        let reopen = await f.run("board_reopen", ["id": "1", "feedback": "also enable it at boot"], as: "cy")
        XCTAssertFalse(reopen.isError, reopen.text)
        let reopened = await f.board.task("1")
        XCTAssertEqual(reopened?.status, .todo)
        XCTAssertEqual(reopened?.history.last, "Reopened by the reviewer: also enable it at boot")
        let unknown = await f.run("board_reopen", ["id": "9", "feedback": "x"], as: "cy")
        XCTAssertTrue(unknown.isError)
    }

    func testToolsMatchDuties() {
        let spec = TeamSpec(members: [teamMember("ada", .lead), teamMember("bob", .worker), teamMember("cy", .reviewer)], goal: "g")
        let toolbox = TeamToolbox(board: TaskBoard(), messages: MessageBus(roster: spec.roster), roster: spec.roster)
        let names = { (d: TeamDuties) in Set(toolbox.tools(for: d).map { $0.spec.name }) }
        let common: Set<String> = ["team_send", "team_broadcast", "team_inbox", "board_list"]
        XCTAssertEqual(names([.plan]), common.union(["board_plan"]))
        XCTAssertEqual(names([.work]), common.union(["board_claim", "board_update"]))
        XCTAssertEqual(names([.review]), common.union(["board_reopen"]))
        XCTAssertEqual(Set(toolbox.tools(for: [.review], allowReopen: false).map { $0.spec.name }), common)
        XCTAssertTrue(toolbox.allTools.allSatisfy { $0.risk(of: ToolCall(id: "x", name: $0.spec.name, arguments: [:])).level == .readOnly })
    }
}
