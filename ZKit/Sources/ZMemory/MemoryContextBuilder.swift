import Foundation
import ZCore

/// Builds the memory block injected into an agent's system prompt: who the user is (profile), how they want agents
/// to behave (preferences), then the memories most relevant to the task — compact, one line per item, and never
/// longer than `characterBudget` characters. Returns "" when there is nothing to say.
public struct MemoryContextBuilder: Sendable {
    public var characterBudget: Int
    /// Profile and preference items listed at most (each kind).
    public var maxPinnedItems: Int
    /// Longest single line before it is cut with "…".
    public var maxLineCharacters: Int
    /// Kinds searched for task-relevant hits (profile and preferences are always listed separately).
    public var hitKinds: [MemoryKind]

    /// Lines are only cut to fit the remaining budget when at least this much room is left.
    static let minimumLineCharacters = 24
    static let title = "## Memory (from the user's library; may be incomplete)"

    public init(characterBudget: Int = 4_000, maxPinnedItems: Int = 40, maxLineCharacters: Int = 500,
                hitKinds: [MemoryKind] = [.fact, .episode, .document, .chunk]) {
        self.characterBudget = characterBudget
        self.maxPinnedItems = maxPinnedItems
        self.maxLineCharacters = maxLineCharacters
        self.hitKinds = hitKinds
    }

    /// Convenience with the default settings.
    public static func contextBlock(for task: String, store: any MemoryStore, limit: Int = 8,
                                    characterBudget: Int = 4_000) async throws -> String {
        try await MemoryContextBuilder(characterBudget: characterBudget).contextBlock(for: task, store: store, limit: limit)
    }

    public func contextBlock(for task: String, store: any MemoryStore, limit: Int = 8) async throws -> String {
        guard characterBudget > 0 else { return "" }
        var profile: [MemoryItem] = []
        var preferences: [MemoryItem] = []
        if maxPinnedItems > 0 {
            profile = try await store.list(kind: .profile, limit: maxPinnedItems, offset: 0)
            preferences = try await store.list(kind: .preference, limit: maxPinnedItems, offset: 0)
        }
        var hits: [MemoryHit] = []
        let query = TextUtil.trimmed(task)
        if limit > 0, !query.isEmpty, !hitKinds.isEmpty {
            hits = try await store.search(query, kinds: hitKinds, limit: limit)
        }
        let sections: [(header: String, lines: [String])] = [
            (header: "About the user:", lines: profile.map { pinnedLine($0) }),
            (header: "User preferences:", lines: preferences.map { pinnedLine($0) }),
            (header: "Relevant memories (most relevant first):", lines: Self.deduplicated(hits).map { hitLine($0) }),
        ]
        return render(sections)
    }

    // MARK: Formatting

    func pinnedLine(_ item: MemoryItem) -> String {
        let title = TextUtil.oneLine(item.title)
        let text = TextUtil.compactLines(item.text)
        let body: String
        if title.isEmpty || text.lowercased().hasPrefix(title.lowercased()) {
            body = text.isEmpty ? title : text
        } else {
            body = text.isEmpty ? title : "\(title): \(text)"
        }
        return TextUtil.truncate("- \(body)", maxLineCharacters)
    }

    func hitLine(_ hit: MemoryHit) -> String {
        let item = hit.item
        let label: String
        switch item.kind {
        case .episode: label = "episode \(Self.day(item.createdAt))"
        case .chunk: label = "excerpt"
        default: label = item.kind.rawValue
        }
        let title = TextUtil.oneLine(item.title)
        let text = TextUtil.compactLines(item.text)
        let body = title.isEmpty ? text : (text.isEmpty ? title : "\(title): \(text)")
        return TextUtil.truncate("- [\(label)] \(body)", maxLineCharacters)
    }

    static func day(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: date)
    }

    /// Drops pinned kinds (already listed), repeated items, and documents whose own chunks are among the hits.
    static func deduplicated(_ hits: [MemoryHit]) -> [MemoryHit] {
        let chunkParents = Set(hits.compactMap { $0.item.kind == .chunk ? $0.item.parentID : nil })
        var seen = Set<UUID>()
        return hits.filter { hit in
            let kind = hit.item.kind
            if kind == .profile || kind == .preference { return false }
            if kind == .document, chunkParents.contains(hit.item.id) { return false }
            return seen.insert(hit.item.id).inserted
        }
    }

    /// Lays sections out in order until the budget runs out. A section header is only written when at least part
    /// of its first line fits; the last line that does not fit is cut to the remaining room.
    func render(_ sections: [(header: String, lines: [String])]) -> String {
        let budget = characterBudget
        guard budget > 0, sections.contains(where: { !$0.lines.isEmpty }) else { return "" }
        // The title is dropped when it would leave no room for any content.
        let withTitle = layout(sections, budget: budget, title: Self.title)
        if !withTitle.isEmpty { return withTitle }
        return layout(sections, budget: budget, title: nil)
    }

    private func layout(_ sections: [(header: String, lines: [String])], budget: Int, title: String?) -> String {
        var output: [String] = []
        var used = 0
        var contentLines = 0
        func cost(_ line: String) -> Int { line.count + (output.isEmpty ? 0 : 1) }
        func add(_ line: String) -> Bool {
            let lineCost = cost(line)
            guard used + lineCost <= budget else { return false }
            output.append(line)
            used += lineCost
            return true
        }
        if let title { _ = add(title) }
        sectionLoop: for section in sections where !section.lines.isEmpty {
            let roomForFirstLine = budget - used - cost(section.header) - 1
            if roomForFirstLine < Self.minimumLineCharacters { break }
            _ = add(section.header)
            for line in section.lines {
                if add(line) {
                    contentLines += 1
                    continue
                }
                let remaining = budget - used - 1
                if remaining >= Self.minimumLineCharacters, add(TextUtil.truncate(line, remaining)) {
                    contentLines += 1
                }
                break sectionLoop
            }
        }
        return contentLines > 0 ? output.joined(separator: "\n") : ""
    }
}
