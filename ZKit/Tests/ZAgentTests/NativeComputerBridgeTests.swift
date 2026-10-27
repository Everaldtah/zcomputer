import Foundation
import XCTest
import ZCore
@testable import ZAgent

final class NativeComputerBridgeTests: XCTestCase {
    private func quietPolicy(_ mode: ApprovalMode = .destructiveOnly) -> AgentPolicy {
        AgentPolicy(approvalMode: mode, actionSettleDelay: 0, initialScreenshot: false)
    }

    private func makeClient(_ kind: NativeToolKind, _ script: [[StreamEvent]]) -> MockLLMClient {
        MockLLMClient(capabilities: ModelCapabilities(vision: true, tools: true, nativeComputerUse: kind), script: script)
    }

    private func complete(_ id: String = "done") -> [StreamEvent] {
        [.toolCall(ToolCall(id: id, name: "task_complete", arguments: ["summary": "ok", "success": true])), .finished(.toolCalls)]
    }

    // MARK: Anthropic

    func testAnthropicTranslation() throws {
        let bridge = AnthropicComputerBridge()
        XCTAssertEqual(try bridge.translate(ToolCall(id: "1", name: "computer.left_click", arguments: ["coordinate": [10, 20], "text": "shift"])).actions,
                       [.click(at: ScreenPoint(x: 10, y: 20), button: .left, count: 1, modifiers: ["shift"])])
        XCTAssertEqual(try bridge.translate(ToolCall(id: "2", name: "computer.left_click", arguments: [:])).actions,
                       [.click(at: nil, button: .left, count: 1, modifiers: [])])
        XCTAssertEqual(try bridge.translate(ToolCall(id: "3", name: "computer.left_click_drag",
                                                     arguments: ["start_coordinate": [1, 2], "coordinate": [3, 4]])).actions,
                       [.drag(from: ScreenPoint(x: 1, y: 2), to: ScreenPoint(x: 3, y: 4), modifiers: [])])
        XCTAssertEqual(try bridge.translate(ToolCall(id: "4", name: "computer.key", arguments: ["text": "ctrl+s", "repeat": 3])).actions,
                       [.key(combo: "ctrl+s", repeat: 3)])
        XCTAssertEqual(try bridge.translate(ToolCall(id: "5", name: "computer.scroll",
                                                     arguments: ["scroll_direction": "up", "scroll_amount": 5, "coordinate": [7, 8]])).actions,
                       [.scroll(at: ScreenPoint(x: 7, y: 8), dx: 0, dy: -5, modifiers: [])])
        XCTAssertEqual(try bridge.translate(ToolCall(id: "6", name: "computer.wait", arguments: ["duration": 120])).actions, [.wait(seconds: 30)])
        XCTAssertEqual(try bridge.translate(ToolCall(id: "7", name: "computer.hold_key", arguments: ["text": "shift", "duration": 2])).actions,
                       [.holdKey(key: "shift", seconds: 2)])
        XCTAssertEqual(try bridge.translate(ToolCall(id: "8", name: "computer.cursor_position", arguments: [:])).actions, [.cursorPosition])
        // Legacy computer_20251124: name "computer", member in input.action.
        XCTAssertEqual(try bridge.translate(ToolCall(id: "9", name: "computer", arguments: ["action": "triple_click", "coordinate": [1, 1]])).actions,
                       [.click(at: ScreenPoint(x: 1, y: 1), button: .left, count: 3, modifiers: [])])
        XCTAssertThrowsError(try bridge.translate(ToolCall(id: "x", name: "computer.teleport", arguments: [:])))
    }

    func testAnthropicDeclarations() {
        let size = PixelSize(width: 1280, height: 800)
        let toolset = AnthropicComputerBridge().toolSpec(modelDisplaySize: size, features: ComputerFeatures(zoom: false, heldKeys: true))
        XCTAssertEqual(toolset.name, "computer")
        XCTAssertEqual(toolset.native, .anthropicComputer)
        XCTAssertEqual(toolset.metadata["declaration"], ["type": "computer_toolset_20260801", "configs": ["zoom": ["enabled": false]]])
        XCTAssertNil(toolset.metadata["beta_header"])

        let legacy = AnthropicComputerBridge(version: .legacy20251124).toolSpec(modelDisplaySize: size, features: ComputerFeatures(zoom: true))
        XCTAssertEqual(legacy.metadata["declaration"], ["type": "computer_20251124", "name": "computer", "display_width_px": 1280,
                                                        "display_height_px": 800, "display_number": 1, "enable_zoom": true])
        XCTAssertEqual(legacy.metadata["beta_header"], "computer-use-2025-11-24")
    }

