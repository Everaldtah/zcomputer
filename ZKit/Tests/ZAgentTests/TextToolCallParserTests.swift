import Foundation
import XCTest
import ZCore
@testable import ZAgent

final class TextToolCallParserTests: XCTestCase {
    let parser = TextToolCallParser(knownTools: ["shell", "computer", "task_complete", "type_text"])

    func testFencedJSONBlockWithProse() {
        let text = """
        I'll check the disk usage first.
        ```json
        {"tool": "shell", "arguments": {"command": "df -h"}}
        ```
        """
        let r = parser.parse(text, idPrefix: "s1")
        XCTAssertEqual(r.calls.count, 1)
        XCTAssertEqual(r.calls.first?.id, "s1_0")
        XCTAssertEqual(r.calls.first?.name, "shell")
        XCTAssertEqual(r.calls.first?.arguments["command"]?.stringValue, "df -h")
        XCTAssertEqual(r.prose, "I'll check the disk usage first.")
    }

    func testFenceWithoutLanguageAndNameParametersKeysAndStringArguments() {
        let text = "```\n{\"name\": \"computer\", \"parameters\": \"{\\\"action\\\": \\\"click\\\", \\\"x\\\": 5, \\\"y\\\": 6}\"}\n```"
        let r = parser.parse(text)
        XCTAssertEqual(r.calls.count, 1)
        XCTAssertEqual(r.calls.first?.name, "computer")
        XCTAssertEqual(r.calls.first?.arguments["action"]?.stringValue, "click")
        XCTAssertEqual(r.calls.first?.arguments["x"]?.intValue, 5)
    }

    func testTrailingCommasAndSmartQuotesAreRepaired() {
        let text = "```json\n{\u{201C}tool\u{201D}: \"shell\", \"arguments\": {\"command\": \"ls\",},}\n```"
        let r = parser.parse(text)
        XCTAssertEqual(r.calls.first?.name, "shell")
        XCTAssertEqual(r.calls.first?.arguments["command"]?.stringValue, "ls")
    }

    func testUnterminatedFenceRunsToTheEnd() {
        let text = "Done soon.\n```json\n{\"tool\": \"task_complete\", \"arguments\": {\"summary\": \"ok\"}}"
        let r = parser.parse(text)
        XCTAssertEqual(r.calls.map(\.name), ["task_complete"])
        XCTAssertEqual(r.prose, "Done soon.")
    }

    func testOneLineFence() {
        let r = parser.parse("```json {\"tool\": \"shell\", \"arguments\": {\"command\": \"pwd\"}}```")
        XCTAssertEqual(r.calls.first?.arguments["command"]?.stringValue, "pwd")
    }

    func testBareJSONObjectInProse() {
        let text = "Sure, running it now: {\"tool\": \"shell\", \"arguments\": {\"command\": \"uname -a\"}} and then I will report."
        let r = parser.parse(text)
        XCTAssertEqual(r.calls.first?.name, "shell")
        XCTAssertEqual(r.prose, "Sure, running it now:  and then I will report.")
    }

    func testBareObjectNamingAnUnknownToolIsIgnored() {
        let r = parser.parse("Here is the config: {\"name\": \"my-app\", \"version\": \"1.0\"}")
        XCTAssertTrue(r.calls.isEmpty)
    }

    func testToolCallTags() {
        let text = "<tool_call>\n{\"name\": \"shell\", \"arguments\": {\"command\": \"whoami\"}}\n</tool_call>"
        let r = parser.parse(text)
        XCTAssertEqual(r.calls.first?.name, "shell")
        XCTAssertEqual(r.calls.first?.arguments["command"]?.stringValue, "whoami")
        XCTAssertEqual(r.prose, "")
    }

    func testNonToolCodeBlockIsIgnored() {
        let text = "Run this:\n```bash\nls -la\n```"
        let r = parser.parse(text)
        XCTAssertTrue(r.calls.isEmpty)
        XCTAssertEqual(r.prose, text)
    }

    func testMultipleBlocksGetSequentialIDs() {
        let text = """
        ```json
        {"tool": "shell", "arguments": {"command": "a"}}
        ```
        then
        ```json
        {"tool": "shell", "arguments": {"command": "b"}}
        ```
        """
        let r = parser.parse(text, idPrefix: "p")
        XCTAssertEqual(r.calls.map(\.id), ["p_0", "p_1"])
        XCTAssertEqual(r.calls.compactMap { $0.arguments["command"]?.stringValue }, ["a", "b"])
        XCTAssertEqual(r.prose, "then")
    }

    func testBracesInsideStringsDoNotConfuseTheScanner() {
        let text = "{\"tool\": \"type_text\", \"arguments\": {\"text\": \"a } b { c \\\" }\"}}"
        let r = parser.parse(text)
        XCTAssertEqual(r.calls.first?.name, "type_text")
        XCTAssertEqual(r.calls.first?.arguments["text"]?.stringValue, "a } b { c \" }")
    }

    func testFlatArgumentsAndOpenAIFunctionShapeAndArrays() {
        let flat = parser.parse("```json\n{\"tool\": \"shell\", \"command\": \"ls\", \"timeout\": 5}\n```")
        XCTAssertEqual(flat.calls.first?.arguments, ["command": "ls", "timeout": 5])

        let openAI = parser.parse("```json\n{\"type\": \"function\", \"function\": {\"name\": \"shell\", \"arguments\": \"{\\\"command\\\": \\\"id\\\"}\"}}\n```")
        XCTAssertEqual(openAI.calls.first?.name, "shell")
        XCTAssertEqual(openAI.calls.first?.arguments["command"]?.stringValue, "id")

        let array = parser.parse("```json\n[{\"tool\": \"shell\", \"arguments\": {\"command\": \"a\"}}, {\"tool\": \"task_complete\", \"arguments\": {}}]\n```")
        XCTAssertEqual(array.calls.map(\.name), ["shell", "task_complete"])

        let wrapped = parser.parse("```json\n{\"tool_calls\": [{\"name\": \"shell\", \"arguments\": {\"command\": \"x\"}}]}\n```")
        XCTAssertEqual(wrapped.calls.map(\.name), ["shell"])
    }

    func testPlainTextHasNoCalls() {
        let r = parser.parse("All done, the file is saved.")
        XCTAssertTrue(r.calls.isEmpty)
        XCTAssertEqual(r.prose, "All done, the file is saved.")
    }

    func testFormatInstructionsListTools() {
        let s = TextToolCallParser.formatInstructions(tools: [ShellTool().spec])
        XCTAssertTrue(s.contains("```json"))
        XCTAssertTrue(s.contains("- shell:"))
    }
}
