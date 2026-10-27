import Foundation
import XCTest
import ZCore
@testable import ZProviders

final class OpenAIResponsesClientTests: XCTestCase {
    let computer = ToolSpec(name: "computer", description: "Operate the screen", native: .openAIComputer,
                            metadata: ["declaration": ["type": "computer"], "display_width_px": 1440, "display_height_px": 900])
    let shell = ToolSpec(name: "shell", description: "Run a command",
                         parameters: ["type": "object", "properties": ["command": ["type": "string"]], "required": ["command"]])

    func makeClient(_ transport: MockTransport, native: Bool = true, quirks: [String] = []) -> OpenAIResponsesClient {
        OpenAIResponsesClient(model: ModelRef(provider: "openai", model: "gpt-6.1-sol"),
                              capabilities: ModelCapabilities(vision: true, tools: true, nativeComputerUse: native ? .openAIComputer : nil),
                              endpoint: testEndpoint("https://api.openai.com/v1"), http: testHTTP(transport),
                              quirks: QuirkSet(quirks))
    }

    func testFirstTurnRequestShape() async throws {
        let transport = MockTransport()
        transport.enqueue(body: sse([("response.completed", #"{"type":"response.completed","response":{"id":"resp_0","status":"completed","output":[]}}"#)]))
        let client = makeClient(transport)
        _ = try await collect(client.stream(messages: [.system("Be careful."), .user("Open the browser", images: [testPNG])],
                                            tools: [computer, shell],
                                            options: GenerationOptions(maxTokens: 2000, reasoningEffort: "medium")))
        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.url.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.header("Authorization"), "Bearer test-key")
        let body = try XCTUnwrap(request.jsonBody)
        XCTAssertEqual(body["model"], "gpt-6.1-sol")
        XCTAssertEqual(body["stream"], true)
        XCTAssertEqual(body["instructions"], "Be careful.")
        XCTAssertNil(body["previous_response_id"])
        XCTAssertEqual(body["max_output_tokens"], 2000)
        XCTAssertEqual(body["reasoning"], ["effort": "medium", "summary": "auto"])
        XCTAssertEqual(body.at("tools", 0), ["type": "computer"])
        XCTAssertEqual(body.at("tools", 1, "type"), "function")
        XCTAssertEqual(body.at("tools", 1, "name"), "shell")
        XCTAssertEqual(body.at("tools", 1, "parameters", "required"), ["command"])
        XCTAssertEqual(body.at("input", 0, "role"), "user")
        XCTAssertEqual(body.at("input", 0, "content", 0), ["type": "input_text", "text": "Open the browser"])
        XCTAssertEqual(body.at("input", 0, "content", 1, "type"), "input_image")
        XCTAssertEqual(body.at("input", 0, "content", 1, "image_url")?.stringValue, testPNG.dataURL)
    }

    func testDefaultAndLegacyComputerDeclarations() throws {
        let bare = ToolSpec(name: "computer", description: "c", native: .openAIComputer,
                            metadata: ["display_width_px": 1280, "display_height_px": 800])
        let ga = try makeClient(MockTransport()).makeRequestBody(messages: [.user("x")], tools: [bare], options: .standard)
        XCTAssertEqual(ga.at("tools", 0), ["type": "computer"], "GA tool has no display size")

        let legacy = try makeClient(MockTransport(), quirks: ["computerToolType:computer_use_preview"])
            .makeRequestBody(messages: [.user("x")], tools: [bare], options: .standard)
        XCTAssertEqual(legacy.at("tools", 0), ["type": "computer_use_preview", "display_width": 1280,
                                               "display_height": 800, "environment": "linux"])

        let notNative = try makeClient(MockTransport(), native: false)
            .makeRequestBody(messages: [.user("x")], tools: [bare], options: .standard)
        XCTAssertEqual(notNative.at("tools", 0, "type"), "function", "models without native computer use get a function")
    }

    func testStreamParsesComputerCallBatch() async throws {
        let events: [(String?, String)] = [
            ("response.created", #"{"type":"response.created","response":{"id":"resp_1","status":"in_progress"}}"#),
            ("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"type":"reasoning","id":"rs_1","summary":[]}}"#),
            ("response.reasoning_summary_text.delta", #"{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","output_index":0,"summary_index":0,"delta":"Search box is top left."}"#),
            ("response.output_item.done", #"{"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"rs_1","summary":[{"type":"summary_text","text":"Search box is top left."}]}}"#),
            ("response.output_item.added", #"{"type":"response.output_item.added","output_index":1,"item":{"type":"computer_call","id":"cu_1","call_id":"call_002","status":"in_progress"}}"#),
            ("response.output_item.done", #"{"type":"response.output_item.done","output_index":1,"item":{"type":"computer_call","id":"cu_1","call_id":"call_002","actions":[{"type":"click","button":"left","x":405,"y":157},{"type":"type","text":"penguin"}],"pending_safety_checks":[],"status":"completed"}}"#),
            ("response.completed", #"{"type":"response.completed","response":{"id":"resp_1","status":"completed","output":[],"usage":{"input_tokens":1200,"input_tokens_details":{"cached_tokens":1000},"output_tokens":40}}}"#),
        ]
        let transport = MockTransport()
        transport.enqueue(body: sse(events), chunkSize: 64)
        let result = try await collect(makeClient(transport).stream(messages: [.user("Search for penguins")],
                                                                     tools: [computer, shell], options: .standard))
        XCTAssertEqual(result.reasoning, "Search box is top left.")
        XCTAssertEqual(result.calls.count, 1)
        let call = try XCTUnwrap(result.calls.first)
        XCTAssertEqual(call.id, "call_002")
        XCTAssertEqual(call.name, "computer")
        XCTAssertEqual(call.arguments["actions"]?.arrayValue?.count, 2)
        XCTAssertEqual(call.arguments.at("actions", 0), ["type": "click", "button": "left", "x": 405, "y": 157])
        XCTAssertEqual(call.arguments["pending_safety_checks"], [])
        XCTAssertEqual(call.arguments["response_id"], "resp_1")
        XCTAssertEqual(result.starts.first?.id, "call_002")
        XCTAssertEqual(result.usage, Usage(inputTokens: 1200, outputTokens: 40, cachedInputTokens: 1000))
        XCTAssertEqual(result.finish, .toolCalls)
    }

    func testStreamParsesFunctionCallsAndText() async throws {
        let events: [(String?, String)] = [
            (nil, #"{"type":"response.created","response":{"id":"resp_7"}}"#),
            (nil, #"{"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":"Listing "}"#),
            (nil, #"{"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":"files."}"#),
            (nil, #"{"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","id":"fc_1","call_id":"call_9","name":"shell","arguments":""}}"#),
            (nil, #"{"type":"response.function_call_arguments.delta","output_index":1,"item_id":"fc_1","delta":"{\"command\":"}"#),
            (nil, #"{"type":"response.function_call_arguments.delta","output_index":1,"item_id":"fc_1","delta":"\"ls -la\"}"}"#),
            (nil, #"{"type":"response.function_call_arguments.done","output_index":1,"item_id":"fc_1","arguments":"{\"command\":\"ls -la\"}"}"#),
            (nil, #"{"type":"response.output_item.done","output_index":1,"item":{"type":"function_call","id":"fc_1","call_id":"call_9","name":"shell","arguments":"{\"command\":\"ls -la\"}","status":"completed"}}"#),
            (nil, #"{"type":"response.completed","response":{"id":"resp_7","status":"completed","usage":{"input_tokens":10,"output_tokens":5}}}"#),
        ]
        let transport = MockTransport()
        transport.enqueue(body: sse(events), chunkSize: 11)
        let result = try await collect(makeClient(transport).stream(messages: [.user("ls")], tools: [shell], options: .standard))
        XCTAssertEqual(result.text, "Listing files.")
        XCTAssertEqual(result.calls, [ToolCall(id: "call_9", name: "shell", arguments: ["command": "ls -la"])])
        XCTAssertEqual(result.starts.first?.id, "call_9")
        XCTAssertEqual(result.deltas.map { $0.delta }.joined(), "{\"command\":\"ls -la\"}")
        XCTAssertEqual(result.finish, .toolCalls)
    }

    func testContinuationSendsComputerCallOutputWithAcknowledgedChecks() throws {
        let checks: JSONValue = [["id": "cu_sc_1", "code": "malicious_instructions", "message": "Suspicious page"]]
        let call = ToolCall(id: "call_002", name: "computer",
                            arguments: ["actions": [["type": "screenshot"]], "pending_safety_checks": checks, "response_id": "resp_1"])
        let messages: [ChatMessage] = [
            .system("sys"),
            .user("Search for penguins"),
            ChatMessage(role: .assistant, parts: [.toolUse(call)]),
            .toolResults([ToolResult(callID: "call_002", parts: [.image(testPNG)])]),
        ]
        let body = try makeClient(MockTransport()).makeRequestBody(messages: messages, tools: [computer], options: .standard)
        XCTAssertEqual(body["previous_response_id"], "resp_1")
        XCTAssertEqual(body["instructions"], "sys")
        let input = try XCTUnwrap(body["input"]?.arrayValue)
        XCTAssertEqual(input.count, 1, "only the new items after the anchored turn")
        XCTAssertEqual(input[0]["type"], "computer_call_output")
        XCTAssertEqual(input[0]["call_id"], "call_002")
        XCTAssertEqual(input[0]["output"], ["type": "computer_screenshot", "image_url": .string(testPNG.dataURL), "detail": "original"])
        XCTAssertEqual(input[0]["acknowledged_safety_checks"], checks)

        // A failed (e.g. denied) call acknowledges nothing and tells the model why; the earlier screenshot stands in.
        let failed: [ChatMessage] = [
            .user("go", images: [testPNG]),
            ChatMessage(role: .assistant, parts: [.toolUse(call)]),
            .toolResults([ToolResult(callID: "call_002", text: "Denied by the user", isError: true)]),
            .user("Try something else"),
        ]
        let failedBody = try makeClient(MockTransport()).makeRequestBody(messages: failed, tools: [computer], options: .standard)
        let items = try XCTUnwrap(failedBody["input"]?.arrayValue)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0]["acknowledged_safety_checks"], [])
        XCTAssertEqual(items[0].at("output", "image_url")?.stringValue, testPNG.dataURL)
        XCTAssertEqual(items[1].at("content", 0, "text")?.stringValue?.contains("Denied by the user"), true)
        XCTAssertEqual(items[2].at("content", 0, "text"), "Try something else")
    }

    func testStatelessReplayWithoutAResponseID() throws {
        let call = ToolCall(id: "call_5", name: "shell", arguments: ["command": "pwd"])
        let messages: [ChatMessage] = [
            .user("where am I?"),
            ChatMessage(role: .assistant, parts: [.text("Checking."), .toolUse(call)]),
            .toolResults([ToolResult(callID: "call_5", text: "{\"exit_code\":0,\"stdout\":\"/root\"}")]),
        ]
        let body = try makeClient(MockTransport()).makeRequestBody(messages: messages, tools: [shell], options: .standard)
        XCTAssertNil(body["previous_response_id"])
        let input = try XCTUnwrap(body["input"]?.arrayValue)
        XCTAssertEqual(input.count, 4)
        XCTAssertEqual(input[1], ["role": "assistant", "content": "Checking."])
        XCTAssertEqual(input[2], ["type": "function_call", "call_id": "call_5", "name": "shell", "arguments": "{\"command\":\"pwd\"}"])
        XCTAssertEqual(input[3], ["type": "function_call_output", "call_id": "call_5", "output": "{\"exit_code\":0,\"stdout\":\"/root\"}"])

        let chained = try makeClient(MockTransport()).makeRequestBody(messages: messages, tools: [shell], options: .standard,
                                                                     responseIDLookup: ["call_5": "resp_9"])
        XCTAssertEqual(chained["previous_response_id"], "resp_9")
        XCTAssertEqual(chained["input"]?.arrayValue?.count, 1)
    }

    func testResponseIDMemoChainsFunctionCallTurns() async throws {
        let transport = MockTransport()
        transport.enqueue(body: sse([
            (nil, #"{"type":"response.created","response":{"id":"resp_memo_1"}}"#),
            (nil, #"{"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","call_id":"call_memo_1","name":"shell","arguments":"{}"}}"#),
            (nil, #"{"type":"response.completed","response":{"id":"resp_memo_1","status":"completed"}}"#),
        ]))
        transport.enqueue(body: sse([(nil, #"{"type":"response.completed","response":{"id":"resp_memo_2","status":"completed"}}"#)]))
        let client = makeClient(transport)
        let first = try await client.complete(messages: [.user("go")], tools: [shell])
        let next = [ChatMessage.user("go"), first.message,
                    .toolResults([ToolResult(callID: "call_memo_1", text: "ok")])]
        _ = try await collect(client.stream(messages: next, tools: [shell], options: .standard))
        XCTAssertEqual(transport.lastBody?["previous_response_id"], "resp_memo_1")
        XCTAssertEqual(transport.lastBody?.at("input", 0, "type"), "function_call_output")
    }

    func testFailureAndIncompleteEvents() async throws {
        let failing = MockTransport()
        failing.enqueue(body: sse([(nil, #"{"type":"response.failed","response":{"id":"r","status":"failed","error":{"code":"server_error","message":"The model crashed"}}}"#)]))
        let error = await caughtError {
            _ = try await collect(self.makeClient(failing).stream(messages: [.user("x")], tools: [], options: .standard))
        }
        XCTAssertEqual(error as? ZError, .http(status: 500, body: "server_error: The model crashed"))

        let truncated = MockTransport()
        truncated.enqueue(body: sse([
            (nil, #"{"type":"response.output_text.delta","delta":"Partial"}"#),
            (nil, #"{"type":"response.incomplete","response":{"id":"r2","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}}"#),
        ]))
        let result = try await collect(makeClient(truncated).stream(messages: [.user("x")], tools: [], options: .standard))
        XCTAssertEqual(result.text, "Partial")
        XCTAssertEqual(result.finish, .length)
    }
}