    func testAnthropicBatchAnswersEveryBlockAndAttachesOneTrailingScreenshot() async throws {
        let surface = MockSurface()
        let client = makeClient(.anthropicComputer, [
            [.toolCall(ToolCall(id: "a", name: "computer.left_click", arguments: ["coordinate": [10, 20]])),
             .toolCall(ToolCall(id: "b", name: "computer.type", arguments: ["text": "hi"])),
             .toolCall(ToolCall(id: "c", name: "computer.key", arguments: ["text": "ENTER"])),
             .finished(.toolCalls)],
            complete(),
        ])
        let runner = AgentRunner(client: client, surface: surface, policy: quietPolicy())
        let outcome = await runner.run(task: "type hi")
        XCTAssertTrue(outcome.success)

        let declared = try XCTUnwrap(client.requestTools.first?.first { $0.name == "computer" })
        XCTAssertEqual(declared.native, .anthropicComputer)

        let calls = await surface.calls
        XCTAssertEqual(calls, [.click(10, 20, .left, 1), .type("hi"), .keys("Return"), .screenshot])

        let results = try XCTUnwrap(client.requests.last?.last?.toolResults)
        XCTAssertEqual(results.map(\.callID), ["a", "b", "c"])
        XCTAssertEqual(results.map(\.text), ["OK", "OK", "OK"])
        XCTAssertEqual(results.map { $0.images.count }, [0, 0, 1])
    }

    func testAnthropicBatchStopsAtTheFirstFailure() async throws {
        let surface = MockSurface()
        await surface.failNext("click")
        let client = makeClient(.anthropicComputer, [
            [.toolCall(ToolCall(id: "a", name: "computer.left_click", arguments: ["coordinate": [1, 1]])),
             .toolCall(ToolCall(id: "b", name: "computer.type", arguments: ["text": "never"])),
             .finished(.toolCalls)],
            complete(),
        ])
        let runner = AgentRunner(client: client, surface: surface, policy: quietPolicy())
        _ = await runner.run(task: "x")
        let results = try XCTUnwrap(client.requests.last?.last?.toolResults)
        XCTAssertEqual(results.map(\.isError), [true, true])
        XCTAssertEqual(results[1].text, ToolBatch.notExecutedMessage)
        let calls = await surface.calls
        XCTAssertFalse(calls.contains(.type("never")))
    }

    func testAnthropicCursorPositionIsInScreenshotSpace() async throws {
        let surface = MockSurface(size: PixelSize(width: 2732, height: 1536))
        let computer = ComputerTool(resizer: FakeResizer(), settleDelay: 0)
        let tool = NativeComputerTool(bridge: AnthropicComputerBridge(), computer: computer, modelDisplaySize: PixelSize(width: 1366, height: 768))
        let ctx = testContext(surface: surface)
        _ = try await tool.invoke(ToolCall(id: "s", name: "computer.screenshot", arguments: [:]), ctx: ctx)
        _ = try await tool.invoke(ToolCall(id: "m", name: "computer.mouse_move", arguments: ["coordinate": [100, 50]]), ctx: ctx)
        let r = try await tool.invoke(ToolCall(id: "p", name: "computer.cursor_position", arguments: [:]), ctx: ctx)
        XCTAssertEqual(r.text, "X=100, Y=50")
        let calls = await surface.calls
        XCTAssertTrue(calls.contains(.mouseMove(200, 100)))
    }

    // MARK: OpenAI

