import Foundation
import XCTest
import ZCore
@testable import ZMemory

final class SQLiteMemoryStoreTests: XCTestCase {
    // MARK: CRUD

    func testSaveGetRoundTripsEveryField() async throws {
        let store = try makeStore()
        let parent = UUID()
        let item = MemoryItem(
            kind: .fact, title: "Shell", text: "zsh is the default shell on the VM", tags: ["env", "shell"],
            parentID: parent, source: "agent:test", metadata: ["os": "linux", "verified": true, "nested": ["a": "b"]],
            createdAt: Date(timeIntervalSinceReferenceDate: 700_000_000.123456), updatedAt: Date())
        try await store.save(item)
        let loaded = try await store.get(id: item.id)
        XCTAssertEqual(loaded, item)
        let missing = try await store.get(id: UUID())
        XCTAssertNil(missing)
    }

    func testUpdateReplacesTextAndKeywordIndex() async throws {
        for preferFTS5 in [true, false] {
            let store = try makeStore(preferFTS5: preferFTS5)
            var item = MemoryItem(kind: .fact, title: "Shell", text: "zsh is the default shell")
            try await store.save(item)
            item.text = "fish is the default shell"
            item.updatedAt = Date()
            try await store.save(item)

            let loaded = try await store.get(id: item.id)
            XCTAssertEqual(loaded?.text, "fish is the default shell")
            let total = try await store.count(kind: nil)
            XCTAssertEqual(total, 1)
            let fish = try await store.keywordSearch("fish", kinds: [], limit: 5)
            XCTAssertEqual(fish.map(\.item.id), [item.id], "mode \(store.keywordMode)")
            let zsh = try await store.keywordSearch("zsh", kinds: [], limit: 5)
            XCTAssertTrue(zsh.isEmpty, "stale keyword index in mode \(store.keywordMode)")
            let vectors = try store.database.scalar("SELECT count(*) FROM embeddings")
            XCTAssertEqual(vectors, .integer(1))
        }
    }

    func testDeleteRemovesItemVectorAndIndex() async throws {
        let store = try makeStore()
        let keep = MemoryItem(kind: .fact, title: "Editor", text: "The user edits with neovim")
        let gone = MemoryItem(kind: .fact, title: "Browser", text: "The user browses with firefox")
        try await store.save(keep)
        try await store.save(gone)
        try await store.delete(id: gone.id)

        let deleted = try await store.get(id: gone.id)
        XCTAssertNil(deleted)
        let remaining = try await store.count(kind: .fact)
        XCTAssertEqual(remaining, 1)
        let hits = try await store.search("firefox", kinds: [], limit: 5)
        XCTAssertFalse(hits.contains { $0.item.id == gone.id })
        XCTAssertEqual(try store.database.scalar("SELECT count(*) FROM embeddings"), .integer(1))
        if store.usesFTS5 {
            XCTAssertEqual(try store.database.scalar("SELECT count(*) FROM items_fts"), .integer(1))
        }
        try await store.delete(id: UUID())  // deleting a missing id is a no-op
    }

    func testListOrdersNewestFirstWithPagingAndKinds() async throws {
        let store = try makeStore()
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var facts: [MemoryItem] = []
        for n in 0..<5 {
            let date = base.addingTimeInterval(Double(n) * 60)
            let item = MemoryItem(kind: .fact, title: "Fact \(n)", text: "text \(n)", createdAt: date, updatedAt: date)
            facts.append(item)
            try await store.save(item)
        }
        try await store.save(MemoryItem(kind: .profile, title: "Name", text: "Everald"))

        let firstPage = try await store.list(kind: .fact, limit: 2, offset: 0)
        XCTAssertEqual(firstPage.map(\.title), ["Fact 4", "Fact 3"])
        let secondPage = try await store.list(kind: .fact, limit: 2, offset: 2)
        XCTAssertEqual(secondPage.map(\.title), ["Fact 2", "Fact 1"])
        let everything = try await store.list(kind: nil, limit: 100, offset: 0)
        XCTAssertEqual(everything.count, 6)
        let none = try await store.list(kind: .fact, limit: 0, offset: 0)
        XCTAssertTrue(none.isEmpty)

        let factCount = try await store.count(kind: .fact)
        let profileCount = try await store.count(kind: .profile)
        let episodeCount = try await store.count(kind: .episode)
        let total = try await store.count(kind: nil)
        XCTAssertEqual([factCount, profileCount, episodeCount, total], [5, 1, 0, 6])
    }

    // MARK: Keyword search

