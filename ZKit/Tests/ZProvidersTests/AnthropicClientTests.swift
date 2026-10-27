import Foundation
import XCTest
import ZCore
@testable import ZProviders

final class AnthropicClientTests: XCTestCase {
    let weather = ToolSpec(name: "get_weather", description: "Weather",
                           parameters: ["type": "object", "properties": ["city": ["type": "string"]]])
    let computer = ToolSpec(name: "computer", description: "Screen", native: .anthropicComputer,
                            metadata: ["display_width_px": 1280, "display_height_px": 800])
    let bash = ToolSpec(name: "shell", description: "Run bash", native: .anthropicBash)

    func makeClient(_ transport: MockTransport, native: Bool = true, quirks: [String] = ["anthropicVersion:2023-06-01"])
        -> AnthropicClient {
        AnthropicClient(model: ModelRef(provider: "anthropic", model: "claude-opus-5-5"),
                        capabilities: ModelCapabilities(vision: true, tools: true,
                                                        nativeComputerUse: native ? .anthropicComputer : nil),
                        endpoint: testEndpoint("https://api.anthropic.com/v1", auth: .header("x-api-key"), key: "sk-ant-test"),
                        http: testHTTP(transport), quirks: QuirkSet(quirks))
    }

    func testRequestBodyAndHeaders() async throws {
        let transport = MockTransport()
        transport.enqueue(body: sse([("message_stop", #"{"type":"message_stop"}"#)]))
        let call = ToolCall(id: "toolu_1", name: "get_weather", arguments: ["city": "Paris"])
        let messages: [ChatMessage] = [
            .system("Be brief."),
            .user("Weather?", images: [testPNG]),
            ChatMessage(role: .assistant, parts: [.reasoning("thinking..."), .text("Checking."), .toolUse(call)]),
            .toolResults([ToolResult(callID: "toolu_1", text: "18C")]),
            .user("And tomorrow?"),
        ]
        let options = GenerationOptions(temperature: 0.7, maxTokens: 1024, stop: ["###"], reasoningEffort: "high")
        _ = try await collect(makeClient(transport).stream(messages: messages, tools: [weather], options: options))

        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.url.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.header("x-api-key"), "sk-ant-test")
        XCTAssertNil(request.header("authorization"))
        XCTAssertEqual(request.header("anthropic-version"), "2023-06-01")
        XCTAssertNil(request.header("anthropic-beta"))
        let body = try XCTUnwrap(request.jsonBody)
        XCTAssertEqual(body["model"], "claude-opus-5-5")
        XCTAssertEqual(body["max_tokens"], 1024)
        XCTAssertEqual(body["stream"], true)
        XCTAssertEqual(body["system"], "Be brief.")
        XCTAssertEqual(body["stop_sequences"], ["###"])
        XCTAssertNil(body["temperature"], "current Claude models reject sampling parameters")
        XCTAssertEqual(body["thinking"], ["type": "adaptive", "display": "summarized"])
        XCTAssertEqual(body["output_config"], ["effort": "high"])
        XCTAssertEqual(body.at("tools", 0), ["name": "get_weather", "description": "Weather",
                                            "input_schema": ["type": "object", "properties": ["city": ["type": "string"]]]])

        let turns = try XCTUnwrap(body["messages"]?.arrayValue)
        XCTAssertEqual(turns.count, 3, "tool results and the next user message merge into one user turn")
        XCTAssertEqual(turns[0]["role"], "user")
        XCTAssertEqual(turns[0].at("content", 0), ["type": "text", "text": "Weather?"])
        XCTAssertEqual(turns[0].at("content", 1), ["type": "image", "source": ["type": "base64", "media_type": "image/png",
                                                                                "data": .string(testPNGBase64)]])
        XCTAssertEqual(turns[1]["role"], "assistant")
        XCTAssertEqual(turns[1]["content"]?.arrayValue?.count, 2, "reasoning is not replayed")
        XCTAssertEqual(turns[1].at("content", 1), ["type": "tool_use", "id": "toolu_1", "name": "get_weather",
                                                   "input": ["city": "Paris"]])
        XCTAssertEqual(turns[2]["role"], "user")
        XCTAssertEqual(turns[2].at("content", 0), ["type": "tool_result", "tool_use_id": "toolu_1",
                                                   "content": [["type": "text", "text": "18C"]]])
        XCTAssertEqual(turns[2].at("content", 1), ["type": "text", "text": "And tomorrow?"])
    }

    func testComputerToolsetAndBashEncoding() throws {
        let click = ToolCall(id: "toolu_c", name: "computer.left_click", arguments: ["coordinate": [512, 384]])
        let shot = ToolCall(id: "toolu_s", name: "computer.screenshot", arguments: [:])
        let run = ToolCall(id: "toolu_b", name: "shell", arguments: ["command": "ls"])
        let messages: [ChatMessage] = [
            .user("Open the terminal"),
            ChatMessage(role: .assistant, parts: [.toolUse(click), .toolUse(shot), .toolUse(run)]),
            .toolResults([
                ToolResult(callID: "toolu_c", text: "OK"),
                ToolResult(callID: "toolu_s", parts: [.image(testPNG)]),
                ToolResult(callID: "toolu_b", text: "file.txt"),
            ]),
        ]
        let plainComputer = ToolSpec(name: "computer", description: "neutral computer function")
        let (body, headers) = try makeClient(MockTransport())
            .makeRequest(messages: messages, tools: [computer, bash, plainComputer, weather], options: .standard)
        XCTAssertNil(headers["anthropic-beta"], "the GA toolset needs no beta header")
        XCTAssertEqual(body["max_tokens"], 64000)
        let tools = try XCTUnwrap(body["tools"]?.arrayValue)
        XCTAssertEqual(tools.count, 3, "a second tool named computer is dropped next to the toolset")
        XCTAssertEqual(tools[0], ["type": "computer_toolset_20260801",
                                  "configs": ["hold_key": ["enabled": false], "zoom": ["enabled": false]]])
        XCTAssertEqual(tools[1], ["type": "bash_20250124", "name": "bash"])
        XCTAssertEqual(tools[2]["name"], "get_weather")

        let assistant = try XCTUnwrap(body.at("messages", 1, "content")?.arrayValue)
        XCTAssertEqual(assistant[0], ["type": "tool_use", "id": "toolu_c", "name": "left_click", "toolset_name": "computer",
                                      "input": ["coordinate": [512, 384]]])
        XCTAssertEqual(assistant[1]["name"], "screenshot")
        XCTAssertEqual(assistant[1]["toolset_name"], "computer")
        XCTAssertEqual(assistant[2], ["type": "tool_use", "id": "toolu_b", "name": "bash", "input": ["command": "ls"]])

        let results = try XCTUnwrap(body.at("messages", 2, "content")?.arrayValue)
        XCTAssertEqual(results[0], ["type": "tool_result", "tool_use_id": "toolu_c", "toolset_name": "computer",
                                    "content": [["type": "text", "text": "OK"]]])
        XCTAssertEqual(results[1]["toolset_name"], "computer")
        XCTAssertEqual(results[1].at("content", 0, "type"), "image")
        XCTAssertNil(results[2]["toolset_name"])
    }

    func testDeclarationFromMetadataAndLegacyVersions() throws {
        let declared = ToolSpec(name: "computer", description: "Screen", native: .anthropicComputer,
                                metadata: ["declaration": ["type": "computer_20251124", "name": "computer",
                                                           "display_width_px": 1280, "display_height_px": 800,
                                                           "display_number": 1],
                                           "beta_header": "computer-use-2025-11-24"])
        let legacyCall = ToolCall(id: "toolu_l", name: "computer", arguments: ["action": "left_click", "coordinate": [1, 2]])
        let messages: [ChatMessage] = [
            .user("x"),
            ChatMessage(role: .assistant, parts: [.toolUse(legacyCall)]),
            .toolResults([ToolResult(callID: "toolu_l", text: "OK")]),
        ]
        let client = makeClient(MockTransport())
        let (body, headers) = try client.makeRequest(messages: messages, tools: [declared], options: .standard)
        XCTAssertEqual(headers["anthropic-beta"], "computer-use-2025-11-24")
        XCTAssertEqual(body.at("tools", 0), declared.metadata["declaration"])
        XCTAssertEqual(body.at("messages", 1, "content", 0, "name"), "computer")
        XCTAssertEqual(body.at("messages", 1, "content", 0, "input", "action"), "left_click")
        XCTAssertNil(body.at("messages", 2, "content", 0, "toolset_name"), "legacy results carry no toolset_name")

        // Version chosen by quirk; display size from metadata; beta header derived from the type.
        let byQuirk = makeClient(MockTransport(), quirks: ["computerToolset:computer_20250124"])
        let (legacyBody, legacyHeaders) = try byQuirk.makeRequest(messages: [.user("x")], tools: [computer], options: .standard)
        XCTAssertEqual(legacyHeaders["anthropic-beta"], "computer-use-2025-01-24")
        XCTAssertEqual(legacyBody.at("tools", 0), ["type": "computer_20250124", "name": "computer", "display_width_px": 1280,
                                                   "display_height_px": 800, "display_number": 1])

        // A legacy version without a display size is an honest error.
        let noSize = ToolSpec(name: "computer", description: "Screen", native: .anthropicComputer)
        XCTAssertThrowsError(try byQuirk.makeRequest(messages: [.user("x")], tools: [noSize], options: .standard))
    }

    func testNativeKindsFallBackToFunctionsWithoutCapability() throws {
        let (body, _) = try makeClient(MockTransport(), native: false)
            .makeRequest(messages: [.user("x")], tools: [computer, bash], options: .standard)
        XCTAssertEqual(body.at("tools", 0, "name"), "computer")
        XCTAssertNotNil(body.at("tools", 0, "input_schema"))
        XCTAssertEqual(body.at("tools", 1, "name"), "shell")
    }

    func testStreamParsing() async throws {
        let events: [(String?, String)] = [
            ("message_start", #"{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-5-5","content":[],"stop_reason":null,"usage":{"input_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":1000,"output_tokens":1}}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#),
            ("ping", #"{"type": "ping"}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"The terminal icon is in the dock."}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"EqQBCgIYAhIM"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Opening "}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"it."}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
            ("content_block_start", #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_01","name":"left_click","input":{},"toolset_name":"computer"}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"coordinate\": [512, 384]}"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":2}"#),
            ("content_block_start", #"{"type":"content_block_start","index":3,"content_block":{"type":"tool_use","id":"toolu_02","name":"screenshot","input":{},"toolset_name":"computer"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":3}"#),
            ("content_block_start", #"{"type":"content_block_start","index":4,"content_block":{"type":"tool_use","id":"toolu_03","name":"bash","input":{}}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":4,"delta":{"type":"input_json_delta","partial_json":"{\"command\": \"ec"}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":4,"delta":{"type":"input_json_delta","partial_json":"ho hi\"}"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":4}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":42}}"#),
            ("message_stop", #"{"type":"message_stop"}"#),
        ]
        let transport = MockTransport()
        transport.enqueue(body: sse(events), chunkSize: 13)
        let result = try await collect(makeClient(transport).stream(messages: [.user("Open the terminal")],
                                                                     tools: [computer, bash], options: .standard))
        XCTAssertEqual(result.reasoning, "The terminal icon is in the dock.")
        XCTAssertEqual(result.text, "Opening it.")
        XCTAssertEqual(result.calls, [
            ToolCall(id: "toolu_01", name: "computer.left_click", arguments: ["coordinate": [512, 384]]),
            ToolCall(id: "toolu_02", name: "computer.screenshot", arguments: [:]),
            ToolCall(id: "toolu_03", name: "shell", arguments: ["command": "echo hi"]),
        ])
        XCTAssertEqual(result.starts.map { $0.name }, ["computer.left_click", "computer.screenshot", "shell"])
        XCTAssertEqual(result.deltas.filter { $0.id == "toolu_03" }.map { $0.delta }.joined(), "{\"command\": \"echo hi\"}")
        XCTAssertEqual(result.usage, Usage(inputTokens: 1050, outputTokens: 42, cachedInputTokens: 1000))
        XCTAssertEqual(result.finish, .toolCalls)
    }

    func testStopReasonsAndErrors() async throws {
        let transport = MockTransport()
        transport.enqueue(body: sse([
            ("message_start", #"{"type":"message_start","message":{"usage":{"input_tokens":5,"output_tokens":0}}}"#),
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":"Hel"}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":2}}"#),
        ]))
        let result = try await collect(makeClient(transport).stream(messages: [.user("x")], tools: [], options: .standard))
        XCTAssertEqual(result.text, "Hello")
        XCTAssertEqual(result.finish, .length)

        let refused = MockTransport()
        refused.enqueue(body: sse([("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"refusal"}}"#)]))
        let refusal = try await collect(makeClient(refused).stream(messages: [.user("x")], tools: [], options: .standard))
        XCTAssertEqual(refusal.finish, .contentFilter)

        let overloaded = MockTransport()
        overloaded.enqueue(body: sse([("error", #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)]))
        let error = await caughtError {
            _ = try await collect(self.makeClient(overloaded).stream(messages: [.user("x")], tools: [], options: .standard))
        }
        XCTAssertEqual(error as? ZError, .http(status: 529, body: "overloaded_error: Overloaded"))
    }

    func testListModelsPaginates() async throws {
        let transport = MockTransport()
        transport.enqueue(body: #"{"data":[{"id":"claude-opus-5-5","display_name":"Claude Opus 5.5","max_input_tokens":1000000,"max_tokens":128000}],"has_more":true,"last_id":"claude-opus-5-5"}"#)
        transport.enqueue(body: #"{"data":[{"id":"claude-haiku-5-5","display_name":"Claude Haiku 5.5"}],"has_more":false,"last_id":"claude-haiku-5-5"}"#)
        let models = try await makeClient(transport).listModels()
        XCTAssertEqual(models.map(\.id), ["claude-opus-5-5", "claude-haiku-5-5"])
        XCTAssertEqual(models[0].displayName, "Claude Opus 5.5")
        XCTAssertEqual(models[0].capabilities.contextWindow, 1_000_000)
        XCTAssertEqual(models[0].capabilities.maxOutputTokens, 128_000)
        XCTAssertTrue(transport.requests[1].url.absoluteString.contains("after_id=claude-opus-5-5"))
        XCTAssertEqual(transport.requests[0].header("anthropic-version"), "2023-06-01")
    }
}