    func testOpenAITranslation() throws {
        let bridge = OpenAIComputerBridge()
        let call = ToolCall(id: "call_002", name: "computer", arguments: [
            "actions": [
                ["type": "click", "button": "left", "x": 405, "y": 157, "keys": ["SHIFT"]],
                ["type": "type", "text": "penguin"],
                ["type": "keypress", "keys": ["CTRL", "A"]],
                ["type": "scroll", "x": 10, "y": 10, "scroll_x": 0, "scroll_y": -250],
                ["type": "click", "button": "back", "x": 0, "y": 0],
                ["type": "drag", "path": [["x": 1, "y": 1], ["x": 2, "y": 2], ["x": 3, "y": 3]]],
                ["type": "wait"],
            ],
            "pending_safety_checks": [],
        ])
        let t = try bridge.translate(call)
        XCTAssertEqual(t.actions, [
            .click(at: ScreenPoint(x: 405, y: 157), button: .left, count: 1, modifiers: ["SHIFT"]),
            .type(text: "penguin"),
            .key(combo: "CTRL+A", repeat: 1),
            .scroll(at: ScreenPoint(x: 10, y: 10), dx: 0, dy: -3, modifiers: []),
            .key(combo: "alt+Left", repeat: 1),
            .mouseDown(at: ScreenPoint(x: 1, y: 1), button: .left),
            .mouseMove(to: ScreenPoint(x: 2, y: 2)),
            .mouseMove(to: ScreenPoint(x: 3, y: 3)),
            .mouseUp(at: ScreenPoint(x: 3, y: 3), button: .left),
            .wait(seconds: 2),
        ])
        XCTAssertTrue(t.safetyChecks.isEmpty)
        XCTAssertEqual(bridge.toolSpec(modelDisplaySize: PixelSize(width: 1440, height: 900), features: ComputerFeatures()).metadata["declaration"],
                       ["type": "computer"])
    }

    func testOpenAIBatchRunsInOrderAndReturnsOneScreenshot() async throws {
        let surface = MockSurface()
        let client = makeClient(.openAIComputer, [
            [.toolCall(ToolCall(id: "call_1", name: "computer", arguments: [
                "actions": [["type": "click", "button": "left", "x": 5, "y": 6], ["type": "keypress", "keys": ["ENTER"]]],
                "pending_safety_checks": [],
            ])), .finished(.toolCalls)],
            complete(),
        ])
        let runner = AgentRunner(client: client, surface: surface, policy: quietPolicy())
        _ = await runner.run(task: "x")
        let calls = await surface.calls
        XCTAssertEqual(calls, [.click(5, 6, .left, 1), .keys("Return"), .screenshot])
        let result = try XCTUnwrap(client.requests.last?.last?.toolResults.first)
        XCTAssertEqual(result.callID, "call_1")
        XCTAssertEqual(result.parts.count, 1)
        XCTAssertEqual(result.images.count, 1)
    }

    func testOpenAISafetyCheckNeedsAHumanEvenInNeverModeAndDenialHaltsTheRun() async throws {
        let surface = MockSurface()
        let client = makeClient(.openAIComputer, [
            [.toolCall(ToolCall(id: "call_1", name: "computer", arguments: [
                "actions": [["type": "click", "button": "left", "x": 5, "y": 6]],
                "pending_safety_checks": [["id": "sc_1", "code": "sensitive_domain", "message": "Banking site"]],
            ])), .finished(.toolCalls)],
            complete("never"),
        ])
        let runner = AgentRunner(client: client, surface: surface, policy: quietPolicy(.never))
        let run = Task { await runner.run(task: "pay the bill") }
        await waitUntil { await runner.pendingApprovals.count == 1 }
        let pending = await runner.pendingApprovals
        XCTAssertTrue(pending.first?.summary.contains("Banking site") ?? false)
        await runner.approve(id: "call_1", decision: .deny)
        let outcome = await run.value

        XCTAssertFalse(outcome.success)
        XCTAssertTrue(outcome.summary.contains("declined"), outcome.summary)
        let status = await runner.status
        XCTAssertEqual(status, .stopped)
        XCTAssertEqual(client.requestCount, 1)
        let calls = await surface.calls
        XCTAssertTrue(calls.isEmpty, "nothing runs before the human approves")
    }

    func testOpenAISafetyCheckApprovalIsNeverRememberedForTheSession() async throws {
        let gate = ApprovalGate(mode: .never)
        let risk = ToolRisk.safetyCheck("computer:safety_check", reason: "x")
        let needs = await gate.needsApproval(risk)
        XCTAssertTrue(needs)
        let request = ApprovalRequest(id: "r", agentID: "a", toolName: "computer", summary: "s", arguments: [:])
        let decision = Task { await gate.request(request, kind: risk.kind, mandatory: true) }
        await waitUntil { await gate.pendingRequests.count == 1 }
        await gate.decide(id: "r", decision: .approveAlways)
        let d = await decision.value
        XCTAssertEqual(d, .approveAlways)
        let kinds = await gate.alwaysAllowedKinds
        XCTAssertTrue(kinds.isEmpty)
        let stillNeeds = await gate.needsApproval(risk)
        XCTAssertTrue(stillNeeds)
    }

