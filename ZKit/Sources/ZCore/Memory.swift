import Foundation

public enum MemoryKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// Stable facts about the user ("name is Everald", "prefers dark mode").
    case profile
    /// Things the agent learned that are worth keeping (environment facts, how a tool behaved).
    case fact
    /// A summary of one task run (what was asked, what happened, result).
    case episode
    /// An imported document (title + full text); its searchable pieces are `chunk`s.
    case document
    case chunk
    /// User preferences about how agents should behave.
    case preference
}

public struct MemoryItem: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var kind: MemoryKind
    public var title: String
    public var text: String
    public var tags: [String]
    /// For chunks: the parent document id. For episodes: nil.
    public var parentID: UUID?
    /// Free-form origin ("import:/path/file.pdf", "agent:lead", "user").
    public var source: String
    public var metadata: JSONValue
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), kind: MemoryKind, title: String, text: String, tags: [String] = [], parentID: UUID? = nil,
                source: String = "user", metadata: JSONValue = [:], createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.kind = kind; self.title = title; self.text = text; self.tags = tags; self.parentID = parentID
        self.source = source; self.metadata = metadata; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public struct MemoryHit: Hashable, Codable, Sendable, Identifiable {
    public var item: MemoryItem
    public var score: Double
    public var id: UUID { item.id }
    public init(item: MemoryItem, score: Double) { self.item = item; self.score = score }
}

/// The personal library. ZMemory implements it on SQLite; tests may use an in-memory version.
public protocol MemoryStore: Sendable {
    func save(_ item: MemoryItem) async throws
    func get(id: UUID) async throws -> MemoryItem?
    func delete(id: UUID) async throws
    func list(kind: MemoryKind?, limit: Int, offset: Int) async throws -> [MemoryItem]
    /// Hybrid search (vector + keyword) over the given kinds (all when empty).
    func search(_ query: String, kinds: [MemoryKind], limit: Int) async throws -> [MemoryHit]
    /// Stores a document and its chunks; returns the document item.
    func importDocument(title: String, text: String, source: String, tags: [String]) async throws -> MemoryItem
    func count(kind: MemoryKind?) async throws -> Int
}

public protocol Embedder: Sendable {
    var id: String { get }
    var dimensions: Int { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}
