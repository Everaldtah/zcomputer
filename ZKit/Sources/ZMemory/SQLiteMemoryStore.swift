import Foundation
import ZCore

/// The personal library on SQLite.
///
/// * `items` holds every `MemoryItem` (tags and metadata as JSON, dates as seconds since the reference date).
/// * `embeddings` holds one float32 little-endian vector per item and embedder model.
/// * `items_fts` is an FTS5 index (porter stemming) when the SQLite library has FTS5; otherwise keyword search
///   falls back to `LIKE` scans.
///
/// `search` is hybrid: brute-force cosine over the stored vectors (fine up to ~50k items) united with keyword
/// hits, merged by reciprocal-rank fusion. `MemoryHit.score` is the fused score (higher is better).
/// Embedding failures never block a save: the item is stored without a vector, stays findable by keyword, and
/// `reindexEmbeddings()` fills the gap later.
public final class SQLiteMemoryStore: MemoryStore, Sendable {
    public enum KeywordSearchMode: String, Sendable, Hashable {
        case fts5
        case like
    }

    public struct Configuration: Sendable, Hashable {
        /// Use FTS5 when the library supports it (false forces the LIKE fallback).
        public var preferFTS5: Bool
        /// Candidates taken from each ranking before fusion (at least 4 × the requested limit).
        public var candidatePoolSize: Int
        /// The k in 1 / (k + rank).
        public var rrfK: Double
        /// Vector hits below this cosine similarity are ignored.
        public var minimumSimilarity: Float
        /// How `importDocument` splits text.
        public var chunker: Chunker
        /// Longer texts are cut to this many characters before embedding.
        public var maxEmbeddingCharacters: Int
        /// Texts per `Embedder.embed` call when embedding many items.
        public var embeddingBatchSize: Int

        public init(preferFTS5: Bool = true, candidatePoolSize: Int = 50, rrfK: Double = 60, minimumSimilarity: Float = 0.05,
                    chunker: Chunker = Chunker(), maxEmbeddingCharacters: Int = 8_000, embeddingBatchSize: Int = 64) {
            self.preferFTS5 = preferFTS5
            self.candidatePoolSize = candidatePoolSize
            self.rrfK = rrfK
            self.minimumSimilarity = minimumSimilarity
            self.chunker = chunker
            self.maxEmbeddingCharacters = maxEmbeddingCharacters
            self.embeddingBatchSize = embeddingBatchSize
        }
    }

    public let database: SQLiteDatabase
    public let embedder: any Embedder
    public let configuration: Configuration
    /// The keyword engine chosen at open time.
    public let keywordMode: KeywordSearchMode
    public var usesFTS5: Bool { keywordMode == .fts5 }

    public init(database: SQLiteDatabase, embedder: any Embedder = HashingEmbedder(),
                configuration: Configuration = Configuration()) throws {
        let mode = try database.withConnection { connection -> KeywordSearchMode in
            try connection.exec(SQLiteMemoryStore.schemaSQL)
            if configuration.preferFTS5, SQLiteMemoryStore.setUpFTS(connection) { return .fts5 }
            return .like
        }
        self.database = database
        self.embedder = embedder
        self.configuration = configuration
        self.keywordMode = mode
    }

