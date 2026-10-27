import Foundation
import XCTest
import ZCore
@testable import ZMemory

/// Scripted LLMClient: replies with fixed text (or fails), and records what it was asked.
final class MockLLMClient: LLMClient, @unchecked Sendable {
    let model = ModelRef(provider: "mock", model: "mock-1")
    let capabilities = ModelCapabilities(tools: true)
    private let reply: String
    private let failure: ZError?
    private let embeddingDimensions: Int
    private let lock = NSLock()
    private var recordedRequests: [[ChatMessage]] = []
    private var recordedEmbedBatches: [[String]] = []

    init(reply: String = "", failure: ZError? = nil, embeddingDimensions: Int = 3) {
        self.reply = reply
        self.failure = failure
        self.embeddingDimensions = embeddingDimensions
    }

    var requests: [[ChatMessage]] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    var embedBatches: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEmbedBatches
    }

    private func remember(request: [ChatMessage]) {
        lock.lock()
        recordedRequests.append(request)
        lock.unlock()
    }

    private func remember(embedBatch: [String]) {
        lock.lock()
        recordedEmbedBatches.append(embedBatch)
        lock.unlock()
    }

    func stream(messages: [ChatMessage], tools: [ToolSpec], options: GenerationOptions) -> AsyncThrowingStream<StreamEvent, Error> {
        remember(request: messages)
        let reply = self.reply
        let failure = self.failure
        return AsyncThrowingStream { continuation in
            if let failure {
                continuation.finish(throwing: failure)
                return
            }
            if !reply.isEmpty { continuation.yield(.textDelta(reply)) }
            continuation.yield(.usage(Usage(inputTokens: 10, outputTokens: 5)))
            continuation.yield(.finished(.stop))
            continuation.finish()
        }
    }

    func listModels() async throws -> [ModelInfo] { [] }

    func embed(texts: [String], model: String?) async throws -> [[Float]] {
        remember(embedBatch: texts)
        if let failure { throw failure }
        return texts.map { text in (0..<embeddingDimensions).map { Float(text.count + $0) } }
    }
}

/// Maps words onto four "concept" axes, so tests control exactly which items are semantically close
/// without sharing any keyword.
struct ConceptEmbedder: Embedder {
    let id = "concept-test"
    let dimensions = 4
    static let axes: [Set<String>] = [
        ["fruit", "apple", "banana", "mango"],
        ["car", "engine", "wheel", "tyre", "garage"],
        ["music", "guitar", "piano", "melody"],
        ["weather", "rain", "sunny", "forecast"],
    ]

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { text in
            let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            return Self.axes.map { axis in Float(words.filter { axis.contains($0) }.count) }
        }
    }
}

/// An embedder whose service is always down.
struct FailingEmbedder: Embedder {
    let id = "failing-test"
    let dimensions = 8
    func embed(_ texts: [String]) async throws -> [[Float]] { throw ZError.network("embedding service offline") }
}

func makeStore(embedder: any Embedder = HashingEmbedder(), preferFTS5: Bool = true,
               chunker: Chunker = Chunker()) throws -> SQLiteMemoryStore {
    try SQLiteMemoryStore.inMemory(
        embedder: embedder, configuration: SQLiteMemoryStore.Configuration(preferFTS5: preferFTS5, chunker: chunker))
}

/// A fresh, empty directory under the system temporary directory.
func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("zmemory-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
