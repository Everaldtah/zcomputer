import XCTest
@testable import ZCore

final class JSONValueTests: XCTestCase {
    func testRoundTrip() throws {
        let v: JSONValue = ["a": 1, "b": [true, "x", nil], "c": 2.5]
        let text = v.jsonString()
        let back = try JSONValue.parse(text)
        XCTAssertEqual(v, back)
        XCTAssertEqual(back["a"]?.intValue, 1)
        XCTAssertEqual(back["b"]?[1]?.stringValue, "x")
        XCTAssertEqual(text, #"{"a":1,"b":[true,"x",null],"c":2.5}"#)
    }

    func testCompleteCollectsToolCalls() async throws {
        struct Fake: LLMClient {
            var model = ModelRef(provider: "fake", model: "m")
            var capabilities = ModelCapabilities(tools: true)
            func stream(messages: [ChatMessage], tools: [ToolSpec], options: GenerationOptions) -> AsyncThrowingStream<StreamEvent, Error> {
                AsyncThrowingStream { c in
                    c.yield(.textDelta("hi "))
                    c.yield(.textDelta("there"))
                    c.yield(.toolCall(ToolCall(id: "1", name: "shell", arguments: ["command": "ls"])))
                    c.yield(.usage(Usage(inputTokens: 3, outputTokens: 4)))
                    c.yield(.finished(.stop))
                    c.finish()
                }
            }
            func listModels() async throws -> [ModelInfo] { [] }
        }
        let r = try await Fake().complete(messages: [.user("x")])
        XCTAssertEqual(r.message.text, "hi there")
        XCTAssertEqual(r.message.toolCalls.count, 1)
        XCTAssertEqual(r.finishReason, .toolCalls)
        XCTAssertEqual(r.usage.outputTokens, 4)
    }

    func testEventBusFanOut() async {
        let bus = EventBus()
        let stream = bus.subscribe()
        let em = AgentEmitter(agentID: "a", agentName: "A", sink: bus)
        em.emit(.note("hello"))
        var it = stream.makeAsyncIterator()
        let first = await it.next()
        if case .note(let s)? = first?.event { XCTAssertEqual(s, "hello") } else { XCTFail("no event") }
        XCTAssertEqual(bus.history.count, 1)
    }
}