    func testFTSKeywordSearch() async throws {
        let store = try makeStore()
        #if os(Linux)
        XCTAssertTrue(store.usesFTS5, "Ubuntu's libsqlite3 is built with FTS5 (SQLite \(SQLiteDatabase.libraryVersion))")
        #endif
        try XCTSkipUnless(store.usesFTS5, "FTS5 is not compiled into this SQLite")
        let rust = MemoryItem(kind: .fact, title: "Rust setup", text: "Install the Rust toolchain with rustup, then cargo build.")
        let proxy = MemoryItem(kind: .fact, title: "Network", text: "Configure the proxy before running apt.")
        let bread = MemoryItem(kind: .episode, title: "Banana bread", text: "Baked banana bread for the user.", tags: ["cooking"])
        for item in [rust, proxy, bread] { try await store.save(item) }

        let rustHits = try await store.keywordSearch("rustup toolchain", kinds: [], limit: 5)
        XCTAssertEqual(rustHits.first?.item.id, rust.id)
        XCTAssertEqual(rustHits.count, 1)
        // Porter stemming: "configuring proxies" matches "Configure the proxy".
        let stemmed = try await store.keywordSearch("configuring proxies", kinds: [], limit: 5)
        XCTAssertEqual(stemmed.first?.item.id, proxy.id)
        // Tags are indexed.
        let tagged = try await store.keywordSearch("cooking", kinds: [], limit: 5)
        XCTAssertEqual(tagged.first?.item.id, bread.id)
        // Quotes and FTS operators in the query are harmless.
        let odd = try await store.keywordSearch("\"rustup\" AND (NOT* -cargo", kinds: [], limit: 5)
        XCTAssertEqual(odd.first?.item.id, rust.id)
    }

    func testLikeFallbackKeywordSearch() async throws {
        let store = try makeStore(preferFTS5: false)
        XCTAssertEqual(store.keywordMode, .like)
        let rust = MemoryItem(kind: .fact, title: "Rust setup", text: "Install the Rust toolchain with rustup.")
        let bread = MemoryItem(kind: .episode, title: "Banana bread", text: "Baked banana bread.", tags: ["cooking"])
        let both = MemoryItem(kind: .fact, title: "Notes", text: "rustup came up while baking banana bread")
        for item in [rust, bread, both] { try await store.save(item) }

        let hits = try await store.keywordSearch("RUSTUP toolchain", kinds: [], limit: 5)
        XCTAssertEqual(hits.first?.item.id, rust.id, "matching both terms beats matching one")
        XCTAssertEqual(Set(hits.map(\.item.id)), [rust.id, both.id])
        let tagged = try await store.keywordSearch("cooking", kinds: [], limit: 5)
        XCTAssertEqual(tagged.map(\.item.id), [bread.id])
        let episodesOnly = try await store.keywordSearch("banana", kinds: [.episode], limit: 5)
        XCTAssertEqual(episodesOnly.map(\.item.id), [bread.id])
    }

    func testSearchHonoursKinds() async throws {
        let store = try makeStore()
        let fact = MemoryItem(kind: .fact, title: "Tool", text: "rustup manages Rust toolchains")
        let episode = MemoryItem(kind: .episode, title: "Episode: install rust", text: "Installed rustup and cargo")
        try await store.save(fact)
        try await store.save(episode)
        let onlyEpisodes = try await store.search("rustup", kinds: [.episode], limit: 5)
        XCTAssertEqual(onlyEpisodes.map(\.item.id), [episode.id])
        let all = try await store.search("rustup", kinds: [], limit: 5)
        XCTAssertEqual(Set(all.map(\.item.id)), [fact.id, episode.id])
        let empty = try await store.search("   ", kinds: [], limit: 5)
        XCTAssertTrue(empty.isEmpty)
        let zero = try await store.search("rustup", kinds: [], limit: 0)
        XCTAssertTrue(zero.isEmpty)
    }

    // MARK: Vector + hybrid search

    func testEmbeddingSearchRanksTheRightItemFirst() async throws {
        let store = try makeStore(embedder: HashingEmbedder())
        let rust = MemoryItem(kind: .fact, title: "Rust setup", text: "Install the Rust toolchain with rustup, then run cargo build.")
        let bread = MemoryItem(kind: .fact, title: "Banana bread", text: "Mash three ripe bananas, mix with flour and bake for an hour.")
        let report = MemoryItem(kind: .fact, title: "Quarterly report", text: "Revenue grew twelve percent in Europe this quarter.")
        for item in [bread, report, rust] { try await store.save(item) }

        let vectorHits = try await store.vectorSearch("how do I install the rust compiler", kinds: [], limit: 3)
        XCTAssertEqual(vectorHits.first?.item.id, rust.id)
        let scores = vectorHits.map(\.score)
        XCTAssertEqual(scores, scores.sorted(by: >), "cosine scores are in descending order")
        let hybrid = try await store.search("how do I install the rust compiler", kinds: [], limit: 3)
        XCTAssertEqual(hybrid.first?.item.id, rust.id)
    }

