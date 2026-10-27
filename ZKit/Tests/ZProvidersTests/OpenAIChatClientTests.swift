import Foundation
import XCTest
import ZCore
@testable import ZProviders

final class OpenAIChatClientTests: XCTestCase {
    let weatherTool = ToolSpec(name: "get_weather", description: "Current weather",
                               parameters: ["type": "object", "properties": ["city": ["type": "string"]], "required": ["city"]])

    func makeClient(_ transport: MockTransport, quirks: [String] = [], vision: Bool = true,
                    streaming: Bool = true) -> OpenAIChatClient {
        OpenAIChatClient(model: ModelRef(provider: "groq", model: "qwen/qwen3.8-27b"),
                         capabilities: ModelCapabilities(vision: vision, tools: true, streaming: streaming, jsonMode: true),
                         endpoint: testEndpoint("https://api.groq.com/openai/v1"), http: testHTTP(transport),
                         quirks: QuirkSet(quirks), catalogModels: [ModelInfo(id: "qwen/qwen3.8-27b", displayName: "Qwen")])
    }

    var transcript: [ChatMessage] {
        let call = ToolCall(id: "call_1", name: "get_weather", arguments: ["city": "Paris"])
        return [
            .system("You are terse."),
            .user("Weather in Paris?", images: [testPNG]),
            ChatMessage(role: .assistant, parts: [.toolUse(call)]),
            .toolResults([ToolResult(callID: "call_1", parts: [.text("18C, sunny"), .image(testPNG)])]),
            .user("Thanks. And tomorrow?"),
        ]
    }

