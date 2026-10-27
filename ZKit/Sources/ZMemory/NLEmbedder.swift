#if canImport(NaturalLanguage)
import Foundation
import NaturalLanguage
import ZCore

/// On-device sentence embeddings from Apple's NaturalLanguage framework (Apple platforms only).
/// `init` returns nil when the OS has no sentence-embedding model for the language.
@available(macOS 11.0, iOS 14.0, *)
public final class NLEmbedder: Embedder, @unchecked Sendable {
    public let id: String
    public let dimensions: Int
    private let embedding: NLEmbedding
    // NLEmbedding is not documented as thread-safe, so lookups are serialised.
    private let lock = NSLock()

    public init?(languageCode: String = "en") {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: NLLanguage(rawValue: languageCode)) else { return nil }
        self.embedding = embedding
        self.dimensions = embedding.dimension
        self.id = "nl-sentence-\(languageCode)-r\(embedding.revision)"
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        vectors(for: texts)
    }

    /// Texts the model cannot embed give the zero vector (they then only match by keyword).
    public func vectors(for texts: [String]) -> [[Float]] {
        lock.lock()
        defer { lock.unlock() }
        return texts.map { text in
            guard let vector = embedding.vector(for: text), vector.count == dimensions else {
                return [Float](repeating: 0, count: dimensions)
            }
            return vector.map { Float($0) }
        }
    }
}
#endif
