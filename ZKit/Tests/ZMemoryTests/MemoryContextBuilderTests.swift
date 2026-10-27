import Foundation
import XCTest
import ZCore
@testable import ZMemory

final class MemoryContextBuilderTests: XCTestCase {
    func testProfileAndPreferencesComeBeforeRelevantHits() async throws {
        let store = try makeStore()
        try await store.save(MemoryItem(kind: .profile, title: "Name", text: "Everald"))
        try await store.save(MemoryItem(kind: .preference, title: "Style", text: "Prefers concise answers"))
        try await store.save(MemoryItem(kind: .fact, title: "Rust setup", text: "Install the Rust toolchain with rustup"))
        try await store.save(MemoryItem(kind: .episode, title: "Episode: bake", text: "Baked banana bread\nIt took an hour"))

        let block = try await MemoryContextBuilder.contextBlock(for: "install rust", store: store, limit: 3)
        let lines = block.components(separatedBy: "\n")
        let name = try XCTUnwrap(lines.firstIndex { $0.contains("Everald") }, block)
        let style = try XCTUnwrap(lines.firstIndex { $0.contains("Prefers concise answers") }, block)
        let rust = try XCTUnwrap(lines.firstIndex { $0.contains("rustup") }, block)
        XCTAssertLessThan(name, style)
        XCTAssertLessThan(style, rust)
        XCTAssertEqual(lines[name], "- Name: Everald")
        XCTAssertTrue(lines[rust].hasPrefix("- [fact] Rust setup: "), lines[rust])
        XCTAssertTrue(block.hasPrefix("## Memory"))
        // Profile items are listed once, not repeated among the hits.
        XCTAssertEqual(lines.filter { $0.contains("Everald") }.count, 1)
    }

    func testEmptyLibraryGivesEmptyBlock() async throws {
        let store = try makeStore()
        let block = try await MemoryContextBuilder.contextBlock(for: "anything at all", store: store, limit: 5)
        XCTAssertEqual(block, "")
    }

    func testPinnedItemsWithoutTask() async throws {
        let store = try makeStore()
        try await store.save(MemoryItem(kind: .preference, title: "", text: "Always ask before deleting files"))
        let block = try await MemoryContextBuilder.contextBlock(for: "", store: store, limit: 5)
        XCTAssertTrue(block.contains("- Always ask before deleting files"), block)
        XCTAssertFalse(block.contains("Relevant memories"))
    }

    func testRespectsCharacterBudget() async throws {
        let store = try makeStore()
        try await store.save(MemoryItem(kind: .profile, title: "Name", text: "Everald"))
        try await store.save(MemoryItem(kind: .profile, title: "Location", text: "London, works late evenings"))
        for n in 0..<30 {
            let text = String(repeating: "Deploy the service carefully and check the logs afterwards. ", count: 8)
            try await store.save(MemoryItem(kind: .fact, title: "Deploy note \(n)", text: text))
        }
        for budget in [60, 120, 300, 800, 4_000] {
            let builder = MemoryContextBuilder(characterBudget: budget)
            let block = try await builder.contextBlock(for: "deploy the service", store: store, limit: 20)
            XCTAssertLessThanOrEqual(block.count, budget, "budget \(budget)")
            XCTAssertFalse(block.isEmpty, "budget \(budget)")
            XCTAssertTrue(block.contains("About the user:\n- Location: London"),
                          "the (newest-first) profile comes first even when the budget is tight (\(budget)):\n\(block)")
        }
        let tight = try await MemoryContextBuilder(characterBudget: 60).contextBlock(for: "deploy", store: store, limit: 5)
        XCTAssertFalse(tight.contains("## Memory"), "the title is dropped when it would crowd out the content")
        let roomy = try await MemoryContextBuilder(characterBudget: 4_000).contextBlock(for: "deploy the service", store: store, limit: 20)
        XCTAssertTrue(roomy.contains("Deploy note"))
        let lines = roomy.components(separatedBy: "\n")
        XCTAssertTrue(lines.allSatisfy { $0.count <= 500 }, "long items are cut to maxLineCharacters")
        let none = try await MemoryContextBuilder(characterBudget: 0).contextBlock(for: "deploy", store: store, limit: 5)
        XCTAssertEqual(none, "")
    }

    func testChunkHitHidesItsDocument() {
        let document = MemoryItem(kind: .document, title: "Manual", text: "full text")
        let chunk = MemoryItem(kind: .chunk, title: "Manual (2/3)", text: "part two", parentID: document.id)
        let other = MemoryItem(kind: .document, title: "Other", text: "other text")
        let profile = MemoryItem(kind: .profile, title: "Name", text: "Everald")
        let hits = [document, chunk, other, profile, chunk].enumerated().map { MemoryHit(item: $0.element, score: Double(10 - $0.offset)) }
        let kept = MemoryContextBuilder.deduplicated(hits).map(\.item.id)
        XCTAssertEqual(kept, [chunk.id, other.id])
    }
}
