import Foundation
import XCTest
import ZCore
@testable import ZProviders

final class OllamaClientTests: XCTestCase {
    let weather = ToolSpec(name: "get_weather", description: "Weather",
                           parameters: ["type": "object", "properties": ["city": ["type": "string"]], "required": ["city"]])

    func makeClient(_ transport: MockTransport, key: String? = nil, streaming: Bool = true) -> OllamaClient {
        OllamaClient(model: ModelRef(provider: "ollama", model: "qwen3-vl:4b"),
                     capabilities: ModelCapabilities(vision: true, tools: true, streaming: streaming, jsonMode: true),
                     endpoint: testEndpoint("http://localhost:11434", auth: .noAuth, key: key),
                     http: testHTTP(transport))
    }

    func testRequestBodyShape() async throws {
        let transport = MockTransport()
        transport.enqueue(body: #"{"model":"qwen3-vl:4b","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop"}"# + "\n")
        let call = ToolCall(id: "call_1", name: "get_weather", arguments: ["city": "Toronto"])
        let messages: [ChatMessage] = [
            .system("Be brief."),
            .user("What is on screen?", images: [testPNG]),
            ChatMessage(role: .assistant, parts: [.text("Checking."), .toolUse(call)]),
            .toolResults([ToolResult(callID: "call_1", parts: [.text("11 degrees"), .image(testPNG)])]),
            .user("Thanks"),
        ]
        let options = GenerationOptions(temperature: 0.1, maxTokens: 256, stop: ["</s>"], jsonMode: true, reasoningEffort: "high")
        _ = try await collect(makeClient(transport).stream(messages: messages, tools: [weather], options: options))

        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.url.absoluteString, "http://localhost:11434/api/chat")
        XCTAssertNil(request.header("authorization"), "local Ollama needs no key")
        let body = try XCTUnwrap(request.jsonBody)
        XCTAssertEqual(body["model"], "qwen3-vl:4b")
        XCTAssertEqual(body["stream"], true)
        XCTAssertEqual(body["options"], ["temperature": 0.1, "num_predict": 256, "stop": ["</s>"]])
        XCTAssertEqual(body["format"], "json")
        XCTAssertEqual(body["think"], true)
        XCTAssertEqual(body.at("tools", 0, "function", "name"), "get_weather")

        let sent = try XCTUnwrap(body["messages"]?.arrayValue)
        XCTAssertEqual(sent.count, 6)
        XCTAssertEqual(sent[0], ["role": "system", "content": "Be brief."])
        XCTAssertEqual(sent[1], ["role": "user", "content": "What is on screen?", "images": [.string(testPNGBase64)]])
        XCTAssertEqual(sent[2], ["role": "assistant", "content": "Checking.",
                                 "tool_calls": [["function": ["name": "get_weather", "arguments": ["city": "Toronto"]]]]])
        XCTAssertEqual(sent[3], ["role": "tool", "content": "11 degrees", "tool_name": "get_weather"])
        XCTAssertEqual(sent[4]["role"], "user")
        XCTAssertEqual(sent[4]["images"], [.string(testPNGBase64)])
        XCTAssertEqual(sent[5], ["role": "user", "content": "Thanks"])
    }

