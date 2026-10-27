import Foundation
import XCTest
import ZCore
@testable import ZAgent

final class AgentRunnerTests: XCTestCase {
    private func quietPolicy(_ mode: ApprovalMode = .destructiveOnly) -> AgentPolicy {
        AgentPolicy(approvalMode: mode, actionSettleDelay: 0, initialScreenshot: false)
    }

    func testTwoStepToolRunEmitsTheExpectedEventSequence() async throws {
        let surface = MockSurface()
        let client = MockLLMClient(script: [
            [.textDelta("Clicking the button."),
             .toolCall(ToolCall(id: "c1", name: "computer", arguments: ["action": "click", "x": 10, "y": 20])),
             .usage(Usage(inputTokens: 10, outputTokens: 5)),
             .finished(.toolCalls)],
            [.toolCall(ToolCall(id: "c2", name: "task_complete", arguments: ["summary": "Clicked it", "success": true])),
             .finished(.toolCalls)],
        ])
        let bus = EventBus()
        let runner = AgentRunner(name: "Tester", client: client, surface: surface, policy: quietPolicy(), bus: bus)

        let outcome = await runner.run(task: "Click the button")

        XCTAssertTrue(outcome.success)
        XCTAssertEqual(outcome.summary, "Clicked it")
        XCTAssertEqual(outcome.steps, 2)
        XCTAssertEqual(outcome.usage.inputTokens, 10)

        let labels = bus.history.map { label($0.event) }
        XCTAssertEqual(labels, [
            "started",
            "status:thinking", "textDelta", "usage", "message:assistant",
            "status:acting", "toolCall:computer", "toolResult", "screenshot",
            "status:thinking", "message:assistant",
            "status:acting", "toolCall:task_complete", "toolResult",
            "status:finished", "finished",
        ])
        XCTAssertTrue(bus.history.allSatisfy { $0.agentID == runner.id && $0.agentName == "Tester" })

        let calls = await surface.calls
        XCTAssertEqual(calls, [.click(10, 20, .left, 1), .screenshot])
        let status = await runner.status
        XCTAssertEqual(status, .finished)

        // The second request carries the tool result with the screenshot, after the assistant's tool call.
        let second = try XCTUnwrap(client.requests.last)
        XCTAssertEqual(second.first?.role, .system)
        XCTAssertEqual(second.map(\.role), [.system, .user, .assistant, .tool])
        let toolResult = try XCTUnwrap(second.last?.toolResults.first)
        XCTAssertEqual(toolResult.callID, "c1")
        XCTAssertEqual(toolResult.images.count, 1)
        XCTAssertFalse(toolResult.isError)
        // Tools were declared natively.
        XCTAssertTrue(client.requestTools.first?.contains { $0.name == "computer" } ?? false)
        XCTAssertTrue(client.requestTools.first?.contains { $0.name == "task_complete" } ?? false)
    }

    func testPlainTextAnswerEndsTheRun() async {
        let client = MockLLMClient(script: [[.textDelta("The answer is 4."), .finished(.stop)]])
        let runner = AgentRunner(client: client, policy: quietPolicy())
        let outcome = await runner.run(task: "2+2?")
        XCTAssertTrue(outcome.success)
        XCTAssertEqual(outcome.summary, "The answer is 4.")
        let transcript = await runner.transcript
        XCTAssertEqual(transcript.map(\.role), [.user, .assistant])
    }

    func testDestructiveShellCommandWaitsForApprovalAndDenyReturnsAnError() async throws {
        let surface = MockSurface()
        let client = MockLLMClient(script: [
            [.toolCall(ToolCall(id: "s1", name: "shell", arguments: ["command": "sudo rm -rf /var/lib/important"])), .finished(.toolCalls)],
            [.toolCall(ToolCall(id: "done", name: "task_complete", arguments: ["summary": "Gave up", "success": false])), .finished(.toolCalls)],
        ])
        let bus = EventBus()
        let runner = AgentRunner(client: client, surface: surface, policy: quietPolicy(.destructiveOnly), bus: bus)

        let run = Task { await runner.run(task: "Clean up") }
        await waitUntil { await runner.pendingApprovals.count == 1 }

        let status = await runner.status
        XCTAssertEqual(status, .waitingForApproval)
        let pending = await runner.pendingApprovals
        XCTAssertEqual(pending.first?.id, "s1")
        XCTAssertEqual(pending.first?.toolName, "shell")
        let executedBefore = await surface.shellCommands
        XCTAssertTrue(executedBefore.isEmpty, "the command must not run before approval")

        let resolved = await runner.approve(id: "s1", decision: .deny)
        XCTAssertTrue(resolved)
        let outcome = await run.value

        XCTAssertFalse(outcome.success)
        XCTAssertEqual(outcome.summary, "Gave up")
        let executed = await surface.shellCommands
        XCTAssertTrue(executed.isEmpty, "a denied command must never run")

        let events = bus.history.map(\.event)
        XCTAssertTrue(events.contains { if case .approvalRequested(let r) = $0 { return r.id == "s1" } else { return false } })
        XCTAssertTrue(events.contains { if case .approvalResolved("s1", .deny) = $0 { return true } else { return false } })
        let result = try XCTUnwrap(events.compactMap { e -> ToolResult? in
            if case .toolResult(let r) = e, r.callID == "s1" { return r } else { return nil }
        }.first)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("denied"), result.text)

