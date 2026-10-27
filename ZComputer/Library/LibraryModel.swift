import Foundation
import Observation
import ZCore
import ZMemory

/// An item being edited (new or existing).
struct MemoryDraft: Identifiable, Hashable {
    var id: UUID
    var isNew: Bool
    var kind: MemoryKind
    var title: String
    var text: String
    var tags: String
    var source: String
    var createdAt: Date

    init(item: MemoryItem) {
        id = item.id
        isNew = false
        kind = item.kind
        title = item.title
        text = item.text
        tags = item.tags.joined(separator: ", ")
        source = item.source
        createdAt = item.createdAt
    }

    init(kind: MemoryKind) {
        id = UUID()
        isNew = true
        self.kind = kind
        title = ""
        text = ""
        tags = ""
        source = "user"
        createdAt = Date()
    }

    var tagList: [String] {
        tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func makeItem() -> MemoryItem {
        MemoryItem(id: id, kind: kind, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                   text: text, tags: tagList, source: source, createdAt: createdAt, updatedAt: Date())
    }
}

/// The Library screen over ZMemory's `SQLiteMemoryStore`: list / hybrid search / kind filter, edit, delete, import.
@Observable
@MainActor
final class LibraryModel {
    /// Kinds the list offers (chunks are the searchable pieces of documents and stay hidden).
    static let listedKinds: [MemoryKind] = [.profile, .preference, .fact, .episode, .document]

    var query = ""
    var kindFilter: MemoryKind?
    var selection: UUID?
    var draft: MemoryDraft?

    private(set) var items: [MemoryItem] = []
    private(set) var scores: [UUID: Double] = [:]
    private(set) var counts: [MemoryKind: Int] = [:]
    private(set) var profile: [MemoryItem] = []
    private(set) var isBusy = false
    private(set) var importStatus: String?
    var errorMessage: String?

    let store: SQLiteMemoryStore?

    init(store: SQLiteMemoryStore?) {
        self.store = store
    }

    var isAvailable: Bool { store != nil }

    func item(_ id: UUID?) -> MemoryItem? {
        guard let id else { return nil }
        return items.first { $0.id == id } ?? profile.first { $0.id == id }
    }

    // MARK: Loading

    func reload() async {
        guard let store else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            var newCounts: [MemoryKind: Int] = [:]
            for kind in MemoryKind.allCases { newCounts[kind] = try await store.count(kind: kind) }
            counts = newCounts
            let profileItems = try await store.list(kind: .profile, limit: 200, offset: 0)
            let preferenceItems = try await store.list(kind: .preference, limit: 200, offset: 0)
            profile = profileItems + preferenceItems
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                scores = [:]
                if let kindFilter {
                    items = try await store.list(kind: kindFilter, limit: 500, offset: 0)
                } else {
                    var all: [MemoryItem] = []
                    for kind in Self.listedKinds { all += try await store.list(kind: kind, limit: 300, offset: 0) }
                    items = all.sorted { $0.updatedAt > $1.updatedAt }
                }
            } else {
                let kinds = kindFilter.map { [$0] } ?? Self.listedKinds + [.chunk]
                let hits = try await store.search(trimmed, kinds: kinds, limit: 60)
                scores = Dictionary(hits.map { ($0.item.id, $0.score) }, uniquingKeysWith: { a, _ in a })
                items = hits.map(\.item)
            }
        } catch {
            errorMessage = Format.describe(error)
        }
    }

    // MARK: Editing

    func newItem(kind: MemoryKind) {
        draft = MemoryDraft(kind: kind)
        selection = nil
    }

    func edit(_ item: MemoryItem) {
        draft = MemoryDraft(item: item)
    }

    func save(_ draft: MemoryDraft) async {
        guard let store else { return }
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Give the item a title or some text."
            return
        }
        do {
            try await store.save(draft.makeItem())
            self.draft = nil
            selection = draft.id
            await reload()
        } catch {
            errorMessage = Format.describe(error)
        }
    }

    func delete(_ id: UUID) async {
        guard let store else { return }
        do {
            try await store.delete(id: id)
            if selection == id { selection = nil }
            if draft?.id == id { draft = nil }
            await reload()
        } catch {
            errorMessage = Format.describe(error)
        }
    }

    // MARK: Import

    /// Imports txt / md / pdf files (URLs from the file importer, security scoped) as documents with chunks.
    func importFiles(_ urls: [URL]) async {
        guard let store else { return }
        isBusy = true
        defer { isBusy = false }
        var imported = 0
        var failures: [String] = []
        for url in urls {
            importStatus = "Importing \(url.lastPathComponent)…"
            do {
                let text = try await Task.detached(priority: .userInitiated) {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    return try DocumentTextExtractor.extractText(from: url)
                }.value
                _ = try await store.importDocument(title: DocumentTextExtractor.title(for: url), text: text,
                                                   source: "import:\(url.lastPathComponent)",
                                                   tags: [url.pathExtension.lowercased()])
                imported += 1
            } catch {
                failures.append("\(url.lastPathComponent): \(Format.describe(error))")
            }
        }
        importStatus = imported > 0 ? "Imported \(imported) file\(imported == 1 ? "" : "s")." : nil
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
        await reload()
    }
}