    func testVectorSearchFindsItemWithoutSharedWords() async throws {
        let store = try makeStore(embedder: ConceptEmbedder())
        let fruit = MemoryItem(kind: .fact, title: "Smoothie", text: "blend mango and banana with yogurt")
        let car = MemoryItem(kind: .fact, title: "Service", text: "the engine needs oil and a wheel alignment")
        let music = MemoryItem(kind: .fact, title: "Lessons", text: "piano practice every evening, learn a melody")
        for item in [fruit, car, music] { try await store.save(item) }

        let keyword = try await store.keywordSearch("guitar", kinds: [], limit: 5)
        XCTAssertTrue(keyword.isEmpty)
        let vector = try await store.vectorSearch("guitar", kinds: [], limit: 5)
        XCTAssertEqual(vector.map(\.item.id), [music.id])
        XCTAssertEqual(vector.first?.score ?? 0, 1, accuracy: 1e-5)
        let hybrid = try await store.search("guitar", kinds: [], limit: 5)
        XCTAssertEqual(hybrid.map(\.item.id), [music.id])
    }

    func testHybridSearchFusesVectorAndKeywordHits() async throws {
        let store = try makeStore(embedder: ConceptEmbedder())
        let garage = MemoryItem(kind: .fact, title: "Garage visit", text: "took the car to the garage")
        let tyre = MemoryItem(kind: .fact, title: "Tyre pressure", text: "check tyre pressure monthly")
        let stall = MemoryItem(kind: .fact, title: "Fruit stall", text: "the garage stall sells mango")
        let lyrics = MemoryItem(kind: .fact, title: "Lyrics", text: "zyxquux chorus draft")
        for item in [garage, stall, lyrics, tyre] { try await store.save(item) }

        // "tyre": vector hits = garage, tyre (cos 1), stall (cos 0.45); keyword hit = tyre only.
        let hits = try await store.search("tyre", kinds: [], limit: 10)
        XCTAssertEqual(hits.first?.item.id, tyre.id, "in both rankings, so fused first")
        XCTAssertEqual(Set(hits.map(\.item.id)), [tyre.id, garage.id, stall.id], "union of both rankings")
        XCTAssertEqual(hits.last?.item.id, stall.id)
        let scores = hits.map(\.score)
        XCTAssertEqual(scores, scores.sorted(by: >))

        // A keyword-only hit (its vector is all zeros) still comes back.
        let keywordOnly = try await store.search("zyxquux", kinds: [], limit: 10)
        XCTAssertEqual(keywordOnly.map(\.item.id), [lyrics.id])
    }

    func testReciprocalRankFusion() {
        let fused = RankFusion.reciprocalRank([["a", "b", "c"], ["c", "a", "d"]], k: 60)
        XCTAssertEqual(fused.map { $0.id }, ["a", "c", "b", "d"])
        XCTAssertEqual(fused[0].score, 1 / 61.0 + 1 / 62.0, accuracy: 1e-12)
        XCTAssertEqual(fused[1].score, 1 / 63.0 + 1 / 61.0, accuracy: 1e-12)
        XCTAssertEqual(fused[2].score, 1 / 62.0, accuracy: 1e-12)
        // Duplicates inside one ranking count once.
        let duplicates = RankFusion.reciprocalRank([["x", "x", "y"], ["y"]], k: 1)
        XCTAssertEqual(duplicates.map { $0.id }, ["y", "x"])
        XCTAssertEqual(duplicates[1].score, 0.5, accuracy: 1e-12)
        // Equal scores: the item with the better single rank wins.
        let tie = RankFusion.reciprocalRank([["p", "q"], ["q", "p"]], k: 60)
        XCTAssertEqual(tie.map { $0.id }, ["p", "q"])
        XCTAssertTrue(RankFusion.reciprocalRank([[String]](), k: 60).isEmpty)
    }

    // MARK: Documents