    func testBearerKeyForOllamaCloud() async throws {
        let transport = MockTransport()
        transport.enqueue(body: #"{"message":{"role":"assistant","content":"hi"},"done":true}"#)
        let cloud = OllamaClient(model: ModelRef(provider: "ollama-cloud", model: "gemma4:31b"),
                                 capabilities: ModelCapabilities(vision: true, tools: true),
                                 endpoint: testEndpoint("https://ollama.com", auth: .bearer, key: "olm-key"),
                                 http: testHTTP(transport))
        let result = try await collect(cloud.stream(messages: [.user("hi")], tools: [], options: .standard))
        XCTAssertEqual(result.text, "hi")
        XCTAssertEqual(transport.lastRequest?.header("authorization"), "Bearer olm-key")
        XCTAssertEqual(transport.lastRequest?.url.absoluteString, "https://ollama.com/api/chat")
    }

    func testNDJSONStreamParsing() async throws {
        let lines = [
            #"{"model":"qwen3-vl:4b","created_at":"2026-10-27T10:00:00Z","message":{"role":"assistant","content":"","thinking":"Need the weather tool."},"done":false}"#,
            #"{"model":"qwen3-vl:4b","created_at":"2026-10-27T10:00:01Z","message":{"role":"assistant","content":"Let me "},"done":false}"#,
            #"{"model":"qwen3-vl:4b","created_at":"2026-10-27T10:00:01Z","message":{"role":"assistant","content":"check."},"done":false}"#,
            #"{"model":"qwen3-vl:4b","created_at":"2026-10-27T10:00:02Z","message":{"role":"assistant","content":"","tool_calls":[{"function":{"index":0,"name":"get_weather","arguments":{"city":"Toronto"}}}]},"done":false}"#,
            #"{"model":"qwen3-vl:4b","created_at":"2026-10-27T10:00:02Z","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop","total_duration":4883583458,"prompt_eval_count":26,"eval_count":19}"#,
        ]
        let transport = MockTransport()
        transport.enqueue(body: lines.joined(separator: "\n") + "\n", chunkSize: 23)
        let result = try await collect(makeClient(transport).stream(messages: [.user("Weather in Toronto?")],
                                                                     tools: [weather], options: .standard))
        XCTAssertEqual(result.reasoning, "Need the weather tool.")
        XCTAssertEqual(result.text, "Let me check.")
        XCTAssertEqual(result.calls.count, 1)
        XCTAssertEqual(result.calls.first?.name, "get_weather")
        XCTAssertEqual(result.calls.first?.arguments, ["city": "Toronto"])
        XCTAssertTrue(result.calls.first?.id.hasPrefix("call_") ?? false)
        XCTAssertEqual(result.usage, Usage(inputTokens: 26, outputTokens: 19))
        XCTAssertEqual(result.finish, .toolCalls)
    }

    func testNonStreamingAndStringArguments() async throws {
        let transport = MockTransport()
        transport.enqueue(body: #"{"message":{"role":"assistant","content":"","tool_calls":[{"id":"call_x","function":{"name":"get_weather","arguments":"{\"city\":\"Rome\"}"}}]},"done":true,"done_reason":"stop"}"#)
        let result = try await collect(makeClient(transport, streaming: false).stream(messages: [.user("x")], tools: [weather],
                                                                                       options: .standard))
        XCTAssertEqual(transport.lastBody?["stream"], false)
        XCTAssertEqual(result.calls, [ToolCall(id: "call_x", name: "get_weather", arguments: ["city": "Rome"])])
    }

    func testErrorLineAndHTTPError() async {
        let transport = MockTransport()
        transport.enqueue(body: #"{"error":"model 'qwen3-vl:4b' not found, try pulling it first"}"# + "\n")
        let error = await caughtError {
            _ = try await collect(self.makeClient(transport).stream(messages: [.user("x")], tools: [], options: .standard))
        }
        XCTAssertEqual(error as? ZError, .http(status: 500, body: "model 'qwen3-vl:4b' not found, try pulling it first"))

        let missing = MockTransport()
        missing.enqueue(status: 404, body: #"{"error":"model \"nope\" not found"}"#)
        let httpError = await caughtError {
            _ = try await collect(self.makeClient(missing).stream(messages: [.user("x")], tools: [], options: .standard))
        }
        XCTAssertEqual(httpError as? ZError, .http(status: 404, body: "model \"nope\" not found"))
    }

    func testListModelsAndEmbed() async throws {
        let transport = MockTransport()
        transport.enqueue(body: #"{"models":[{"name":"qwen3-vl:4b","model":"qwen3-vl:4b","size":3300000000,"details":{"family":"qwen3vl","parameter_size":"4.4B","quantization_level":"Q4_K_M"}}]}"#)
        transport.enqueue(body: #"{"model":"embeddinggemma","embeddings":[[0.25,0.5],[0.75,1]]}"#)
        let client = makeClient(transport)
        let models = try await client.listModels()
        XCTAssertEqual(models.map(\.id), ["qwen3-vl:4b"])
        XCTAssertEqual(models.first?.notes, "4.4B Q4_K_M")
        XCTAssertEqual(transport.requests[0].url.absoluteString, "http://localhost:11434/api/tags")
        XCTAssertEqual(transport.requests[0].method, "GET")

        let vectors = try await client.embed(texts: ["a", "b"], model: "embeddinggemma")
        XCTAssertEqual(vectors, [[0.25, 0.5], [0.75, 1]])
        XCTAssertEqual(transport.lastRequest?.url.absoluteString, "http://localhost:11434/api/embed")
        XCTAssertEqual(transport.lastBody, ["model": "embeddinggemma", "input": ["a", "b"]])
    }
}
