import Foundation
import XCTest
import ZCore
@testable import ZProviders

final class SSEParserTests: XCTestCase {
    func parse(_ text: String) -> [SSEEvent] {
        var parser = SSEParser()
        return parser.feed(text) + parser.finish()
    }

    func testBasicEvents() {
        let events = parse("data: hello\n\ndata: world\n\n")
        XCTAssertEqual(events.map(\.data), ["hello", "world"])
        XCTAssertNil(events[0].event)
    }

    func testEventTypeIDAndRetry() {
        let events = parse("event: message_start\nid: 7\nretry: 3000\ndata: {\"a\":1}\n\n")
        XCTAssertEqual(events, [SSEEvent(event: "message_start", data: "{\"a\":1}", id: "7", retry: 3000)])
    }

    func testEventTypeResetsBetweenEvents() {
        let events = parse("event: ping\ndata: {}\n\ndata: plain\n\n")
        XCTAssertEqual(events.map(\.event), ["ping", nil])
    }

    func testCRLFAndBareCR() {
        let events = parse("data: a\r\n\r\ndata: b\r\rdata: c\n\n")
        XCTAssertEqual(events.map(\.data), ["a", "b", "c"])
    }

    func testCRLFSplitAcrossChunks() {
        var parser = SSEParser()
        var events = parser.feed("data: a\r")
        events += parser.feed("\n\r")
        events += parser.feed("\ndata: b\r\n")
        events += parser.feed("\r\n")
        events += parser.finish()
        XCTAssertEqual(events.map(\.data), ["a", "b"])
    }

    func testCommentsAreIgnored() {
        let events = parse(": keep-alive\n\n:another\ndata: x\n\n")
        XCTAssertEqual(events.map(\.data), ["x"])
    }

    func testMultiLineData() {
        let events = parse("data: line1\ndata: line2\ndata:\n\n")
        XCTAssertEqual(events.map(\.data), ["line1\nline2\n"])
    }

    func testOnlyOneSpaceIsStripped() {
        XCTAssertEqual(parse("data:x\n\n").map(\.data), ["x"])
        XCTAssertEqual(parse("data:  two\n\n").map(\.data), [" two"])
    }

    func testFieldWithoutColonAndUnknownFields() {
        XCTAssertEqual(parse("data\n\n").map(\.data), [""])
        XCTAssertEqual(parse("foo: bar\ndata: y\n\n").map(\.data), ["y"])
        XCTAssertEqual(parse("event: only\n\n"), [], "an event without data is not dispatched")
    }

    func testUTF8SplitAcrossChunks() {
        var parser = SSEParser()
        var events: [SSEEvent] = []
        for byte in Data("data: héllo 🙂\n\n".utf8) { events += parser.feed(Data([byte])) }
        events += parser.finish()
        XCTAssertEqual(events.map(\.data), ["héllo 🙂"])
    }

    func testFinishFlushesTrailingEvent() {
        var parser = SSEParser()
        XCTAssertEqual(parser.feed("data: first\n\ndata: last"), [SSEEvent(data: "first")])
        XCTAssertEqual(parser.finish().map(\.data), ["last"])
    }

    func testBOMAndDoneMarker() {
        let events = parse("\u{FEFF}data: x\n\ndata: [DONE]\n\n")
        XCTAssertEqual(events.map(\.data), ["x", "[DONE]"])
        XCTAssertFalse(events[0].isDone)
        XCTAssertTrue(events[1].isDone)
    }

    func testLineSplitter() {
        var splitter = LineSplitter()
        var lines = splitter.feed(Data("{\"a\":1}\r\n{\"b\"".utf8))
        lines += splitter.feed(Data(":2}\n\n\n{\"c\":3}".utf8))
        lines += splitter.finish()
        XCTAssertEqual(lines, ["{\"a\":1}", "{\"b\":2}", "{\"c\":3}"])
    }

    func testThinkTagSplitter() {
        var splitter = ThinkTagSplitter()
        var events = splitter.feed("<thi")
        events += splitter.feed("nk>plan it</th")
        events += splitter.feed("ink>The answer <b")
        events += splitter.flush()
        var text = ""
        var reasoning = ""
        for event in events {
            switch event {
            case .textDelta(let t): text += t
            case .reasoningDelta(let r): reasoning += r
            default: XCTFail("unexpected \(event)")
            }
        }
        XCTAssertEqual(reasoning, "plan it")
        XCTAssertEqual(text, "The answer <b")
    }
}

