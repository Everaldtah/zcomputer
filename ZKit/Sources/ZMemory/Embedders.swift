import Foundation
import ZCore

/// Deterministic feature-hashing embedder: word unigrams, word bigrams and character trigrams hashed (signed) into
/// a fixed number of dimensions, sub-linear term weighting, L2-normalised. No model, no network, same output on every
/// platform and every run — the always-available fallback.
public struct HashingEmbedder: Embedder, Hashable {
    public let dimensions: Int
    public var id: String { "hashing-v1-\(dimensions)" }

    static let unigramWeight: Float = 1.0
    static let bigramWeight: Float = 0.6
    static let trigramWeight: Float = 0.25

    public init(dimensions: Int = 256) {
        self.dimensions = max(8, dimensions)
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { vector(for: $0) }
    }

    /// Synchronous embedding of one text. Empty or symbol-only text gives the zero vector.
    public func vector(for text: String) -> [Float] {
        var vector = [Float](repeating: 0, count: dimensions)
        let words = TextTokenizer.contentWords(text)
        guard !words.isEmpty else { return vector }

        var unigrams: [UInt64: Int] = [:]
        var bigrams: [UInt64: Int] = [:]
        var trigrams: [UInt64: Int] = [:]
        let unigramSeed = TextTokenizer.fnvOffset ^ 0x01
        let bigramSeed = TextTokenizer.fnvOffset ^ 0x02
        let trigramSeed = TextTokenizer.fnvOffset ^ 0x03

        for word in words {
            unigrams[TextTokenizer.fnv1a(word.utf8, seed: unigramSeed), default: 0] += 1
        }
        for (first, second) in zip(words, words.dropFirst()) {
            bigrams[TextTokenizer.fnv1a("\(first) \(second)".utf8, seed: bigramSeed), default: 0] += 1
        }
        for word in words {
            let scalars = Array("<\(word)>".unicodeScalars)
            guard scalars.count >= 3 else { continue }
            for start in 0...(scalars.count - 3) {
                var hash = trigramSeed
                for scalar in scalars[start..<(start + 3)] {
                    var value = scalar.value
                    for _ in 0..<4 {
                        hash ^= UInt64(value & 0xff)
                        hash = hash &* TextTokenizer.fnvPrime
                        value >>= 8
                    }
                }
                trigrams[hash, default: 0] += 1
            }
        }

        let buckets = UInt64(dimensions)
        func accumulate(_ counts: [UInt64: Int], weight: Float) {
            // Sorted so floating-point sums happen in the same order on every run.
            for key in counts.keys.sorted() {
                guard let count = counts[key] else { continue }
                let mixed = TextTokenizer.mix(key)
                let index = Int(mixed % buckets)
                let sign: Float = (mixed >> 63) == 0 ? 1 : -1
                vector[index] += sign * weight * Float(1 + log(Double(count)))
            }
        }
        accumulate(unigrams, weight: Self.unigramWeight)
        accumulate(bigrams, weight: Self.bigramWeight)
        accumulate(trigrams, weight: Self.trigramWeight)
        return VectorMath.normalized(vector)
    }
}

/// Embeds through any provider client that supports embeddings (`LLMClient.embed`).
/// `dimensions` must be the model's output size (e.g. 1536); results of another size are rejected.
public struct ProviderEmbedder: Embedder {
    public let client: any LLMClient
    /// Embedding model name passed to the provider (nil = the provider's default).
    public let model: String?
    public let dimensions: Int
    public let batchSize: Int
    public let id: String

    public init(client: any LLMClient, model: String? = nil, dimensions: Int, batchSize: Int = 64) {
        self.client = client
        self.model = model
        self.dimensions = dimensions
        self.batchSize = max(1, batchSize)
        self.id = "provider:\(client.model.provider.rawValue)/\(model ?? client.model.model)"
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        var vectors: [[Float]] = []
        vectors.reserveCapacity(texts.count)
        var start = 0
        while start < texts.count {
            let end = min(start + batchSize, texts.count)
            let batch = Array(texts[start..<end])
            let result = try await client.embed(texts: batch, model: model)
            guard result.count == batch.count else {
                throw ZError.decoding("\(id) returned \(result.count) embeddings for \(batch.count) texts")
            }
            if dimensions > 0, let wrong = result.first(where: { $0.count != dimensions }) {
                throw ZError.decoding("\(id) returned a \(wrong.count)-d embedding, expected \(dimensions)")
            }
            vectors.append(contentsOf: result)
            start = end
        }
        return vectors
    }
}
