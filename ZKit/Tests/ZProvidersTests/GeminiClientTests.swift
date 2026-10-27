import Foundation
import XCTest
import ZCore
@testable import ZProviders

final class GeminiClientTests: XCTestCase {
    let computer = ToolSpec(name: "computer", description: "Screen", native: .geminiComputer)
    let shell = ToolSpec(name: "shell", description: "Run a command",
                         parameters: ["type": "object", "additionalProperties": false, "$schema": "http://json-schema.org/draft-07/schema#",
                                      "properties": ["command": ["type": "string"],
                                                     "timeout_seconds": ["type": ["integer", "null"], "minimum": 1]],
                                      "required": ["command"]])
    let noArgs = ToolSpec(name: "task_done", description: "Finish")

    func makeClient(_ transport: MockTransport, native: Bool = true, streaming: Bool = true,
                    quirks: [String] = ["thinkingMinimalUnsupported:gemini-3.8-flash"]) -> GeminiClient {
        GeminiClient(model: ModelRef(provider: "google", model: "gemini-3.8-flash"),
                     capabilities: ModelCapabilities(vision: true, tools: true, streaming: streaming, jsonMode: true,
                                                     nativeComputerUse: native ? .geminiComputer : nil),
                     endpoint: testEndpoint("https://generativelanguage.googleapis.com/v1beta", auth: .header("x-goog-api-key"),
                                            key: "AIza-test"),
                     http: testHTTP(transport), quirks: QuirkSet(quirks))
    }

