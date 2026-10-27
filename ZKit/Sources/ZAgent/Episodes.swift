import Foundation
import ZCore

/// One finished run, handed to an `EpisodeSink` (ZMemory's `EpisodeRecorder` plugs in here).
public struct AgentEpisode: Sendable, Hashable {
    public var agentID: String
    public var agentName: String
    public var model: ModelRef
    public var task: String
    public var transcript: [ChatMessage]
    public var outcome: AgentOutcome
    public var startedAt: Date
    public var endedAt: Date

    public init(agentID: String, agentName: String, model: ModelRef, task: String, transcript: [ChatMessage],
                outcome: AgentOutcome, startedAt: Date, endedAt: Date) {
        self.agentID = agentID; self.agentName = agentName; self.model = model; self.task = task
        self.transcript = transcript; self.outcome = outcome; self.startedAt = startedAt; self.endedAt = endedAt
    }

    /// Names of the tools used, in first-use order.
    public var toolsUsed: [String] {
        var seen: [String] = []
        for m in transcript { for c in m.toolCalls where !seen.contains(c.name) { seen.append(c.name) } }
        return seen
    }
}

/// Receives finished runs.
public protocol EpisodeSink: Sendable {
    func record(_ episode: AgentEpisode) async throws
}

/// Adapts a closure (e.g. `{ try await recorder.record(task: $0.task, transcript: $0.transcript, outcome: $0.outcome) }`).
public struct ClosureEpisodeSink: EpisodeSink {
    private let body: @Sendable (AgentEpisode) async throws -> Void
    public init(_ body: @escaping @Sendable (AgentEpisode) async throws -> Void) { self.body = body }
    public func record(_ episode: AgentEpisode) async throws { try await body(episode) }
}

/// Stores a plain (non-LLM) episode summary in a `MemoryStore`. ZMemory's recorder writes better summaries.
public struct MemoryEpisodeSink: EpisodeSink {
    public let store: any MemoryStore
    public init(store: any MemoryStore) { self.store = store }

    public func record(_ episode: AgentEpisode) async throws {
        let o = episode.outcome
        let tools = episode.toolsUsed
        let text = """
        Task: \(episode.task)
        Result: \(o.success ? "succeeded" : "did not succeed") after \(o.steps) steps.
        Summary: \(o.summary)
        Tools used: \(tools.isEmpty ? "none" : tools.joined(separator: ", "))
        Agent: \(episode.agentName) (\(episode.model.description))
        """
        let item = MemoryItem(kind: .episode, title: String(episode.task.prefix(80)), text: text,
                              tags: o.success ? ["success"] : ["failed"], source: "agent:\(episode.agentName)",
                              metadata: ["agentID": .string(episode.agentID), "steps": .number(Double(o.steps)),
                                         "model": .string(episode.model.description)])
        try await store.save(item)
    }
}

/// Builds the "what you remember" block of the system prompt. ZMemory's `MemoryContextBuilder` can conform.
public protocol MemoryContextProvider: Sendable {
    func contextBlock(for task: String, store: any MemoryStore) async -> String?
}

/// Profile + preferences + the top search hits for the task, straight from the `MemoryStore`.
public struct DefaultMemoryContextProvider: MemoryContextProvider {
    public var hitLimit: Int
    public var profileLimit: Int
    public var snippetLength: Int

    public init(hitLimit: Int = 6, profileLimit: Int = 20, snippetLength: Int = 400) {
        self.hitLimit = hitLimit; self.profileLimit = profileLimit; self.snippetLength = snippetLength
    }

    public func contextBlock(for task: String, store: any MemoryStore) async -> String? {
        let profile = (try? await store.list(kind: .profile, limit: profileLimit, offset: 0)) ?? []
        let prefs = (try? await store.list(kind: .preference, limit: profileLimit, offset: 0)) ?? []
        let hits = (try? await store.search(task, kinds: [.fact, .episode, .chunk, .document], limit: hitLimit)) ?? []
        var sections: [String] = []
        if !profile.isEmpty { sections.append("About the user:\n" + profile.map { "- " + line($0) }.joined(separator: "\n")) }
        if !prefs.isEmpty { sections.append("Preferences:\n" + prefs.map { "- " + line($0) }.joined(separator: "\n")) }
        if !hits.isEmpty {
            sections.append("Possibly relevant:\n" + hits.map { "- [\($0.item.kind.rawValue)] " + line($0.item) }.joined(separator: "\n"))
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    private func line(_ item: MemoryItem) -> String {
        let text = item.text.replacingOccurrences(of: "\n", with: " ")
        let snippet = text.count > snippetLength ? String(text.prefix(snippetLength)) + "…" : text
        if item.title.isEmpty || text.hasPrefix(item.title) { return snippet }
        return "\(item.title): \(snippet)"
    }
}