    /// Opens (creating when needed, including parent folders) the library at `path`; ":memory:" for a private one.
    public convenience init(path: String, embedder: any Embedder = HashingEmbedder(),
                            configuration: Configuration = Configuration()) throws {
        let inMemory = path.isEmpty || path == ":memory:"
        if !inMemory {
            let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let database = try SQLiteDatabase(path: inMemory ? ":memory:" : path)
        if !inMemory { try? database.exec("PRAGMA journal_mode = WAL") }
        try self.init(database: database, embedder: embedder, configuration: configuration)
    }

    /// A private in-memory library (tests, previews).
    public static func inMemory(embedder: any Embedder = HashingEmbedder(),
                                configuration: Configuration = Configuration()) throws -> SQLiteMemoryStore {
        try SQLiteMemoryStore(path: ":memory:", embedder: embedder, configuration: configuration)
    }

    // MARK: Schema

    static let schemaSQL = """
        CREATE TABLE IF NOT EXISTS items (
            id TEXT PRIMARY KEY NOT NULL,
            kind TEXT NOT NULL,
            title TEXT NOT NULL DEFAULT '',
            text TEXT NOT NULL DEFAULT '',
            source TEXT NOT NULL DEFAULT '',
            tags TEXT NOT NULL DEFAULT '[]',
            parentID TEXT,
            metadata TEXT NOT NULL DEFAULT '{}',
            createdAt REAL NOT NULL,
            updatedAt REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS items_kind_updated ON items(kind, updatedAt);
        CREATE INDEX IF NOT EXISTS items_updated ON items(updatedAt);
        CREATE INDEX IF NOT EXISTS items_parent ON items(parentID);
        CREATE TABLE IF NOT EXISTS embeddings (
            itemID TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
            model TEXT NOT NULL,
            dim INTEGER NOT NULL,
            vector BLOB NOT NULL,
            PRIMARY KEY (itemID, model)
        );
        CREATE INDEX IF NOT EXISTS embeddings_model ON embeddings(model, dim);
        PRAGMA user_version = 1;
        """

    /// Creates the FTS5 index (trying richer tokenizers first) and backfills it when it is out of step with
    /// `items`. Returns false when FTS5 is not available.
    static func setUpFTS(_ connection: SQLiteConnection) -> Bool {
        let tokenizers = ["porter unicode61 remove_diacritics 2", "porter unicode61", "unicode61"]
        var created = false
        for tokenizer in tokenizers {
            do {
                try connection.exec(
                    "CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(title, text, tags, tokenize = '\(tokenizer)')")
                created = true
                break
            } catch {
                continue
            }
        }
        guard created else { return false }
        do {
            let itemCount = try connection.scalar("SELECT count(*) FROM items").int64Value ?? 0
            let indexedCount = try connection.scalar("SELECT count(*) FROM items_fts").int64Value ?? 0
            if itemCount != indexedCount {
                try connection.transaction {
                    try connection.exec("DELETE FROM items_fts")
                    try connection.exec(
                        "INSERT INTO items_fts(rowid, title, text, tags) SELECT rowid, title, text, tags FROM items")
                }
            }
            return true
        } catch {
            return false
        }
    }

    static let itemColumns = "id, kind, title, text, source, tags, parentID, metadata, createdAt, updatedAt"

    static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    static func encodeTags(_ tags: [String]) -> String {
        guard let data = try? JSONEncoder().encode(tags) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeTags(_ text: String) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(text.utf8))) ?? []
    }

    /// Reads an item from the current row (columns in `itemColumns` order). Rows that cannot be decoded (bad id,
    /// a kind from a newer version) are skipped by callers.
    static func readItem(_ statement: SQLiteStatement) -> MemoryItem? {
        guard let idText = statement.string(0), let id = UUID(uuidString: idText),
              let kindText = statement.string(1), let kind = MemoryKind(rawValue: kindText) else { return nil }
        let parentID = statement.string(6).flatMap { UUID(uuidString: $0) }
        let metadata = statement.string(7).flatMap { try? JSONValue.parse($0) } ?? [:]
        return MemoryItem(
            id: id, kind: kind, title: statement.string(2) ?? "", text: statement.string(3) ?? "",
            tags: decodeTags(statement.string(5) ?? "[]"), parentID: parentID, source: statement.string(4) ?? "",
            metadata: metadata,
            createdAt: Date(timeIntervalSinceReferenceDate: statement.double(8)),
            updatedAt: Date(timeIntervalSinceReferenceDate: statement.double(9)))
    }

    static func kindNames(_ kinds: [MemoryKind]) -> [String] {
        Array(Set(kinds.map(\.rawValue))).sorted()
    }

    // MARK: Writing

    /// The text that gets embedded for an item: title + (possibly cut) body.
    public func embeddingText(for item: MemoryItem) -> String {
        let limit = max(1, configuration.maxEmbeddingCharacters)
        let body = item.text.count > limit ? String(item.text.prefix(limit)) : item.text
        return item.title.isEmpty ? body : item.title + "\n" + body
    }

    /// Embeds items in batches; a failed batch yields nil vectors (those items are saved without one).
    private func embedAll(_ items: [MemoryItem]) async -> [[Float]?] {
        var vectors: [[Float]?] = []
        vectors.reserveCapacity(items.count)
        let batchSize = max(1, configuration.embeddingBatchSize)
        var start = 0
        while start < items.count {
            let end = min(start + batchSize, items.count)
            let texts = items[start..<end].map { embeddingText(for: $0) }
            if let batch = try? await embedder.embed(texts), batch.count == texts.count {
                vectors.append(contentsOf: batch.map { $0.isEmpty ? nil : $0 })
            } else {
                vectors.append(contentsOf: Array(repeating: nil, count: texts.count))
            }
            start = end
        }
        return vectors
    }

    private static let upsertSQL = """
        INSERT INTO items (id, kind, title, text, source, tags, parentID, metadata, createdAt, updatedAt)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            kind = excluded.kind, title = excluded.title, text = excluded.text, source = excluded.source,
            tags = excluded.tags, parentID = excluded.parentID, metadata = excluded.metadata,
            createdAt = excluded.createdAt, updatedAt = excluded.updatedAt
        """

    /// Upserts one item, its keyword index row and its vector. Call inside a transaction.
    private func write(_ item: MemoryItem, vector: [Float]?, in connection: SQLiteConnection) throws {
        let key = item.id.uuidString
        let tags = Self.encodeTags(item.tags)
        let parent: SQLiteValue = item.parentID.map { SQLiteValue.text($0.uuidString) } ?? .null
        try connection.execute(Self.upsertSQL, [
            .text(key), .text(item.kind.rawValue), .text(item.title), .text(item.text), .text(item.source),
            .text(tags), parent, .text(item.metadata.jsonString()),
            .real(item.createdAt.timeIntervalSinceReferenceDate), .real(item.updatedAt.timeIntervalSinceReferenceDate),
        ])
        if keywordMode == .fts5 {
            let rowID = try connection.scalar("SELECT rowid FROM items WHERE id = ?", [.text(key)])
            try connection.execute("DELETE FROM items_fts WHERE rowid = ?", [rowID])
            try connection.execute("INSERT INTO items_fts(rowid, title, text, tags) VALUES (?, ?, ?, ?)",
                                   [rowID, .text(item.title), .text(item.text), .text(tags)])
        }
        try connection.execute("DELETE FROM embeddings WHERE itemID = ?", [.text(key)])
        if let vector, !vector.isEmpty {
            try connection.execute("INSERT INTO embeddings (itemID, model, dim, vector) VALUES (?, ?, ?, ?)", [
                .text(key), .text(embedder.id), .integer(Int64(vector.count)), .blob(VectorMath.encode(vector)),
            ])
        }
    }

    public func save(_ item: MemoryItem) async throws {
        try await save([item])
    }

    /// Saves several items in one transaction (embedded in batches first).
    public func save(_ items: [MemoryItem]) async throws {
        guard !items.isEmpty else { return }
        let vectors = await embedAll(items)
        try database.transaction { connection -> Void in
            for (item, vector) in zip(items, vectors) {
                try write(item, vector: vector, in: connection)
            }
        }
    }

    public func importDocument(title: String, text: String, source: String, tags: [String]) async throws -> MemoryItem {
        let pieces = configuration.chunker.chunks(text)
        let now = Date()
        let document = MemoryItem(
            kind: .document, title: title, text: text, tags: tags, source: source,
            metadata: ["chunks": .number(Double(pieces.count)), "characters": .number(Double(text.count))],
            createdAt: now, updatedAt: now)
        let chunks: [MemoryItem] = pieces.enumerated().map { entry in
            MemoryItem(
                kind: .chunk, title: pieces.count > 1 ? "\(title) (\(entry.offset + 1)/\(pieces.count))" : title,
                text: entry.element, tags: tags, parentID: document.id, source: source,
                metadata: ["index": .number(Double(entry.offset)), "count": .number(Double(pieces.count))],
                createdAt: now, updatedAt: now)
        }
        try await save([document] + chunks)
        return document
    }

    /// Deletes an item; deleting a document also deletes its chunks.
    public func delete(id: UUID) async throws {
        let key = id.uuidString
        let targets: [SQLiteValue] = [.text(key), .text(key)]
        try database.transaction { connection -> Void in
            if keywordMode == .fts5 {
                try connection.execute(
                    "DELETE FROM items_fts WHERE rowid IN (SELECT rowid FROM items WHERE id = ? OR parentID = ?)", targets)
            }
            try connection.execute(
                "DELETE FROM embeddings WHERE itemID IN (SELECT id FROM items WHERE id = ? OR parentID = ?)", targets)
            try connection.execute("DELETE FROM items WHERE id = ? OR parentID = ?", targets)
        }
    }

    /// Embeds every item that has no vector from the current embedder (after an embedder change or failed saves).
    /// Returns the number of items embedded. Throws when the embedder fails.
    @discardableResult
    public func reindexEmbeddings() async throws -> Int {
        let modelID = embedder.id
        let pending: [MemoryItem] = try database.withConnection { connection -> [MemoryItem] in
            let statement = try connection.prepare(
                "SELECT \(Self.itemColumns) FROM items WHERE id NOT IN (SELECT itemID FROM embeddings WHERE model = ?) ORDER BY rowid")
            try statement.bind([.text(modelID)])
            var items: [MemoryItem] = []
            while try statement.step() {
                if let item = Self.readItem(statement) { items.append(item) }
            }
            return items
        }
        let batchSize = max(1, configuration.embeddingBatchSize)
        var embedded = 0
        var start = 0
        while start < pending.count {
            let end = min(start + batchSize, pending.count)
            let batch = Array(pending[start..<end])
            let vectors = try await embedder.embed(batch.map { embeddingText(for: $0) })
            guard vectors.count == batch.count else {
                throw ZError.decoding("\(modelID) returned \(vectors.count) embeddings for \(batch.count) texts")
            }
            let written = try database.transaction { connection -> Int in
                var count = 0
                for (item, vector) in zip(batch, vectors) where !vector.isEmpty {
                    let key = item.id.uuidString
                    try connection.execute("""
                        INSERT OR REPLACE INTO embeddings (itemID, model, dim, vector)
                        SELECT ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM items WHERE id = ?)
                        """, [.text(key), .text(modelID), .integer(Int64(vector.count)), .blob(VectorMath.encode(vector)),
                              .text(key)])
                    count += connection.changes > 0 ? 1 : 0
                }
                return count
            }
            embedded += written
            start = end
        }
        return embedded
    }

    // MARK: Reading

    public func get(id: UUID) async throws -> MemoryItem? {
        try database.withConnection { connection -> MemoryItem? in
            let statement = try connection.prepare("SELECT \(Self.itemColumns) FROM items WHERE id = ?")
            try statement.bind([.text(id.uuidString)])
            guard try statement.step() else { return nil }
            return Self.readItem(statement)
        }
    }

    /// Newest first (by `updatedAt`). `limit` ≤ 0 returns nothing.
    public func list(kind: MemoryKind?, limit: Int, offset: Int) async throws -> [MemoryItem] {
        guard limit > 0 else { return [] }
        var sql = "SELECT \(Self.itemColumns) FROM items"
        var bindings: [SQLiteValue] = []
        if let kind {
            sql += " WHERE kind = ?"
            bindings.append(.text(kind.rawValue))
        }
        sql += " ORDER BY updatedAt DESC, createdAt DESC, rowid DESC LIMIT ? OFFSET ?"
        bindings.append(.integer(Int64(limit)))
        bindings.append(.integer(Int64(max(0, offset))))
        let query = sql
        let values = bindings
        return try database.withConnection { connection -> [MemoryItem] in
            let statement = try connection.prepare(query)
            try statement.bind(values)
            var items: [MemoryItem] = []
            while try statement.step() {
                if let item = Self.readItem(statement) { items.append(item) }
            }
            return items
        }
    }

    /// A document's chunks in order.
    public func chunks(of documentID: UUID) async throws -> [MemoryItem] {
        try database.withConnection { connection -> [MemoryItem] in
            let statement = try connection.prepare(
                "SELECT \(Self.itemColumns) FROM items WHERE parentID = ? AND kind = ? ORDER BY rowid")
            try statement.bind([.text(documentID.uuidString), .text(MemoryKind.chunk.rawValue)])
            var items: [MemoryItem] = []
            while try statement.step() {
                if let item = Self.readItem(statement) { items.append(item) }
            }
            return items
        }
    }

    public func count(kind: MemoryKind?) async throws -> Int {
        let value: SQLiteValue
        if let kind {
            value = try database.scalar("SELECT count(*) FROM items WHERE kind = ?", [.text(kind.rawValue)])
        } else {
            value = try database.scalar("SELECT count(*) FROM items")
        }
        return value.intValue ?? 0
    }

    // MARK: Search

    public func search(_ query: String, kinds: [MemoryKind], limit: Int) async throws -> [MemoryHit] {
        let text = TextUtil.trimmed(query)
        guard limit > 0, !text.isEmpty else { return [] }
        let pool = max(limit * 4, configuration.candidatePoolSize)
        let names = Self.kindNames(kinds)
        // A failing embedder degrades search to keyword-only instead of failing it.
        let embedded: [[Float]]? = try? await embedder.embed([text])
        let queryVector: [Float]? = embedded?.first
        return try database.withConnection { connection -> [MemoryHit] in
            var vectorIDs: [String] = []
            if let queryVector {
                vectorIDs = try vectorRanking(connection, query: queryVector, kinds: names, limit: pool).map { $0.id }
            }
            let keywordIDs = try keywordRanking(connection, query: text, kinds: names, limit: pool).map { $0.id }
            let fused = Array(RankFusion.reciprocalRank([vectorIDs, keywordIDs], k: configuration.rrfK).prefix(limit))
            let items = try loadItems(connection, ids: fused.map { $0.id })
            return fused.compactMap { entry in items[entry.id].map { MemoryHit(item: $0, score: entry.score) } }
        }
    }

    /// Keyword-only search. Scores: negated BM25 with FTS5, a match-count score with LIKE (higher is better).
    public func keywordSearch(_ query: String, kinds: [MemoryKind] = [], limit: Int = 10) async throws -> [MemoryHit] {
        let text = TextUtil.trimmed(query)
        guard limit > 0, !text.isEmpty else { return [] }
        let names = Self.kindNames(kinds)
        return try database.withConnection { connection -> [MemoryHit] in
            let ranked = try keywordRanking(connection, query: text, kinds: names, limit: limit)
            let items = try loadItems(connection, ids: ranked.map { $0.id })
            return ranked.compactMap { entry in items[entry.id].map { MemoryHit(item: $0, score: entry.score) } }
        }
    }

    /// Vector-only search; scores are cosine similarities. Embedder errors are thrown.
    public func vectorSearch(_ query: String, kinds: [MemoryKind] = [], limit: Int = 10) async throws -> [MemoryHit] {
        let text = TextUtil.trimmed(query)
        guard limit > 0, !text.isEmpty else { return [] }
        guard let vector = try await embedder.embed([text]).first else { return [] }
        return try vectorSearch(vector: vector, kinds: kinds, limit: limit)
    }

    /// Vector-only search with a precomputed query vector (from this store's embedder).
    public func vectorSearch(vector: [Float], kinds: [MemoryKind] = [], limit: Int = 10) throws -> [MemoryHit] {
        guard limit > 0 else { return [] }
        let names = Self.kindNames(kinds)
        return try database.withConnection { connection -> [MemoryHit] in
            let ranked = try vectorRanking(connection, query: vector, kinds: names, limit: limit)
            let items = try loadItems(connection, ids: ranked.map { $0.id })
            return ranked.compactMap { entry in items[entry.id].map { MemoryHit(item: $0, score: Double(entry.score)) } }
        }
    }

    private func vectorRanking(_ connection: SQLiteConnection, query: [Float], kinds: [String],
                               limit: Int) throws -> [(id: String, score: Float)] {
        let queryNorm = VectorMath.norm(query)
        guard queryNorm > 0, limit > 0 else { return [] }
        var sql = """
            SELECT e.itemID, e.vector FROM embeddings e JOIN items i ON i.id = e.itemID
            WHERE e.model = ? AND e.dim = ?
            """
        var bindings: [SQLiteValue] = [.text(embedder.id), .integer(Int64(query.count))]
        if !kinds.isEmpty {
            sql += " AND i.kind IN (\(Self.placeholders(kinds.count)))"
            bindings.append(contentsOf: kinds.map { SQLiteValue.text($0) })
        }
        let statement = try connection.prepare(sql)
        try statement.bind(bindings)
        let minimum = configuration.minimumSimilarity
        var scored: [(id: String, score: Float)] = []
        while try statement.step() {
            guard let id = statement.string(0) else { continue }
            let similarity = statement.withBlob(1) { VectorMath.cosine(query, queryNorm: queryNorm, blob: $0) }
            if let similarity, similarity.isFinite, similarity > minimum {
                scored.append((id: id, score: similarity))
            }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
        return Array(scored.prefix(limit))
    }

    private func keywordRanking(_ connection: SQLiteConnection, query: String, kinds: [String],
                                limit: Int) throws -> [(id: String, score: Double)] {
        let terms = TextTokenizer.queryTerms(query)
        guard !terms.isEmpty, limit > 0 else { return [] }
        if keywordMode == .fts5, let ranked = try? ftsRanking(connection, terms: terms, kinds: kinds, limit: limit) {
            return ranked
        }
        return try likeRanking(connection, terms: terms, kinds: kinds, limit: limit)
    }

    private func ftsRanking(_ connection: SQLiteConnection, terms: [String], kinds: [String],
                            limit: Int) throws -> [(id: String, score: Double)] {
        // Terms are letters/digits only, so quoting them is enough to keep FTS5 syntax out.
        let match = terms.map { "\"\($0)\"" }.joined(separator: " OR ")
        var sql = """
            SELECT items.id, bm25(items_fts, 3.0, 1.0, 2.0) AS score
            FROM items_fts JOIN items ON items.rowid = items_fts.rowid
            WHERE items_fts MATCH ?
            """
        var bindings: [SQLiteValue] = [.text(match)]
        if !kinds.isEmpty {
            sql += " AND items.kind IN (\(Self.placeholders(kinds.count)))"
            bindings.append(contentsOf: kinds.map { SQLiteValue.text($0) })
        }
        sql += " ORDER BY score ASC, items.updatedAt DESC LIMIT ?"
        bindings.append(.integer(Int64(limit)))
        let statement = try connection.prepare(sql)
        try statement.bind(bindings)
        var ranked: [(id: String, score: Double)] = []
        while try statement.step() {
            if let id = statement.string(0) { ranked.append((id: id, score: -statement.double(1))) }
        }
        return ranked
    }

    private func likeRanking(_ connection: SQLiteConnection, terms: [String], kinds: [String],
                             limit: Int) throws -> [(id: String, score: Double)] {
        let clause = terms.map { _ in "(title LIKE ? OR text LIKE ? OR tags LIKE ?)" }.joined(separator: " OR ")
        var bindings: [SQLiteValue] = terms.flatMap { term -> [SQLiteValue] in
            let pattern = "%\(term)%"
            return [.text(pattern), .text(pattern), .text(pattern)]
        }
        var sql = "SELECT id, title, text, tags, updatedAt FROM items WHERE (\(clause))"
        if !kinds.isEmpty {
            sql += " AND kind IN (\(Self.placeholders(kinds.count)))"
            bindings.append(contentsOf: kinds.map { SQLiteValue.text($0) })
        }
        sql += " ORDER BY updatedAt DESC LIMIT ?"
        bindings.append(.integer(Int64(max(limit * 10, 500))))
        let statement = try connection.prepare(sql)
        try statement.bind(bindings)
        var scored: [(id: String, score: Double, updated: Double)] = []
        while try statement.step() {
            guard let id = statement.string(0) else { continue }
            let title = (statement.string(1) ?? "").lowercased()
            let body = (statement.string(2) ?? "").lowercased()
            let tags = (statement.string(3) ?? "").lowercased()
            var matched = 0
            var weight = 0.0
            for term in terms {
                let inTitle = title.contains(term)
                let inTags = tags.contains(term)
                let occurrences = Self.occurrences(of: term, in: body)
                guard inTitle || inTags || occurrences > 0 else { continue }
                matched += 1
                if inTitle { weight += 3 }
                if inTags { weight += 2 }
                if occurrences > 0 { weight += 1 + log(Double(occurrences)) }
            }
            guard matched > 0 else { continue }
            scored.append((id: id, score: Double(matched) * 10 + weight, updated: statement.double(4)))
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.updated != b.updated { return a.updated > b.updated }
            return a.id < b.id
        }
        return scored.prefix(limit).map { (id: $0.id, score: $0.score) }
    }

    static func occurrences(of term: String, in text: String) -> Int {
        guard !term.isEmpty else { return 0 }
        var count = 0
        var searchRange = text.startIndex..<text.endIndex
        while count < 50, let found = text.range(of: term, range: searchRange) {
            count += 1
            searchRange = found.upperBound..<text.endIndex
        }
        return count
    }

    private func loadItems(_ connection: SQLiteConnection, ids: [String]) throws -> [String: MemoryItem] {
        guard !ids.isEmpty else { return [:] }
        let statement = try connection.prepare(
            "SELECT \(Self.itemColumns) FROM items WHERE id IN (\(Self.placeholders(ids.count)))")
        try statement.bind(ids.map { SQLiteValue.text($0) })
        var items: [String: MemoryItem] = [:]
        while try statement.step() {
            if let key = statement.string(0), let item = Self.readItem(statement) { items[key] = item }
        }
        return items
    }
}