    func testImportDocumentStoresSearchableChunks() async throws {
        let store = try makeStore(chunker: Chunker(targetTokens: 50, overlapTokens: 10))
        let paragraphs = (1...10).map { n in
            n == 7
                ? "Paragraph \(n) mentions the kumquat harvest, which is the one detail that matters here."
                : "Paragraph \(n) is filler text about nothing in particular, just enough to fill a chunk."
        }
        let text = paragraphs.joined(separator: "\n\n")
        let document = try await store.importDocument(title: "Garden log", text: text, source: "import:/tmp/garden.txt", tags: ["garden"])

        XCTAssertEqual(document.kind, .document)
        XCTAssertEqual(document.text, text)
        let chunks = try await store.chunks(of: document.id)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.parentID == document.id && $0.kind == .chunk && $0.tags == ["garden"] })
        XCTAssertTrue(chunks.allSatisfy { $0.text.count <= 200 })
        XCTAssertEqual(chunks.first?.title, "Garden log (1/\(chunks.count))")
        let chunkCount = try await store.count(kind: .chunk)
        XCTAssertEqual(chunkCount, chunks.count)

        let hits = try await store.keywordSearch("kumquat", kinds: [.chunk], limit: 3)
        XCTAssertTrue(hits.first?.item.text.contains("kumquat") ?? false)
        let hybrid = try await store.search("kumquat harvest", kinds: [.chunk], limit: 3)
        XCTAssertTrue(hybrid.first?.item.text.contains("kumquat") ?? false)

        try await store.delete(id: document.id)
        let chunksLeft = try await store.count(kind: .chunk)
        let documentsLeft = try await store.count(kind: .document)
        XCTAssertEqual(chunksLeft, 0)
        XCTAssertEqual(documentsLeft, 0)
        XCTAssertEqual(try store.database.scalar("SELECT count(*) FROM embeddings"), .integer(0))
    }

    // MARK: Embedder failures and reindexing

    func testEmbedderFailureDoesNotBlockSavingOrSearch() async throws {
        let store = try makeStore(embedder: FailingEmbedder())
        let item = MemoryItem(kind: .fact, title: "Shell", text: "zsh is the default shell")
        try await store.save(item)
        let loaded = try await store.get(id: item.id)
        XCTAssertEqual(loaded, item)
        XCTAssertEqual(try store.database.scalar("SELECT count(*) FROM embeddings"), .integer(0))
        let hits = try await store.search("zsh shell", kinds: [], limit: 5)
        XCTAssertEqual(hits.map(\.item.id), [item.id], "hybrid search degrades to keyword-only")
        do {
            _ = try await store.vectorSearch("zsh", kinds: [], limit: 5)
            XCTFail("vectorSearch should surface the embedder error")
        } catch {
            XCTAssertEqual(error as? ZError, .network("embedding service offline"))
        }
    }

    func testReindexEmbeddingsAfterSwitchingEmbedder() async throws {
        let database = try SQLiteDatabase()
        let offline = try SQLiteMemoryStore(database: database, embedder: FailingEmbedder())
        let rust = MemoryItem(kind: .fact, title: "Rust setup", text: "Install the Rust toolchain with rustup")
        let bread = MemoryItem(kind: .fact, title: "Banana bread", text: "Mash ripe bananas and bake")
        try await offline.save(rust)
        try await offline.save(bread)

        let online = try SQLiteMemoryStore(database: database, embedder: HashingEmbedder())
        let before = try await online.vectorSearch("rust toolchain", kinds: [], limit: 5)
        XCTAssertTrue(before.isEmpty)
        let embedded = try await online.reindexEmbeddings()
        XCTAssertEqual(embedded, 2)
        let again = try await online.reindexEmbeddings()
        XCTAssertEqual(again, 0, "nothing left to embed")
        let after = try await online.vectorSearch("rust toolchain", kinds: [], limit: 5)
        XCTAssertEqual(after.first?.item.id, rust.id)
    }

    // MARK: Persistence

    func testFileBackedStorePersists() async throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("nested/memory.sqlite").path
        let item = MemoryItem(kind: .preference, title: "Tone", text: "Prefers short answers")
        do {
            let store = try SQLiteMemoryStore(path: path)
            try await store.save(item)
            store.database.close()
        }
        let reopened = try SQLiteMemoryStore(path: path)
        let loaded = try await reopened.get(id: item.id)
        XCTAssertEqual(loaded, item)
        let hits = try await reopened.search("short answers", kinds: [], limit: 3)
        XCTAssertEqual(hits.first?.item.id, item.id)
    }

    func testFTSIndexIsBackfilledForRowsWrittenWithoutIt() async throws {
        let database = try SQLiteDatabase()
        let likeStore = try SQLiteMemoryStore(database: database, configuration: .init(preferFTS5: false))
        let item = MemoryItem(kind: .fact, title: "Editor", text: "The user edits with helix")
        try await likeStore.save(item)
        let ftsStore = try SQLiteMemoryStore(database: database)
        try XCTSkipUnless(ftsStore.usesFTS5, "FTS5 is not compiled into this SQLite")
        let hits = try await ftsStore.keywordSearch("helix", kinds: [], limit: 3)
        XCTAssertEqual(hits.map(\.item.id), [item.id])
    }
}