    func testRequestBodyShape() async throws {
        let transport = MockTransport()
        transport.enqueue(body: "data: [DONE]\n\n")
        let client = makeClient(transport, quirks: ["maxCompletionTokens"])
        let options = GenerationOptions(temperature: 0.2, maxTokens: 100, stop: ["END"], jsonMode: true,
                                        reasoningEffort: "low", extra: ["seed": 1])
        _ = try await collect(client.stream(messages: transcript, tools: [weatherTool], options: options))

        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.url.absoluteString, "https://api.groq.com/openai/v1/chat/completions")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.header("authorization"), "Bearer test-key")
        XCTAssertEqual(request.header("accept"), "text/event-stream")
        let body = try XCTUnwrap(request.jsonBody)
        XCTAssertEqual(body["model"], "qwen/qwen3.8-27b")
        XCTAssertEqual(body["stream"], true)
        XCTAssertEqual(body.at("stream_options", "include_usage"), true)
        XCTAssertEqual(body["max_completion_tokens"], 100)
        XCTAssertNil(body["max_tokens"])
        XCTAssertEqual(body["temperature"], 0.2)
        XCTAssertEqual(body["stop"], ["END"])
        XCTAssertEqual(body.at("response_format", "type"), "json_object")
        XCTAssertEqual(body["reasoning_effort"], "low")
        XCTAssertEqual(body["seed"], 1)

        XCTAssertEqual(body.at("tools", 0, "type"), "function")
        XCTAssertEqual(body.at("tools", 0, "function", "name"), "get_weather")
        XCTAssertEqual(body.at("tools", 0, "function", "parameters", "required"), ["city"])

        let messages = try XCTUnwrap(body["messages"]?.arrayValue)
        XCTAssertEqual(messages.count, 6)
        XCTAssertEqual(messages[0], ["role": "system", "content": "You are terse."])
        XCTAssertEqual(messages[1].at("content", 0), ["type": "text", "text": "Weather in Paris?"])
        XCTAssertEqual(messages[1].at("content", 1, "type"), "image_url")
        XCTAssertEqual(messages[1].at("content", 1, "image_url", "url")?.stringValue, "data:image/png;base64,\(testPNGBase64)")
        XCTAssertEqual(messages[1].at("content", 1, "image_url", "detail"), "high")
        XCTAssertEqual(messages[2]["role"], "assistant")
        XCTAssertEqual(messages[2]["content"], .null)
        XCTAssertEqual(messages[2].at("tool_calls", 0, "id"), "call_1")
        XCTAssertEqual(messages[2].at("tool_calls", 0, "function", "arguments"), "{\"city\":\"Paris\"}")
        XCTAssertEqual(messages[3], ["role": "tool", "tool_call_id": "call_1", "content": "18C, sunny"])
        XCTAssertEqual(messages[4]["role"], "user", "tool images follow the tool messages in a user message")
        XCTAssertEqual(messages[4].at("content", 1, "type"), "image_url")
        XCTAssertEqual(messages[5], ["role": "user", "content": "Thanks. And tomorrow?"])
    }

    func testQuirksReshapeTheRequest() throws {
        let client = makeClient(MockTransport(), quirks: ["noSystemRole", "noTools", "noImageDetail", "noJSONMode",
                                                          "reasoningEffortViaExtraBody"])
        let body = try client.makeRequestBody(messages: transcript, tools: [weatherTool],
                                              options: GenerationOptions(maxTokens: 50, jsonMode: true, reasoningEffort: "high"),
                                              stream: true)
        let messages = try XCTUnwrap(body["messages"]?.arrayValue)
        XCTAssertEqual(messages[0]["role"], "user", "system text folded into the first user message")
        XCTAssertEqual(messages[0].at("content", 0, "text"), "You are terse.")
        XCTAssertEqual(messages[0].at("content", 1, "text"), "Weather in Paris?")
        XCTAssertNil(messages[0].at("content", 2, "image_url", "detail"))
        XCTAssertNotNil(messages[0].at("content", 2, "image_url", "url"))
        XCTAssertNil(body["tools"])
        XCTAssertNil(body["response_format"])
        XCTAssertEqual(body["max_tokens"], 50)
        XCTAssertEqual(body.at("extra_body", "reasoning_effort"), "high")
        XCTAssertNil(body["reasoning_effort"])
    }

    func testImageLimitsAndTextOnly() throws {
        let messages: [ChatMessage] = [.user("a", images: [testPNG]), .user("b", images: [testPNG]), .user("c", images: [testPNG])]
        let limited = try makeClient(MockTransport(), quirks: ["maxImagesPerRequest:2"])
            .makeRequestBody(messages: messages, tools: [], options: .standard, stream: true)
        XCTAssertEqual(limited.at("messages", 0, "content"), "a\n[earlier image omitted]")
        XCTAssertEqual(limited.at("messages", 1, "content", 1, "type"), "image_url")
        XCTAssertEqual(limited.at("messages", 2, "content", 1, "type"), "image_url")

        let textOnly = try makeClient(MockTransport(), quirks: ["textOnly"])
            .makeRequestBody(messages: messages, tools: [], options: .standard, stream: true)
        for index in 0..<3 {
            XCTAssertEqual(textOnly.at("messages", index, "content")?.stringValue?.contains("image omitted"), true)
        }
    }

    func testChatToolsOnlyWithReasoningNone() throws {
        let client = makeClient(MockTransport(), quirks: ["chatToolsOnlyWithReasoningNone:qwen/*"])
        let withTools = try client.makeRequestBody(messages: [.user("x")], tools: [weatherTool],
                                                   options: GenerationOptions(reasoningEffort: "high"), stream: false)
        XCTAssertEqual(withTools["reasoning_effort"], "none")
        XCTAssertEqual(withTools["stream"], false)
        XCTAssertNil(withTools["stream_options"])
        let withoutTools = try client.makeRequestBody(messages: [.user("x")], tools: [],
                                                      options: GenerationOptions(reasoningEffort: "high"), stream: true)
        XCTAssertEqual(withoutTools["reasoning_effort"], "high")
    }

    func testStreamParsing() async throws {
        let chunks: [String] = [
            #"{"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}"#,
            #"{"id":"c1","choices":[{"index":0,"delta":{"reasoning_content":"User wants weather."},"finish_reason":null}]}"#,
            #"{"id":"c1","choices":[{"index":0,"delta":{"content":"Let me "},"finish_reason":null}]}"#,
            #"{"id":"c1","choices":[{"index":0,"delta":{"content":"check."},"finish_reason":null}]}"#,
            #"{"id":"c1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_abc","type":"function","function":{"name":"get_weather","arguments":""}}]},"finish_reason":null}]}"#,
            #"{"id":"c1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"city\":"}}]},"finish_reason":null}]}"#,
            #"{"id":"c1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":" \"Paris\"}"}}]},"finish_reason":null}]}"#,
            #"{"id":"c1","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
            #"{"id":"c1","choices":[],"usage":{"prompt_tokens":12,"completion_tokens":5,"total_tokens":17,"prompt_tokens_details":{"cached_tokens":4}}}"#,
        ]
        let body = ": OPENROUTER PROCESSING\n\n" + chunks.map { "data: \($0)\r\n\r\n" }.joined() + "data: [DONE]\r\n\r\n"
        let transport = MockTransport()
        transport.enqueue(body: body, chunkSize: 7)
        let result = try await collect(makeClient(transport).stream(messages: [.user("Weather?")], tools: [weatherTool],
                                                                     options: .standard))
        XCTAssertEqual(result.text, "Let me check.")
        XCTAssertEqual(result.reasoning, "User wants weather.")
        XCTAssertEqual(result.calls, [ToolCall(id: "call_abc", name: "get_weather", arguments: ["city": "Paris"])])
        XCTAssertEqual(result.starts.count, 1)
        XCTAssertEqual(result.starts.first?.name, "get_weather")
        XCTAssertEqual(result.deltas.map { $0.delta }.joined(), "{\"city\": \"Paris\"}")
        XCTAssertEqual(result.usage, Usage(inputTokens: 12, outputTokens: 5, cachedInputTokens: 4))
        XCTAssertEqual(result.finish, .toolCalls)

        let completed = try await makeClient({ () -> MockTransport in
            let t = MockTransport()
            t.enqueue(body: body, chunkSize: 3)
            return t
        }()).complete(messages: [.user("Weather?")], tools: [weatherTool])
        XCTAssertEqual(completed.message.toolCalls.count, 1)
        XCTAssertEqual(completed.finishReason, .toolCalls)
    }

    func testNonStreamingFallback() async throws {
        let transport = MockTransport()
        transport.enqueue(body: #"""
        {"id":"x","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"Done.",
         "tool_calls":[{"id":"call_9","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Oslo\"}"}}]},
         "finish_reason":"tool_calls"}],"usage":{"prompt_tokens":3,"completion_tokens":2}}
        """#)
        let client = makeClient(transport, quirks: ["noStreaming"])
        let result = try await collect(client.stream(messages: [.user("x")], tools: [weatherTool], options: .standard))
        XCTAssertEqual(transport.lastBody?["stream"], false)
        XCTAssertEqual(transport.lastRequest?.header("accept"), "application/json")
        XCTAssertEqual(result.text, "Done.")
        XCTAssertEqual(result.calls.first?.arguments, ["city": "Oslo"])
        XCTAssertEqual(result.usage, Usage(inputTokens: 3, outputTokens: 2))
        XCTAssertEqual(result.finish, .toolCalls)
    }

    func testThinkTagsInContent() async throws {
        let deltas = ["<thi", "nk>plan</th", "ink>Answer", " here"]
        let body = deltas.map { #"data: {"choices":[{"index":0,"delta":{"content":"\#($0)"}}]}"# + "\n\n" }.joined()
            + #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"# + "\n\ndata: [DONE]\n\n"
        let transport = MockTransport()
        transport.enqueue(body: body)
        let result = try await collect(makeClient(transport, quirks: ["thinkTagsInContent"])
            .stream(messages: [.user("x")], tools: [], options: .standard))
        XCTAssertEqual(result.reasoning, "plan")
        XCTAssertEqual(result.text, "Answer here")
        XCTAssertEqual(result.finish, .stop)
    }

    func testErrorsInsideTheStreamAndHTTPErrors() async {
        let transport = MockTransport()
        transport.enqueue(body: #"data: {"error":{"message":"Provider returned error","code":502}}"# + "\n\n")
        let streamError = await caughtError {
            _ = try await collect(self.makeClient(transport).stream(messages: [.user("x")], tools: [], options: .standard))
        }
        XCTAssertEqual(streamError as? ZError, .http(status: 502, body: "Provider returned error"))

        let failing = MockTransport()
        failing.enqueue(status: 404, body: #"{"error":{"message":"The model `nope` does not exist","code":"model_not_found"}}"#)
        let httpError = await caughtError {
            _ = try await collect(self.makeClient(failing).stream(messages: [.user("x")], tools: [], options: .standard))
        }
        XCTAssertEqual(httpError as? ZError, .http(status: 404, body: "model_not_found: The model `nope` does not exist"))
    }

    func testListModelsAndEmbeddings() async throws {
        let transport = MockTransport()
        transport.enqueue(body: #"{"object":"list","data":[{"id":"qwen/qwen3.8-27b"},{"id":"openai/gpt-oss-20b","context_window":131072}]}"#)
        transport.enqueue(body: #"{"object":"list","data":[{"index":1,"embedding":[0.5,0.25]},{"index":0,"embedding":[1,0]}]}"#)
        let client = makeClient(transport)
        let models = try await client.listModels()
        XCTAssertEqual(models.map(\.id), ["qwen/qwen3.8-27b", "openai/gpt-oss-20b"])
        XCTAssertEqual(models[0].displayName, "Qwen", "catalogue info wins")
        XCTAssertEqual(models[1].capabilities.contextWindow, 131_072)
        XCTAssertEqual(transport.requests[0].url.absoluteString, "https://api.groq.com/openai/v1/models")

        let vectors = try await client.embed(texts: ["a", "b"], model: "embed-1")
        XCTAssertEqual(vectors, [[1, 0], [0.5, 0.25]])
        XCTAssertEqual(transport.lastBody, ["model": "embed-1", "input": ["a", "b"]])
        XCTAssertEqual(transport.lastRequest?.url.absoluteString, "https://api.groq.com/openai/v1/embeddings")
    }

    func testListModelsFallsBackToCatalogueOn404() async throws {
        let transport = MockTransport()
        transport.enqueue(status: 404, body: "not found")
        let models = try await makeClient(transport).listModels()
        XCTAssertEqual(models.map(\.id), ["qwen/qwen3.8-27b"])
    }
}
