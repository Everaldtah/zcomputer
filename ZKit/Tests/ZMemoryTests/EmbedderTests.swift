import Foundation
import XCTest
import ZCore
@testable import ZMemory

final class EmbedderTests: XCTestCase {
    func testHashingEmbedderIsDeterministicAndNormalised() async throws {
        let embedder = HashingEmbedder()
        XCTAssertEqual(embedder.dimensions, 256)
        XCTAssertEqual(embedder.id, "hashing-v1-256")
        let vectors = try await embedder.embed(["Install the Rust toolchain", "Install the Rust toolchain"])
        XCTAssertEqual(vectors.count, 2)
        XCTAssertEqual(vectors[0], vectors[1])
        XCTAssertEqual(vectors[0].count, 256)
        XCTAssertEqual(VectorMath.norm(vectors[0]), 1, accuracy: 1e-4)
        // A fresh instance (and, because hashing is FNV-based, a fresh process) gives the same vector.
        XCTAssertEqual(HashingEmbedder().vector(for: "Install the Rust toolchain"), vectors[0])
        XCTAssertEqual(HashingEmbedder(dimensions: 64).vector(for: "x").count, 64)
    }

    func testHashingEmbedderPlacesRelatedTextsCloser() {
        let embedder = HashingEmbedder()
        let anchor = embedder.vector(for: "install rust toolchain")
        let related = embedder.vector(for: "how to install the rust compiler")
        let unrelated = embedder.vector(for: "banana bread recipe with walnuts")
        XCTAssertGreaterThan(VectorMath.cosine(anchor, related), VectorMath.cosine(anchor, unrelated) + 0.2)
        // Character trigrams give partial credit to word variants.
        let variant = embedder.vector(for: "installation of toolchains")
        XCTAssertGreaterThan(VectorMath.cosine(anchor, variant), VectorMath.cosine(anchor, unrelated))
    }

    func testEmptyTextEmbedsToZeroVector() {
        let embedder = HashingEmbedder()
        XCTAssertEqual(embedder.vector(for: ""), [Float](repeating: 0, count: 256))
        XCTAssertEqual(embedder.vector(for: "  ... !!! "), [Float](repeating: 0, count: 256))
        // Stop words alone still produce a vector rather than nothing.
        XCTAssertEqual(VectorMath.norm(embedder.vector(for: "the and of")), 1, accuracy: 1e-4)
    }

    func testProviderEmbedderBatchesAndValidates() async throws {
        let client = MockLLMClient(embeddingDimensions: 3)
        let embedder = ProviderEmbedder(client: client, model: "embed-small", dimensions: 3, batchSize: 2)
        XCTAssertEqual(embedder.id, "provider:mock/embed-small")
        let texts = ["a", "bb", "ccc", "dddd", "eeeee"]
        let vectors = try await embedder.embed(texts)
        XCTAssertEqual(vectors.count, 5)
        XCTAssertEqual(vectors[2], [3, 4, 5])
        XCTAssertEqual(client.embedBatches, [["a", "bb"], ["ccc", "dddd"], ["eeeee"]])
        let none = try await embedder.embed([])
        XCTAssertTrue(none.isEmpty)

        let wrongSize = ProviderEmbedder(client: client, dimensions: 8)
        do {
            _ = try await wrongSize.embed(["x"])
            XCTFail("a 3-d result must be rejected when 8-d is expected")
        } catch {
            guard case .decoding? = error as? ZError else { return XCTFail("unexpected error \(error)") }
        }
    }

    func testProviderEmbedderPropagatesClientErrors() async {
        let client = MockLLMClient(failure: .unsupported("embeddings"))
        let embedder = ProviderEmbedder(client: client, dimensions: 3)
        do {
            _ = try await embedder.embed(["x"])
            XCTFail("expected the client's error")
        } catch {
            XCTAssertEqual(error as? ZError, .unsupported("embeddings"))
        }
    }

    func testVectorCodecRoundTrip() {
        let vector: [Float] = [0, 1, -1, 0.5, -123.456, .greatestFiniteMagnitude, .leastNonzeroMagnitude]
        let data = VectorMath.encode(vector)
        XCTAssertEqual(data.count, vector.count * 4)
        XCTAssertEqual(Array(VectorMath.encode([1]).prefix(4)), [0x00, 0x00, 0x80, 0x3f], "float32 little-endian")
        XCTAssertEqual(VectorMath.decode(data), vector)
        XCTAssertEqual(VectorMath.decode(Data([1, 2, 3])), [])
        XCTAssertEqual(VectorMath.cosine([1, 0], [0, 1]), 0)
        XCTAssertEqual(VectorMath.cosine([1, 2], [2, 4]), 1, accuracy: 1e-6)
        XCTAssertEqual(VectorMath.cosine([1, 2], [1, 2, 3]), 0)
        XCTAssertEqual(VectorMath.cosine([0, 0], [1, 1]), 0)
    }
}