final class ToolCallAssemblerTests: XCTestCase {
    func testOpenAIStyleDeltas() {
        var assembler = ToolCallAssembler()
        var events = assembler.ingest(index: 0, id: "call_1", name: "get_weather", argumentsDelta: "")
        events += assembler.ingest(index: 0, id: nil, name: nil, argumentsDelta: "{\"loc")
        events += assembler.ingest(index: 0, id: nil, name: nil, argumentsDelta: "ation\": \"Paris\"}")
        let calls = assembler.finish()
        XCTAssertEqual(calls, [ToolCall(id: "call_1", name: "get_weather", arguments: ["location": "Paris"])])
        guard case .toolCallStart(let id, let name)? = events.first else { return XCTFail("no start") }
        XCTAssertEqual(id, "call_1")
        XCTAssertEqual(name, "get_weather")
        let deltas = events.compactMap { event -> String? in
            if case .toolCallDelta(_, let d) = event { return d }
            return nil
        }
        XCTAssertEqual(deltas.joined(), "{\"location\": \"Paris\"}")
        XCTAssertTrue(assembler.isEmpty)
    }

    func testParallelCallsByIndex() {
        var assembler = ToolCallAssembler()
        _ = assembler.ingest(index: 0, id: "a", name: "one", argumentsDelta: "{\"x\":")
        _ = assembler.ingest(index: 1, id: "b", name: "two", argumentsDelta: "{\"y\":")
        _ = assembler.ingest(index: 1, id: nil, name: nil, argumentsDelta: "2}")
        _ = assembler.ingest(index: 0, id: nil, name: nil, argumentsDelta: "1}")
        let calls = assembler.finish()
        XCTAssertEqual(calls.map(\.id), ["a", "b"])
        XCTAssertEqual(calls[0].arguments, ["x": 1])
        XCTAssertEqual(calls[1].arguments, ["y": 2])
    }

    func testSameIndexDifferentIDsStartsANewCall() {
        var assembler = ToolCallAssembler()
        _ = assembler.ingest(index: 0, id: "a", name: "one", argumentsDelta: "{}")
        _ = assembler.ingest(index: 0, id: "b", name: "two", argumentsDelta: "{}")
        XCTAssertEqual(assembler.finish().map(\.name), ["one", "two"])
    }

    func testIDOnlyAndContinuationFragments() {
        var assembler = ToolCallAssembler()
        _ = assembler.ingest(index: nil, id: "x1", name: "first", argumentsDelta: "{\"a\":")
        _ = assembler.ingest(index: nil, id: nil, name: nil, argumentsDelta: "true}")
        _ = assembler.ingest(index: nil, id: "x2", name: "second", argumentsDelta: nil)
        let calls = assembler.finish()
        XCTAssertEqual(calls.map(\.id), ["x1", "x2"])
        XCTAssertEqual(calls[0].arguments, ["a": true])
        XCTAssertEqual(calls[1].arguments, [:])
    }

    func testMissingIDIsSynthesised() {
        var assembler = ToolCallAssembler()
        let events = assembler.ingest(index: 0, id: nil, name: "tool", argumentsDelta: "{}")
        let calls = assembler.finish()
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls[0].id.hasPrefix("call_"))
        guard case .toolCallStart(let id, _)? = events.first else { return XCTFail("no start") }
        XCTAssertEqual(id, calls[0].id)
    }

    func testArgumentsBeforeNameAreFlushedAtStart() {
        var assembler = ToolCallAssembler()
        XCTAssertTrue(assembler.ingest(index: 0, id: "c", name: nil, argumentsDelta: "{\"k\":").isEmpty)
        let events = assembler.ingest(index: 0, id: nil, name: "late", argumentsDelta: "1}")
        XCTAssertEqual(events.count, 2)
        if case .toolCallDelta(_, let d) = events[1] { XCTAssertEqual(d, "{\"k\":1}") } else { XCTFail("no delta") }
    }

    func testSetArgumentsOverrides() {
        var assembler = ToolCallAssembler()
        _ = assembler.ingest(index: 3, id: "c", name: "t", argumentsDelta: "{\"garbled")
        assembler.setArguments(index: 3, id: nil, arguments: "{\"fixed\":1}")
        XCTAssertEqual(assembler.finish().first?.arguments, ["fixed": 1])
    }

    func testCallsWithoutNameAreDropped() {
        var assembler = ToolCallAssembler()
        _ = assembler.ingest(index: 0, id: "c", name: nil, argumentsDelta: "{}")
        XCTAssertEqual(assembler.finish(), [])
    }

    func testParseArgumentsLeniency() {
        XCTAssertEqual(ToolCallAssembler.parseArguments(""), [:])
        XCTAssertEqual(ToolCallAssembler.parseArguments("  \n"), [:])
        XCTAssertEqual(ToolCallAssembler.parseArguments("{\"a\": [1, 2]}"), ["a": [1, 2]])
        XCTAssertEqual(ToolCallAssembler.parseArguments("\"{\\\"a\\\": 1}\""), ["a": 1], "double-encoded object")
        XCTAssertEqual(ToolCallAssembler.parseArguments("{broken"), .string("{broken"))
    }
}
