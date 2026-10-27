import Foundation
import XCTest
@testable import ZMemory

final class ChunkerTests: XCTestCase {
    // 50 tokens × 4 chars = 200-character chunks with a 40-character overlap: small enough to reason about.
    let small = Chunker(targetTokens: 50, overlapTokens: 10)

    func testDefaultsMatchTheSpec() {
        let chunker = Chunker()
        XCTAssertEqual(chunker.maxCharacters, 3_200)
        XCTAssertEqual(chunker.overlapCharacters, 400)
        XCTAssertEqual(Chunker.estimateTokens(String(repeating: "abcd", count: 100)), 100)
        XCTAssertEqual(Chunker.estimateTokens("abcde"), 2)
        XCTAssertEqual(Chunker.estimateTokens(""), 0)
    }

    func testShortTextIsOneChunk() {
        XCTAssertEqual(small.chunks("  A short note.\n"), ["A short note."])
        XCTAssertEqual(small.chunks("   \n\n  "), [])
    }

    func testSplitsOnParagraphsWithParagraphOverlap() throws {
        let paragraphs = (1...20).map { String(format: "Paragraph number %02d is here.", $0) }
        let chunks = small.chunks(paragraphs.joined(separator: "\n\n"))
        XCTAssertGreaterThan(chunks.count, 2)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, small.maxCharacters)
            XCTAssertTrue(chunk.hasPrefix("Paragraph number "), chunk)
            XCTAssertTrue(chunk.hasSuffix(" is here."), chunk)
        }
        // Each chunk starts by repeating the previous chunk's last paragraph.
        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            let lastParagraph = try XCTUnwrap(previous.components(separatedBy: "\n\n").last)
            XCTAssertTrue(next.hasPrefix(lastParagraph + "\n\n"), "\(next) should start with \(lastParagraph)")
        }
        // Nothing is lost.
        for paragraph in paragraphs {
            XCTAssertTrue(chunks.contains { $0.contains(paragraph) }, paragraph)
        }
    }

    func testLongParagraphSplitsOnSentences() {
        let sentences = (1...20).map { String(format: "Sentence number %02d ends here.", $0) }
        let chunks = small.chunks(sentences.joined(separator: " "))
        XCTAssertGreaterThan(chunks.count, 2)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, small.maxCharacters)
            XCTAssertTrue(chunk.hasPrefix("Sentence number "), chunk)
            XCTAssertTrue(chunk.hasSuffix("ends here."), chunk)
        }
        for sentence in sentences {
            XCTAssertTrue(chunks.contains { $0.contains(sentence) }, sentence)
        }
    }

    func testUnbrokenTextIsHardSplitWithinBudget() {
        let text = String(repeating: "x", count: 1_000)
        let chunks = small.chunks(text)
        XCTAssertGreaterThan(chunks.count, 4)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= small.maxCharacters && $0.allSatisfy { $0 == "x" } })
        XCTAssertGreaterThanOrEqual(chunks.reduce(0) { $0 + $1.count }, 1_000)
    }

    func testLongWordsSplitAtWhitespace() {
        let words = (1...200).map { "word\($0)" }
        let chunks = small.chunks(words.joined(separator: " "))
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, small.maxCharacters)
            XCTAssertTrue(chunk.hasPrefix("word"), chunk)
            // Chunks end on a whole word.
            let lastWord = String(chunk.split(separator: " ").last ?? "")
            XCTAssertTrue(words.contains(lastWord), lastWord)
        }
        for word in words {
            XCTAssertTrue(chunks.contains { $0.split(separator: " ").contains(Substring(word)) }, word)
        }
    }

    func testDefaultChunkerOnALongDocument() {
        let paragraph = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 10)
        let text = Array(repeating: paragraph, count: 40).joined(separator: "\n\n")
        let chunks = Chunker().chunks(text)
        XCTAssertGreaterThan(chunks.count, 4)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 3_200 })
        XCTAssertTrue(chunks.dropLast().allSatisfy { $0.count > 2_000 }, "chunks are filled close to the target")
    }
}
