import Foundation

/// Quirk names used in `providers.json` (see docs/research/providers.md, "Quirk vocabulary") plus the ones the clients
/// understand for user-added providers. A quirk is either a bare flag (`"noTools"`) or `name:value`
/// (`"maxImagesPerRequest:3"`, `"noParallelToolCalls:openai/gpt-oss-*"`). For model-scoped quirks the value is a
/// comma-separated list of model ids with `*` wildcards.
public enum Quirk {
    // Request shaping (OpenAI-compatible chat).
    public static let noTools = "noTools"
    public static let noJSONMode = "noJSONMode"
    public static let noStreaming = "noStreaming"
    public static let noStreamOptions = "noStreamOptions"
    public static let maxCompletionTokens = "maxCompletionTokens"
    public static let noSystemRole = "noSystemRole"
    public static let noImageDetail = "noImageDetail"
    public static let noMessageName = "noMessageName"
    public static let preserveReasoningContent = "preserveReasoningContent"
    public static let thinkTagsInContent = "thinkTagsInContent"
    public static let maxImagesPerRequest = "maxImagesPerRequest"
    public static let textOnly = "textOnly"
    public static let reasoningEffortViaExtraBody = "reasoningEffortViaExtraBody"
    public static let reasoningEffortNoneOrHighOnly = "reasoningEffortNoneOrHighOnly"
    public static let chatToolsOnlyWithReasoningNone = "chatToolsOnlyWithReasoningNone"
    public static let toolsRequireResponsesAPI = "toolsRequireResponsesAPI"
    public static let embeddingModel = "embeddingModel"
    // Native tools / versions.
    public static let anthropicVersion = "anthropicVersion"
    public static let computerToolset = "computerToolset"
    public static let computerToolType = "computerToolType"
    public static let thinkingMinimalUnsupported = "thinkingMinimalUnsupported"
    // Keys.
    public static let apiKeyOptional = "apiKeyOptional"
    public static let optionalAPIKey = "optionalAPIKey"
    public static let optionalAPIToken = "optionalAPIToken"
    public static let userSuppliedBaseURL = "userSuppliedBaseURL"
}

/// A parsed list of provider quirks.
public struct QuirkSet: Sendable, Hashable {
    public struct Entry: Sendable, Hashable {
        public var name: String
        public var value: String?
    }

    public let raw: [String]
    public let entries: [Entry]

    public init(_ quirks: [String]) {
        raw = quirks
        entries = quirks.compactMap { item in
            let trimmed = item.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            if let colon = trimmed.firstIndex(of: ":") {
                let name = String(trimmed[..<colon])
                let value = String(trimmed[trimmed.index(after: colon)...])
                return Entry(name: name, value: value.isEmpty ? nil : value)
            }
            return Entry(name: trimmed, value: nil)
        }
    }

    public static let empty = QuirkSet([])

    /// True when any entry has this name (with or without a value).
    public func contains(_ name: String) -> Bool {
        entries.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The value of the first entry with this name (`"anthropicVersion:2023-06-01"` → `"2023-06-01"`).
    public func value(_ name: String) -> String? {
        entries.first { $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.value != nil }?.value
    }

    /// Model-scoped check: a bare flag applies to every model; `name:<list>` applies when the model matches one of
    /// the comma-separated patterns (`*` wildcard, case-insensitive).
    public func applies(_ name: String, toModel model: String) -> Bool {
        for entry in entries where entry.name.caseInsensitiveCompare(name) == .orderedSame {
            guard let value = entry.value else { return true }
            for pattern in value.split(separator: ",") {
                if Self.glob(String(pattern).trimmingCharacters(in: .whitespaces), matches: model) { return true }
            }
        }
        return false
    }

    /// Integer value of a quirk (`maxImagesPerRequest:3` → 3).
    public func intValue(_ name: String) -> Int? {
        value(name).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Case-insensitive glob with `*` (any run of characters) and `?` (one character).
    public static func glob(_ pattern: String, matches text: String) -> Bool {
        let p = Array(pattern.lowercased())
        let t = Array(text.lowercased())
        var pi = 0, ti = 0
        var starP = -1, starT = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                pi += 1; ti += 1
            } else if pi < p.count, p[pi] == "*" {
                starP = pi; starT = ti; pi += 1
            } else if starP >= 0 {
                pi = starP + 1; starT += 1; ti = starT
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
