import Foundation
import ZCore

/// Merges streamed tool-call fragments (OpenAI-style `tool_calls[].{index,id,function.{name,arguments}}` deltas,
/// Responses `function_call_arguments.delta`, Anthropic `input_json_delta`) into complete `ToolCall`s.
///
/// Fragments are matched by `index` when present, else by `id`, else they continue the most recent call. A fragment
/// whose `index` matches a call but carries a *different* non-empty id starts a new call (some servers reuse index 0
/// for parallel calls). Missing ids are synthesised.
public struct ToolCallAssembler: Sendable {
    private struct Partial: Sendable {
        var index: Int?
        var id: String
        var idWasSynthesised: Bool
        var name: String
        var arguments: String
        var started: Bool
        var emittedArgumentCount: Int
    }

    private var partials: [Partial] = []

    public init() {}

    public var isEmpty: Bool { partials.isEmpty }

    /// Feeds one fragment; returns the events to forward: `.toolCallStart` once the name is known, then
    /// `.toolCallDelta` for argument text.
    public mutating func ingest(index: Int?, id: String?, name: String?, argumentsDelta: String?) -> [StreamEvent] {
        let cleanID = id.flatMap { $0.isEmpty ? nil : $0 }
        let slot = findSlot(index: index, id: cleanID)
        var partial: Partial
        if let slot {
            partial = partials[slot]
        } else {
            partial = Partial(index: index, id: cleanID ?? Self.synthesizeID(), idWasSynthesised: cleanID == nil,
                              name: "", arguments: "", started: false, emittedArgumentCount: 0)
        }
        if let cleanID, partial.idWasSynthesised, !partial.started {
            partial.id = cleanID
            partial.idWasSynthesised = false
        }
        if let name, !name.isEmpty, partial.name.isEmpty { partial.name = name }
        if let argumentsDelta { partial.arguments += argumentsDelta }

        var events: [StreamEvent] = []
        if !partial.started, !partial.name.isEmpty {
            partial.started = true
            events.append(.toolCallStart(id: partial.id, name: partial.name))
        }
        let scalars = partial.arguments.unicodeScalars
        if partial.started, scalars.count > partial.emittedArgumentCount {
            var pending = String.UnicodeScalarView()
            pending.append(contentsOf: scalars.dropFirst(partial.emittedArgumentCount))
            partial.emittedArgumentCount = scalars.count
            events.append(.toolCallDelta(id: partial.id, argumentsDelta: String(pending)))
        }

        if let slot { partials[slot] = partial } else { partials.append(partial) }
        return events
    }

    /// Replaces a call's arguments with the authoritative final text (e.g. Responses `function_call_arguments.done`).
    public mutating func setArguments(index: Int?, id: String?, arguments: String) {
        if let slot = findSlot(index: index, id: id.flatMap { $0.isEmpty ? nil : $0 }) {
            partials[slot].arguments = arguments
            partials[slot].emittedArgumentCount = arguments.unicodeScalars.count
        }
    }

    /// The complete calls, in the order they started. Calls without a name are dropped.
    public mutating func finish() -> [ToolCall] {
        let calls = partials.filter { !$0.name.isEmpty }.map {
            ToolCall(id: $0.id, name: $0.name, arguments: Self.parseArguments($0.arguments))
        }
        partials.removeAll()
        return calls
    }

    private func findSlot(index: Int?, id: String?) -> Int? {
        if let index, let slot = partials.lastIndex(where: { $0.index == index }) {
            let existing = partials[slot]
            if let id, !existing.idWasSynthesised, existing.id != id {
                return partials.firstIndex { $0.id == id }
            }
            return slot
        }
        if let id { return partials.firstIndex { $0.id == id } }
        if index == nil, !partials.isEmpty { return partials.count - 1 }
        return nil
    }

    static func synthesizeID() -> String {
        "call_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24)).lowercased()
    }

    /// Parses tool arguments leniently: empty → `{}`, valid JSON → value (a JSON string holding an object is unwrapped
    /// once), invalid JSON → `.string(raw)` so the agent can report the problem to the model.
    public static func parseArguments(_ raw: String) -> JSONValue {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .object([:]) }
        guard let value = try? JSONValue.parse(trimmed) else { return .string(raw) }
        if case .string(let inner) = value, let nested = try? JSONValue.parse(inner), nested.objectValue != nil {
            return nested
        }
        return value
    }
}
