import Foundation
import XCTest
import ZCore
@testable import ZMemory

final class EpisodeRecorderTests: XCTestCase {
    var transcript: [ChatMessage] { Self.sampleTranscript }

    static let sampleTranscript: [ChatMessage] = [
        .system("You are a computer-use agent. SECRET-SYSTEM-PROMPT"),
        .user("Please install rustup on the VM"),
        ChatMessage(role: .assistant, parts: [
            .reasoning("thinking about it"),
            .text("Running the installer"),
            .toolUse(ToolCall(id: "1", name: "shell", arguments: ["command": "curl https://sh.rustup.rs | sh -s -- -y"])),
        ]),
        .toolResults([ToolResult(callID: "1", text: "rustup 1.28.1 installed")]),
        .assistant("rustup is installed."),
    ]

    func testStoresTheModelSummaryCappedAtFiveLines() async throws {
        let client = MockLLMClient(reply: "Line 1\nLine 2\n\nLine 3\nLine 4\nLine 5\nLine 6\nLine 7")
        let store = try makeStore()
        let outcome = AgentOutcome(success: true, summary: "rustup 1.28.1 installed", steps: 3,
                                   usage: Usage(inputTokens: 1_200, outputTokens: 300))
        let item = try await EpisodeRecorder.record(task: "Install rustup", transcript: transcript, outcome: outcome,
                                                    client: client, store: store)

        XCTAssertEqual(item.kind, .episode)
        XCTAssertEqual(item.text, "Line 1\nLine 2\nLine 3\nLine 4\nLine 5")
        XCTAssertEqual(item.title, "Episode: Install rustup")
        XCTAssertEqual(item.tags, ["episode", "success"])
        XCTAssertEqual(item.source, "agent:mock/mock-1")
        XCTAssertEqual(item.metadata["summarizer"]?.stringValue, "mock/mock-1")
        XCTAssertEqual(item.metadata["success"]?.boolValue, true)
        XCTAssertEqual(item.metadata["steps"]?.intValue, 3)
        let stored = try await store.get(id: item.id)
        XCTAssertEqual(stored, item)
        let episodes = try await store.count(kind: .episode)
        XCTAssertEqual(episodes, 1)

        let requests = client.requests
        XCTAssertEqual(requests.count, 1)
        let prompt = (requests.first ?? []).map(\.text).joined(separator: "\n")
        XCTAssertTrue(prompt.contains("Task: Install rustup"))
        XCTAssertTrue(prompt.contains("Please install rustup on the VM"))
        XCTAssertTrue(prompt.contains("[call shell"))
        XCTAssertTrue(prompt.contains("rustup 1.28.1 installed"))
        XCTAssertTrue(prompt.contains("at most 5"))
        XCTAssertFalse(prompt.contains("SECRET-SYSTEM-PROMPT"), "the agent's system prompt is not replayed")
        XCTAssertFalse(prompt.contains("thinking about it"), "reasoning is left out")
    }

    func testFallsBackToHeuristicSummaryWhenTheClientFails() async throws {
        let client = MockLLMClient(failure: .network("offline"))
        let store = try makeStore()
        let outcome = AgentOutcome(success: false, summary: "curl was blocked by the proxy", steps: 2, usage: Usage())
        let item = try await EpisodeRecorder.record(task: "Install rustup", transcript: transcript, outcome: outcome,
                                                    client: client, store: store)

        XCTAssertEqual(item.metadata["summarizer"]?.stringValue, "heuristic")
        XCTAssertTrue(item.text.contains("Task: Install rustup"), item.text)
        XCTAssertTrue(item.text.contains("Request: Please install rustup on the VM"), item.text)
        XCTAssertTrue(item.text.contains("failed after 2 step(s)"), item.text)
        XCTAssertTrue(item.text.contains("curl was blocked by the proxy"), item.text)
        XCTAssertLessThanOrEqual(item.text.components(separatedBy: "\n").count, 5)
        XCTAssertEqual(item.tags, ["episode", "failure"])
        let episodes = try await store.count(kind: .episode)
        XCTAssertEqual(episodes, 1)
        // The episode is findable afterwards.
        let hits = try await store.search("rustup proxy", kinds: [.episode], limit: 3)
        XCTAssertEqual(hits.first?.item.id, item.id)
    }

    func testEmptyReplyAndMissingClientUseHeuristicSummary() async throws {
        let store = try makeStore()
        let outcome = AgentOutcome(success: true, summary: "", steps: 1, usage: Usage())
        let silent = try await EpisodeRecorder.record(task: "", transcript: transcript, outcome: outcome,
                                                      client: MockLLMClient(reply: "  \n \n"), store: store)
        XCTAssertEqual(silent.metadata["summarizer"]?.stringValue, "heuristic")
        XCTAssertEqual(silent.title, "Episode: Please install rustup on the VM")
        XCTAssertTrue(silent.text.contains("Request: Please install rustup on the VM"), silent.text)
        XCTAssertTrue(silent.text.contains("succeeded after 1 step(s)"), silent.text)

        let offline = try await EpisodeRecorder.record(task: "Check disk space", transcript: [], outcome: outcome,
                                                       client: nil, store: store)
        XCTAssertEqual(offline.source, "agent")
        XCTAssertEqual(offline.text, "Task: Check disk space\nOutcome: succeeded after 1 step(s).")
        let episodes = try await store.count(kind: .episode)
        XCTAssertEqual(episodes, 2)
    }

    func testLongTranscriptsAreCondensed() {
        let recorder = EpisodeRecorder(maxTranscriptCharacters: 1_000, maxMessageCharacters: 100)
        let long: [ChatMessage] = (0..<200).map { .user("message \($0) " + String(repeating: "x", count: 300)) }
        let condensed = recorder.condensedTranscript(long)
        XCTAssertLessThanOrEqual(condensed.count, 1_000)
        XCTAssertTrue(condensed.hasPrefix("user: message 0 "))
        XCTAssertTrue(condensed.contains("message 199 "), "the end of the run is kept")
        XCTAssertTrue(condensed.components(separatedBy: "\n").allSatisfy { $0.count <= 100 + "user: ".count })
    }
}