        // The model saw the denial.
        let second = try XCTUnwrap(client.requests.last)
        XCTAssertEqual(second.last?.toolResults.first?.isError, true)
    }

    func testApprovedDestructiveCommandRunsAndAlwaysAllowsThatKind() async throws {
        let surface = MockSurface()
        let client = MockLLMClient(script: [
            [.toolCall(ToolCall(id: "a", name: "shell", arguments: ["command": "rm -rf build"])), .finished(.toolCalls)],
            [.toolCall(ToolCall(id: "b", name: "shell", arguments: ["command": "rm -rf dist"])), .finished(.toolCalls)],
            [.toolCall(ToolCall(id: "c", name: "task_complete", arguments: ["summary": "ok"])), .finished(.toolCalls)],
        ])
        let runner = AgentRunner(client: client, surface: surface, policy: quietPolicy(.destructiveOnly))
        let run = Task { await runner.run(task: "clean") }
        await waitUntil { await runner.pendingApprovals.count == 1 }
        await runner.approve(id: "a", decision: .approveAlways)
        let outcome = await run.value
        XCTAssertTrue(outcome.success)
        let executed = await surface.shellCommands
        XCTAssertEqual(executed, ["rm -rf build", "rm -rf dist"], "the second rm -r must not ask again")
        let kinds = await runner.approvalGate.alwaysAllowedKinds
        XCTAssertEqual(kinds, ["shell:rm -r"])
    }

    func testSendUserMessageIsInjectedBeforeTheNextModelCall() async throws {
        let ref = RunnerRef()
        let hook = HookTool { await ref.runner?.send(userMessage: "Also check the logs") }
        let client = MockLLMClient(script: [
            [.toolCall(ToolCall(id: "h1", name: "hook", arguments: [:])), .finished(.toolCalls)],
            [.toolCall(ToolCall(id: "done", name: "task_complete", arguments: ["summary": "Checked"])), .finished(.toolCalls)],
        ])
        let bus = EventBus()
        let runner = AgentRunner(client: client, policy: quietPolicy(), extraTools: [hook], bus: bus)
        await ref.set(runner)

        let outcome = await runner.run(task: "Do the thing")
        XCTAssertTrue(outcome.success)
        XCTAssertEqual(client.requestCount, 2)

        let second = try XCTUnwrap(client.requests.last)
        XCTAssertEqual(second.map(\.role), [.system, .user, .assistant, .tool, .user])
        XCTAssertEqual(second.last?.text, "Also check the logs")
        let first = try XCTUnwrap(client.requests.first)
        XCTAssertFalse(first.contains { $0.text == "Also check the logs" })
        XCTAssertTrue(bus.history.contains {
            if case .message(let m) = $0.event { return m.role == .user && m.text == "Also check the logs" } else { return false }
        })
    }

    func testSendAnswersAPendingAskUserQuestion() async throws {
        let client = MockLLMClient(script: [
            [.toolCall(ToolCall(id: "q", name: "ask_user", arguments: ["question": "Which folder?"])), .finished(.toolCalls)],
            [.toolCall(ToolCall(id: "done", name: "task_complete", arguments: ["summary": "Used it"])), .finished(.toolCalls)],
        ])
        let runner = AgentRunner(client: client, policy: quietPolicy())
        let run = Task { await runner.run(task: "Tidy up") }
        await waitUntil { await runner.pendingQuestion == "Which folder?" }
        await runner.send(userMessage: "~/Downloads")
        let outcome = await run.value
        XCTAssertTrue(outcome.success)
        let second = try XCTUnwrap(client.requests.last)
        XCTAssertEqual(second.last?.toolResults.first?.text, "The user answered: ~/Downloads")
        let queued = await runner.queuedMessageCount
        XCTAssertEqual(queued, 0)
    }

    func testStopWhileWaitingForApprovalEndsTheRun() async throws {
        let surface = MockSurface()
        let client = MockLLMClient(script: [
            [.toolCall(ToolCall(id: "s1", name: "shell", arguments: ["command": "mkfs.ext4 /dev/vdb"])), .finished(.toolCalls)],
            [.toolCall(ToolCall(id: "never", name: "task_complete", arguments: ["summary": "should not happen"])), .finished(.toolCalls)],
        ])
        let bus = EventBus()
        let runner = AgentRunner(client: client, surface: surface, policy: quietPolicy(), bus: bus)
        let run = Task { await runner.run(task: "Format the data disk") }
        await waitUntil { await runner.pendingApprovals.count == 1 }

        await runner.stop()
        let outcome = await run.value

        XCTAssertFalse(outcome.success)
        XCTAssertEqual(outcome.summary, "Stopped by the user.")
        let status = await runner.status
        XCTAssertEqual(status, .stopped)
        XCTAssertEqual(client.requestCount, 1, "no model call after stop")
        let executed = await surface.shellCommands
        XCTAssertTrue(executed.isEmpty)
        let running = await runner.isRunning
        XCTAssertFalse(running)
        XCTAssertEqual(bus.history.last.map { label($0.event) }, "finished")
        let pending = await runner.pendingApprovals
        XCTAssertTrue(pending.isEmpty)
    }

    func testStopFromInsideAToolEndsTheRunBeforeTheNextModelCall() async {
        let ref = RunnerRef()
        let hook = HookTool { await ref.runner?.stop() }
        let client = MockLLMClient(script: [
            [.toolCall(ToolCall(id: "h1", name: "hook", arguments: [:])), .finished(.toolCalls)],
            [.textDelta("never"), .finished(.stop)],
        ])
        let runner = AgentRunner(client: client, policy: quietPolicy(), extraTools: [hook])
        await ref.set(runner)
        let outcome = await runner.run(task: "x")
        XCTAssertFalse(outcome.success)
        XCTAssertEqual(client.requestCount, 1)
        let status = await runner.status
        XCTAssertEqual(status, .stopped)
    }

    func testPauseHoldsTheLoopUntilResume() async {
        let ref = RunnerRef()
        let hook = HookTool { await ref.runner?.pause() }
        let client = MockLLMClient(script: [
            [.toolCall(ToolCall(id: "h1", name: "hook", arguments: [:])), .finished(.toolCalls)],
            [.toolCall(ToolCall(id: "done", name: "task_complete", arguments: ["summary": "resumed"])), .finished(.toolCalls)],
        ])
        let runner = AgentRunner(client: client, policy: quietPolicy(), extraTools: [hook])
        await ref.set(runner)
        let run = Task { await runner.run(task: "x") }
        await waitUntil { await runner.status == .paused }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(client.requestCount, 1, "no model call while paused")
        await runner.resume()
        let outcome = await run.value
        XCTAssertTrue(outcome.success)
        XCTAssertEqual(outcome.summary, "resumed")
        XCTAssertEqual(client.requestCount, 2)
    }

    func testMaxStepsEndsTheRunAsFailed() async {
        let looping: [StreamEvent] = [.toolCall(ToolCall(id: "", name: "computer", arguments: ["action": "screenshot"])), .finished(.toolCalls)]
        let client = MockLLMClient(script: Array(repeating: looping, count: 5))
        var policy = quietPolicy()
        policy.maxSteps = 3
        let runner = AgentRunner(client: client, surface: MockSurface(), policy: policy)
        let outcome = await runner.run(task: "loop forever")
        XCTAssertFalse(outcome.success)
        XCTAssertEqual(outcome.steps, 3)
        XCTAssertEqual(client.requestCount, 3)
        let status = await runner.status
        XCTAssertEqual(status, .failed)
        // Empty ids were replaced with unique ones.
        let ids = await runner.transcript.flatMap(\.toolCalls).map(\.id)
        XCTAssertEqual(Set(ids).count, 3)
        XCTAssertFalse(ids.contains(""))
    }

    func testTextModeParsesFencedToolCallsAndReturnsResultsAsUserMessages() async throws {
        let surface = MockSurface()
        let client = MockLLMClient(capabilities: ModelCapabilities(vision: true, tools: false), script: [
            [.textDelta("I'll list the files.\n```json\n{\"tool\": \"shell\", \"arguments\": {\"command\": \"ls\"}}\n```"), .finished(.stop)],
            [.textDelta("```json\n{\"tool\": \"task_complete\", \"arguments\": {\"summary\": \"Listed\"}}\n```"), .finished(.stop)],
        ])
        let runner = AgentRunner(client: client, surface: surface, policy: quietPolicy())
        let outcome = await runner.run(task: "List files")
        XCTAssertTrue(outcome.success)
        XCTAssertEqual(outcome.summary, "Listed")
        let executed = await surface.shellCommands
        XCTAssertEqual(executed, ["ls"])
        XCTAssertTrue(client.requestTools.allSatisfy(\.isEmpty), "no native tools in text mode")
        let first = try XCTUnwrap(client.requests.first)
        XCTAssertTrue(first[0].text.contains("How to call tools"))
        let second = try XCTUnwrap(client.requests.last)
        XCTAssertEqual(second.map(\.role), [.system, .user, .assistant, .user])
        XCTAssertTrue(second.last?.text.contains("Result of shell") ?? false)
        XCTAssertTrue(second[2].toolCalls.isEmpty, "text-mode assistant messages carry no toolUse parts")
    }

    func testEpisodeIsRecordedAtTheEnd() async {
        let box = EpisodeBox()
        let sink = ClosureEpisodeSink { await box.add($0) }
        let client = MockLLMClient(script: [[.textDelta("Done."), .finished(.stop)]])
        let runner = AgentRunner(client: client, policy: quietPolicy(), episodeSink: sink)
        _ = await runner.run(task: "Say done")
        let episodes = await box.episodes
        XCTAssertEqual(episodes.count, 1)
        XCTAssertEqual(episodes.first?.task, "Say done")
        XCTAssertEqual(episodes.first?.outcome.summary, "Done.")
        XCTAssertEqual(episodes.first?.transcript.count, 2)
    }

    func testMemoryContextGoesIntoTheSystemPrompt() async throws {
        let store = InMemoryMemoryStore()
        try await store.save(MemoryItem(kind: .profile, title: "Name", text: "The user's name is Everald."))
        let client = MockLLMClient(script: [[.textDelta("Hi Everald."), .finished(.stop)]])
        let runner = AgentRunner(client: client, memory: store, policy: quietPolicy())
        _ = await runner.run(task: "Greet me")
        let system = try XCTUnwrap(client.requests.first?.first)
        XCTAssertEqual(system.role, .system)
        XCTAssertTrue(system.text.contains("The user's name is Everald."), system.text)
        XCTAssertTrue(client.requestTools.first?.contains { $0.name == "memory_search" } ?? false)
    }

    func testInitialScreenshotIsAttachedToTheTask() async throws {
        let surface = MockSurface()
        let client = MockLLMClient(script: [[.textDelta("I see the desktop."), .finished(.stop)]])
        var policy = quietPolicy()
        policy.initialScreenshot = true
        let runner = AgentRunner(client: client, surface: surface, policy: policy)
        _ = await runner.run(task: "Look")
        let task = try XCTUnwrap(client.requests.first?[1])
        XCTAssertEqual(task.role, .user)
        XCTAssertEqual(task.images.count, 1)
        XCTAssertEqual(task.images.first?.width, 1024)
    }

    func testEventsStreamIsFilteredToTheAgent() async {
        let bus = EventBus()
        let client = MockLLMClient(script: [[.textDelta("ok"), .finished(.stop)]])
        let runner = AgentRunner(id: "agent-1", client: client, policy: quietPolicy(), bus: bus)
        let stream = runner.events()
        AgentEmitter(agentID: "other", agentName: "Other", sink: bus).emit(.note("not mine"))
        _ = await runner.run(task: "hi")
        var labels: [String] = []
        for await e in stream {
            XCTAssertEqual(e.agentID, "agent-1")
            labels.append(label(e.event))
            if case .finished = e.event { break }
        }
        XCTAssertEqual(labels.first, "started")
        XCTAssertEqual(labels.last, "finished")
    }
}

actor EpisodeBox {
    private(set) var episodes: [AgentEpisode] = []
    func add(_ e: AgentEpisode) { episodes.append(e) }
}
