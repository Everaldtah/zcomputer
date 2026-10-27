import Foundation
import XCTest
import ZCore
@testable import ZAgent

final class ContextManagerTests: XCTestCase {
    private func shot(_ n: Int) -> ImageData {
        ImageData(mime: "image/png", data: fakePNG(width: 100 + n, height: 100), width: 100 + n, height: 100)
    }

    /// user task (with an image) + 5 rounds of computer call / result-with-screenshot.
    private func transcriptWithScreenshots() -> [ChatMessage] {
        var messages: [ChatMessage] = [.user("Do it", images: [shot(0)])]
        for i in 1...5 {
            let call = ToolCall(id: "c\(i)", name: "computer", arguments: ["action": "screenshot"])
            messages.append(ChatMessage(role: .assistant, parts: [.toolUse(call)]))
            messages.append(.toolResults([ToolResult(callID: "c\(i)", parts: [.text("step \(i)"), .image(shot(i))])]))
        }
        return messages
    }

    func testOnlyTheLastScreenshotsStayImages() {
        let cm = ContextManager(keepScreenshots: 3)
        let pruned = cm.pruneScreenshots(transcriptWithScreenshots())

        XCTAssertEqual(pruned.count, 11)
        // The task image and the screenshots of steps 1–2 are gone; 3–5 remain.
        XCTAssertTrue(pruned[0].images.isEmpty)
        XCTAssertTrue(pruned[0].text.contains(ContextManager.omittedScreenshot))
        let remaining = pruned.flatMap { $0.toolResults }.map { ($0.text, $0.images.count) }
        XCTAssertEqual(remaining.map(\.1), [0, 0, 1, 1, 1])
        XCTAssertEqual(remaining[0].0, "step 1\n" + ContextManager.omittedScreenshot)
        XCTAssertEqual(remaining[4].0, "step 5")
        // Newest image is untouched.
        XCTAssertEqual(pruned.last?.toolResults.first?.images.first?.width, 105)
        // Idempotent.
        XCTAssertEqual(cm.pruneScreenshots(pruned), pruned)
    }

    func testKeepZeroRemovesAllImages() {
        let pruned = ContextManager(keepScreenshots: 0).pruneScreenshots(transcriptWithScreenshots())
        XCTAssertTrue(pruned.allSatisfy { $0.images.isEmpty && $0.toolResults.allSatisfy { $0.images.isEmpty } })
    }

    func testStripImagesForModelsWithoutVision() {
        let stripped = ContextManager.stripImages(transcriptWithScreenshots())
        XCTAssertTrue(stripped.allSatisfy { $0.images.isEmpty && $0.toolResults.allSatisfy { $0.images.isEmpty } })
        XCTAssertTrue(stripped[0].text.contains("cannot see images"))
    }

    func testTokenEstimate() {
        XCTAssertEqual(ContextManager.estimateTokens([.user(String(repeating: "a", count: 400))]), 4 + 100)
        let image = ImageData(mime: "image/png", data: Data(), width: 1366, height: 768)
        XCTAssertEqual(ContextManager.estimateTokens([.user("", images: [image])]), 4 + 0 + 1366 * 768 / 750)
        XCTAssertTrue(ContextManager(tokenBudget: 50).needsCompaction([.user(String(repeating: "word ", count: 100))]))
        XCTAssertFalse(ContextManager(tokenBudget: nil).needsCompaction([.user(String(repeating: "word ", count: 100_000))]))
    }

    func testCompactSummarisesOlderTurnsWithTheModel() async throws {
        let client = MockLLMClient(script: [[.textDelta("- opened the terminal\n- installed git"), .finished(.stop)]])
        let cm = ContextManager(keepScreenshots: 3, tokenBudget: 10, keepRecentMessages: 4)
        let messages = transcriptWithScreenshots()     // 11 messages
        XCTAssertTrue(cm.needsCompaction(messages))

        let compacted = try await cm.compact(messages, using: client)

        // Tail of 4 starts at an assistant message (index 7 → c4 call), never with a tool result.
        XCTAssertEqual(compacted.count, 5)
        XCTAssertEqual(compacted.map(\.role), [.user, .assistant, .tool, .assistant, .tool])
        XCTAssertTrue(compacted[0].text.contains("Original task: Do it"))
        XCTAssertTrue(compacted[0].text.contains("installed git"))
        XCTAssertEqual(compacted[1].toolCalls.first?.id, "c4")
        // The summariser saw a text rendering of the older part.
        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(request.first?.role, .system)
        XCTAssertTrue(request.last?.text.contains("[tool result] step 1") ?? false)
        XCTAssertFalse(request.last?.text.contains("step 4") ?? true)
    }

    func testCompactNeverStartsTheTailWithToolResults() {
        let cm = ContextManager(keepRecentMessages: 3)
        let messages = transcriptWithScreenshots()   // 11 messages; naive split at 8 is a .tool message
        let split = cm.splitIndex(messages)
        XCTAssertEqual(split, 7)
        XCTAssertEqual(messages[7].role, .assistant)
        XCTAssertNil(ContextManager(keepRecentMessages: 20).splitIndex(messages))
    }
}