    func testRequestBodyShape() async throws {
        let transport = MockTransport()
        transport.enqueue(body: sse([(nil, #"{"candidates":[{"content":{"role":"model","parts":[{"text":"ok"}]},"finishReason":"STOP"}]}"#)]))
        let click = ToolCall(id: "zc-gemini-1", name: "computer.click",
                             arguments: ["x": 450, "y": 120, "intent": "Open the menu",
                                         "safety_decision": ["decision": "require_confirmation", "explanation": "Clicks Buy"]])
        let run = ToolCall(id: "fc_7", name: "shell", arguments: ["command": "ls"])
        let messages: [ChatMessage] = [
            .system("You operate a Linux desktop."),
            .user("Buy the book", images: [testPNG]),
            ChatMessage(role: .assistant, parts: [.reasoning("thought"), .text("On it."), .toolUse(click), .toolUse(run)]),
            .toolResults([
                ToolResult(callID: "zc-gemini-1", parts: [.text("{}"), .image(testPNG)]),
                ToolResult(callID: "fc_7", text: "file.txt"),
            ]),
            .user("Continue"),
        ]
        let options = GenerationOptions(temperature: 0.4, maxTokens: 512, stop: ["STOP!"], jsonMode: true, reasoningEffort: "minimal")
        _ = try await collect(makeClient(transport).stream(messages: messages, tools: [shell, noArgs, computer], options: options))

        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.url.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:streamGenerateContent?alt=sse")
        XCTAssertEqual(request.header("x-goog-api-key"), "AIza-test")
        let body = try XCTUnwrap(request.jsonBody)
        XCTAssertEqual(body["systemInstruction"], ["parts": [["text": "You operate a Linux desktop."]]])
        XCTAssertEqual(body.at("generationConfig", "temperature"), 0.4)
        XCTAssertEqual(body.at("generationConfig", "maxOutputTokens"), 512)
        XCTAssertEqual(body.at("generationConfig", "stopSequences"), ["STOP!"])
        XCTAssertEqual(body.at("generationConfig", "responseMimeType"), "application/json")
        XCTAssertEqual(body.at("generationConfig", "thinkingConfig"), ["thinkingLevel": "low", "includeThoughts": true],
                       "minimal is unsupported on gemini-3.8-flash (quirk)")

        let declarations = try XCTUnwrap(body.at("tools", 0, "functionDeclarations")?.arrayValue)
        XCTAssertEqual(declarations.count, 2)
        XCTAssertEqual(declarations[0].at("parameters"), ["type": "object", "required": ["command"],
                                                          "properties": ["command": ["type": "string"],
                                                                         "timeout_seconds": ["type": "integer", "nullable": true, "minimum": 1]]])
        XCTAssertEqual(declarations[1], ["name": "task_done", "description": "Finish"], "no parameters for an empty object")
        XCTAssertEqual(body.at("tools", 1), ["computerUse": ["environment": "ENVIRONMENT_DESKTOP",
                                                             "excludedPredefinedFunctions": ["key_down", "key_up"]]])

        let contents = try XCTUnwrap(body["contents"]?.arrayValue)
        XCTAssertEqual(contents.count, 3)
        XCTAssertEqual(contents[0]["role"], "user")
        XCTAssertEqual(contents[0].at("parts", 1), ["inlineData": ["mimeType": "image/png", "data": .string(testPNGBase64)]])
        XCTAssertEqual(contents[1]["role"], "model")
        XCTAssertEqual(contents[1]["parts"]?.arrayValue?.count, 3, "thought summaries are not replayed")
        XCTAssertEqual(contents[1].at("parts", 1, "functionCall"), ["name": "click", "args": click.arguments],
                       "synthesised ids are not echoed; the computer. prefix is stripped")
        XCTAssertEqual(contents[1].at("parts", 1, "thoughtSignature"), "skip_thought_signature_validator")
        XCTAssertEqual(contents[1].at("parts", 2, "functionCall"), ["name": "shell", "args": ["command": "ls"], "id": "fc_7"])
        XCTAssertNil(contents[1].at("parts", 2, "thoughtSignature"))
        XCTAssertEqual(contents[2]["role"], "user")
        XCTAssertEqual(contents[2].at("parts", 0, "functionResponse"),
                       ["name": "click", "response": ["safety_acknowledgement": true],
                        "parts": [["inlineData": ["mimeType": "image/png", "data": .string(testPNGBase64)]]]])
        XCTAssertEqual(contents[2].at("parts", 1, "functionResponse"),
                       ["name": "shell", "id": "fc_7", "response": ["output": "file.txt"]])
        XCTAssertEqual(contents[2].at("parts", 2), ["text": "Continue"])
    }

    func testStreamParsingAndSignatureReplay() async throws {
        let chunks = [
            #"{"candidates":[{"content":{"role":"model","parts":[{"text":"The menu is top left.","thought":true}]}}],"usageMetadata":{"promptTokenCount":900}}"#,
            #"{"candidates":[{"content":{"role":"model","parts":[{"text":"Clicking "}]}}]}"#,
            #"{"candidates":[{"content":{"role":"model","parts":[{"text":"it."},{"functionCall":{"name":"click","args":{"x":42,"y":17,"intent":"Open menu"}},"thoughtSignature":"CiQBVKhc7sigA"},{"functionCall":{"id":"fc_9","name":"shell","args":{"command":"pwd"}}}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":900,"candidatesTokenCount":30,"thoughtsTokenCount":12,"cachedContentTokenCount":800}}"#,
        ]
        let transport = MockTransport()
        transport.enqueue(body: chunks.map { "data: \($0)\r\n\r\n" }.joined(), chunkSize: 17)
        let client = makeClient(transport)
        let result = try await collect(client.stream(messages: [.user("Open the menu")], tools: [shell, computer],
                                                     options: .standard))
        XCTAssertEqual(result.reasoning, "The menu is top left.")
        XCTAssertEqual(result.text, "Clicking it.")
        XCTAssertEqual(result.calls.count, 2)
        let click = result.calls[0]
        XCTAssertEqual(click.name, "computer.click")
        XCTAssertTrue(click.id.hasPrefix("zc-gemini-"))
        XCTAssertEqual(click.arguments, ["x": 42, "y": 17, "intent": "Open menu"])
        XCTAssertEqual(result.calls[1], ToolCall(id: "fc_9", name: "shell", arguments: ["command": "pwd"]))
        XCTAssertEqual(result.usage, Usage(inputTokens: 900, outputTokens: 42, cachedInputTokens: 800))
        XCTAssertEqual(result.finish, .toolCalls)

        // The next turn replays the remembered thought signature on the matching functionCall part.
        transport.enqueue(body: sse([(nil, #"{"candidates":[{"content":{"parts":[{"text":"Done"}]},"finishReason":"STOP"}]}"#)]))
        let next: [ChatMessage] = [
            .user("Open the menu"),
            ChatMessage(role: .assistant, parts: [.text("Clicking it."), .toolUse(click), .toolUse(result.calls[1])]),
            .toolResults([ToolResult(callID: click.id, parts: [.text("{}"), .image(testPNG)]),
                          ToolResult(callID: "fc_9", text: "/root")]),
        ]
        let second = try await collect(client.stream(messages: next, tools: [shell, computer], options: .standard))
        XCTAssertEqual(second.text, "Done")
        XCTAssertEqual(second.finish, .stop)
        let parts = try XCTUnwrap(transport.lastBody?.at("contents", 1, "parts")?.arrayValue)
        XCTAssertEqual(parts[1]["thoughtSignature"], "CiQBVKhc7sigA")
        XCTAssertEqual(parts[1].at("functionCall", "name"), "click")
        XCTAssertNil(parts[1].at("functionCall", "id"))
    }

    func testNativeDeclarationFromMetadataAndNonNativeFallback() throws {
        let declared = ToolSpec(name: "computer", description: "Screen", native: .geminiComputer,
                                metadata: ["declaration": ["computerUse": ["environment": "ENVIRONMENT_DESKTOP",
                                                                           "excludedPredefinedFunctions": []]]])
        let body = try makeClient(MockTransport()).makeRequestBody(messages: [.user("x")], tools: [declared], options: .standard)
        XCTAssertEqual(body.at("tools", 0), declared.metadata["declaration"])
        XCTAssertNil(body["generationConfig"])

        let plain = try makeClient(MockTransport(), native: false)
            .makeRequestBody(messages: [.user("x")], tools: [declared], options: .standard)
        XCTAssertEqual(plain.at("tools", 0, "functionDeclarations", 0, "name"), "computer")
    }

    func testNonStreamingGenerateContent() async throws {
        let transport = MockTransport()
        transport.enqueue(body: #"{"candidates":[{"content":{"role":"model","parts":[{"text":"Hi"}]},"finishReason":"MAX_TOKENS"}],"usageMetadata":{"promptTokenCount":3,"candidatesTokenCount":1}}"#)
        let result = try await collect(makeClient(transport, streaming: false).stream(messages: [.user("x")], tools: [],
                                                                                       options: .standard))
        XCTAssertEqual(transport.lastRequest?.url.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent")
        XCTAssertEqual(result.text, "Hi")
        XCTAssertEqual(result.finish, .length)
        XCTAssertEqual(result.usage, Usage(inputTokens: 3, outputTokens: 1))
    }

    func testBlockedPromptAndErrors() async throws {
        let blocked = MockTransport()
        blocked.enqueue(body: sse([(nil, #"{"promptFeedback":{"blockReason":"SAFETY"},"usageMetadata":{"promptTokenCount":4}}"#)]))
        let result = try await collect(makeClient(blocked).stream(messages: [.user("x")], tools: [], options: .standard))
        XCTAssertEqual(result.finish, .contentFilter)

        let failing = MockTransport()
        failing.enqueue(status: 400, body: #"{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT"}}"#)
        let error = await caughtError {
            _ = try await collect(self.makeClient(failing).stream(messages: [.user("x")], tools: [], options: .standard))
        }
        XCTAssertEqual(error as? ZError, .http(status: 400, body: "INVALID_ARGUMENT: API key not valid. Please pass a valid API key."))
    }

    func testEmbeddingsAndListModels() async throws {
        let transport = MockTransport()
        transport.enqueue(body: #"{"embedding":{"values":[0.1,0.2,0.3]}}"#)
        transport.enqueue(body: #"{"embeddings":[{"values":[1,2]},{"values":[3,4]}]}"#)
        transport.enqueue(body: #"{"models":[{"name":"models/gemini-3.8-flash","displayName":"Gemini 3.8 Flash","inputTokenLimit":1048576,"outputTokenLimit":65536,"supportedGenerationMethods":["generateContent","countTokens"]},{"name":"models/gemini-embedding-001","supportedGenerationMethods":["embedContent"]}],"nextPageToken":""}"#)
        let client = makeClient(transport)

        let single = try await client.embed(texts: ["hello"], model: "gemini-embedding-001")
        XCTAssertEqual(single, [[0.1, 0.2, 0.3]])
        XCTAssertEqual(transport.lastRequest?.url.absoluteString,
                       "https://generativelanguage.googleapis.com/v1beta/models/gemini-embedding-001:embedContent")
        XCTAssertEqual(transport.lastBody, ["content": ["parts": [["text": "hello"]]]])

        let batch = try await client.embed(texts: ["a", "b"], model: "models/gemini-embedding-001")
        XCTAssertEqual(batch, [[1, 2], [3, 4]])
        XCTAssertEqual(transport.lastBody?.at("requests", 1), ["model": "models/gemini-embedding-001",
                                                              "content": ["parts": [["text": "b"]]]])

        let models = try await client.listModels()
        XCTAssertEqual(models.map(\.id), ["gemini-3.8-flash"])
        XCTAssertEqual(models[0].capabilities.contextWindow, 1_048_576)
        XCTAssertTrue(transport.lastRequest?.url.absoluteString.hasSuffix("/models?pageSize=1000") ?? false)
    }

    func testSchemaSanitiser() {
        let schema: JSONValue = ["type": "object", "additionalProperties": false, "strict": true,
                                 "properties": ["region": ["type": "array", "items": ["type": "integer", "minimum": 0],
                                                           "minItems": 4, "maxItems": 4, "examples": [[1, 2, 3, 4]]],
                                                "mode": ["anyOf": [["type": "string"], ["type": "null"]]]]]
        XCTAssertEqual(GeminiClient.geminiSchema(schema),
                       ["type": "object",
                        "properties": ["region": ["type": "array", "items": ["type": "integer", "minimum": 0],
                                                  "minItems": 4, "maxItems": 4],
                                       "mode": ["anyOf": [["type": "string"], ["type": "null"]]]]])
    }
}
