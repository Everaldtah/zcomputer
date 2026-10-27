import Foundation
import ZCore

/// memory_search / memory_save / memory_list over the personal library (`MemoryStore`).
public struct MemoryTool: Tool {
    public enum Operation: String, Sendable, CaseIterable, Hashable {
        case search = "memory_search"
        case save = "memory_save"
        case list = "memory_list"
    }

    public let operation: Operation
    /// Characters of each item's text shown in search / list results.
    public var snippetLength: Int

    public init(_ operation: Operation, snippetLength: Int = 500) {
        self.operation = operation
        self.snippetLength = snippetLength
    }

    public static var all: [any Tool] { Operation.allCases.map { MemoryTool($0) } }

    /// Kinds the agent may save. Episodes, documents and chunks are written by the app.
    public static let savableKinds: [MemoryKind] = [.fact, .preference, .profile]

    public var spec: ToolSpec {
        let kinds = MemoryKind.allCases.map(\.rawValue)
        switch operation {
        case .search:
            return ToolSpec(name: operation.rawValue,
                            description: "Search the user's personal library (profile, preferences, facts, past tasks, imported documents).",
                            parameters: Schema.object([
                                "query": Schema.string("What to look for."),
                                "kinds": Schema.array(of: Schema.string("Kind", oneOf: kinds), "Restrict to these kinds (default: all)."),
                                "limit": Schema.integer("Maximum results (default 5, max 20)."),
                            ], required: ["query"]))
        case .save:
            return ToolSpec(name: operation.rawValue,
                            description: "Save a durable fact or preference worth remembering in future tasks. Do not save secrets.",
                            parameters: Schema.object([
                                "text": Schema.string("The fact, stated on its own so it makes sense later."),
                                "title": Schema.string("Short title (optional)."),
                                "kind": Schema.string("fact (default), preference or profile.", oneOf: Self.savableKinds.map(\.rawValue)),
                                "tags": Schema.array(of: Schema.string("Tag"), "Optional tags."),
                            ], required: ["text"]))
        case .list:
            return ToolSpec(name: operation.rawValue,
                            description: "List recent items in the user's library, optionally of one kind.",
                            parameters: Schema.object([
                                "kind": Schema.string("Only this kind.", oneOf: kinds),
                                "limit": Schema.integer("Maximum results (default 20, max 100)."),
                                "offset": Schema.integer("Skip this many (paging)."),
                            ]))
        }
    }

    public func risk(of call: ToolCall) -> ToolRisk {
        operation == .save ? .normal(operation.rawValue) : .readOnly(operation.rawValue)
    }

    public func invoke(_ call: ToolCall, ctx: ToolContext) async throws -> ToolResult {
        let store = try ctx.requireMemory(for: operation.rawValue)
        let args = ToolArguments(call)
        switch operation {
        case .search:
            guard let query = args.string(["query", "q", "text"]), !query.isEmpty else {
                throw ZError.invalidArgument("memory_search needs a 'query'.")
            }
            let kinds = (args.stringArray("kinds") ?? []).compactMap { MemoryKind(rawValue: $0.lowercased()) }
            let limit = min(max(args.int("limit") ?? 5, 1), 20)
            let hits = try await store.search(query, kinds: kinds, limit: limit)
            if hits.isEmpty { return ToolResult(callID: call.id, text: "No memories match \"\(query)\".") }
            let lines = hits.enumerated().map { i, hit in
                "\(i + 1). " + describe(hit.item) + String(format: " (score %.2f)", hit.score)
            }
            return ToolResult(callID: call.id, text: lines.joined(separator: "\n"))

        case .save:
            guard let text = args.string(["text", "content", "fact"])?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                throw ZError.invalidArgument("memory_save needs a non-empty 'text'.")
            }
            let kind = args.string("kind").flatMap { MemoryKind(rawValue: $0.lowercased()) } ?? .fact
            guard Self.savableKinds.contains(kind) else {
                throw ZError.invalidArgument("memory_save can store kinds: \(Self.savableKinds.map(\.rawValue).joined(separator: ", ")).")
            }
            let title = args.string("title").flatMap { $0.isEmpty ? nil : $0 } ?? String(text.prefix(60))
            let item = MemoryItem(kind: kind, title: title, text: text, tags: args.stringArray("tags") ?? [],
                                  source: "agent:\(ctx.agentName)", metadata: ["agentID": .string(ctx.agentID)])
            try await store.save(item)
            return ToolResult(callID: call.id, text: "Saved \(kind.rawValue) \"\(title)\" (id \(item.id.uuidString)).")

        case .list:
            let kind = args.string("kind").flatMap { MemoryKind(rawValue: $0.lowercased()) }
            let limit = min(max(args.int("limit") ?? 20, 1), 100)
            let offset = max(args.int("offset") ?? 0, 0)
            let items = try await store.list(kind: kind, limit: limit, offset: offset)
            if items.isEmpty { return ToolResult(callID: call.id, text: "The library has no \(kind.map { "\($0.rawValue) " } ?? "")items here.") }
            let lines = items.enumerated().map { i, item in "\(offset + i + 1). " + describe(item) }
            return ToolResult(callID: call.id, text: lines.joined(separator: "\n"))
        }
    }

    private func describe(_ item: MemoryItem) -> String {
        let text = item.text.replacingOccurrences(of: "\n", with: " ")
        let snippet = text.count > snippetLength ? String(text.prefix(snippetLength)) + "…" : text
        let tags = item.tags.isEmpty ? "" : " #" + item.tags.joined(separator: " #")
        return "[\(item.kind.rawValue)] \(item.title)\(tags): \(snippet)"
    }
}