    // MARK: Gemini

    func testGeminiTranslationAndNormalisedCoordinates() throws {
        let bridge = GeminiComputerBridge()
        let type = try bridge.translate(ToolCall(id: "1", name: "computer.type", arguments: ["text": "hello", "press_enter": true, "x": 10, "y": 20]))
        XCTAssertEqual(type.actions, [.click(at: ScreenPoint(x: 10, y: 20), button: .left, count: 1, modifiers: []),
                                      .type(text: "hello"), .key(combo: "Return", repeat: 1)])
        XCTAssertEqual(try bridge.translate(ToolCall(id: "2", name: "computer.hotkey", arguments: ["keys": ["CONTROL", "C"]])).actions,
                       [.key(combo: "CONTROL+C", repeat: 1)])
        XCTAssertEqual(try bridge.translate(ToolCall(id: "3", name: "computer.scroll", arguments: ["x": 1, "y": 2, "direction": "down"])).actions,
                       [.scroll(at: ScreenPoint(x: 1, y: 2), dx: 0, dy: 3, modifiers: [])])
        XCTAssertEqual(try bridge.translate(ToolCall(id: "4", name: "computer.drag_and_drop",
                                                     arguments: ["start_x": 1, "start_y": 2, "end_x": 3, "end_y": 4])).actions,
                       [.drag(from: ScreenPoint(x: 1, y: 2), to: ScreenPoint(x: 3, y: 4), modifiers: [])])
        XCTAssertEqual(try bridge.translate(ToolCall(id: "5", name: "computer.key_down", arguments: ["key": "shift"])).actions, [.keyDown(key: "shift")])
        XCTAssertEqual(try bridge.translate(ToolCall(id: "6", name: "computer.click", arguments: ["x": 5, "y": 5, "intent": "Open"])).intent, "Open")

        let mapping = bridge.coordinateMapping(base: .identity(PixelSize(width: 1024, height: 768)))
        XCTAssertEqual(mapping.toSurface(x: 500, y: 500), ScreenPoint(x: 512, y: 384))
        XCTAssertEqual(mapping.toSurface(x: 999, y: 999), ScreenPoint(x: 1023, y: 767))

        let spec = bridge.toolSpec(modelDisplaySize: PixelSize(width: 1440, height: 900), features: ComputerFeatures(heldKeys: false))
        XCTAssertEqual(spec.metadata["declaration"], ["computerUse": ["environment": "ENVIRONMENT_DESKTOP",
                                                                      "excludedPredefinedFunctions": ["key_down", "key_up"]]])
    }

    func testGeminiRunScalesTheGridAndAcknowledgesConfirmedSafetyDecisions() async throws {
        let surface = MockSurface()
        let client = makeClient(.geminiComputer, [
            [.toolCall(ToolCall(id: "g1", name: "computer.click", arguments: [
                "x": 500, "y": 250, "intent": "Press buy",
                "safety_decision": ["decision": "require_confirmation", "explanation": "Purchase"],
            ])), .finished(.toolCalls)],
            complete(),
        ])
        let bus = EventBus()
        let runner = AgentRunner(client: client, surface: surface, policy: quietPolicy(.never), bus: bus)
        let run = Task { await runner.run(task: "buy") }
        await waitUntil { await runner.pendingApprovals.count == 1 }
        await runner.approve(id: "g1", decision: .approve)
        let outcome = await run.value
        XCTAssertTrue(outcome.success)

        let calls = await surface.calls
        XCTAssertEqual(calls.first, .click(512, 192, .left, 1))
        let result = try XCTUnwrap(client.requests.last?.last?.toolResults.first)
        XCTAssertEqual(try JSONValue.parse(result.text), ["safety_acknowledgement": true])
        XCTAssertEqual(result.images.count, 1)
        XCTAssertTrue(bus.history.contains { if case .note(let n) = $0.event { return n.contains("Press buy") } else { return false } })
    }

    func testNativeIsNotUsedWhenThePolicyTurnsItOff() async throws {
        let client = makeClient(.anthropicComputer, [complete()])
        var policy = quietPolicy()
        policy.useNativeComputerUse = false
        let runner = AgentRunner(client: client, surface: MockSurface(), policy: policy)
        _ = await runner.run(task: "x")
        let computer = try XCTUnwrap(client.requestTools.first?.first { $0.name == "computer" })
        XCTAssertNil(computer.native)
    }
}
