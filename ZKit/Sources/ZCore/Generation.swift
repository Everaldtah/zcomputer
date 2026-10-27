import Foundation

public struct Usage: Hashable, Codable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cachedInputTokens: Int
    public init(inputTokens: Int = 0, outputTokens: Int = 0, cachedInputTokens: Int = 0) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.cachedInputTokens = cachedInputTokens
    }
    public static func + (a: Usage, b: Usage) -> Usage {
        .init(inputTokens: a.inputTokens + b.inputTokens, outputTokens: a.outputTokens + b.outputTokens,
              cachedInputTokens: a.cachedInputTokens + b.cachedInputTokens)
    }
}

public enum FinishReason: String, Codable, Sendable, Hashable {
    case stop, length, toolCalls, contentFilter, other
}

public struct GenerationOptions: Hashable, Codable, Sendable {
    public var temperature: Double?
    public var maxTokens: Int?
    public var stop: [String]
    /// Ask for a JSON object response where the provider supports it.
    public var jsonMode: Bool
    /// "low" | "medium" | "high" for providers with reasoning effort.
    public var reasoningEffort: String?
    /// Provider-specific pass-through fields merged into the request body.
    public var extra: [String: JSONValue]
    public init(temperature: Double? = nil, maxTokens: Int? = nil, stop: [String] = [], jsonMode: Bool = false,
                reasoningEffort: String? = nil, extra: [String: JSONValue] = [:]) {
        self.temperature = temperature; self.maxTokens = maxTokens; self.stop = stop; self.jsonMode = jsonMode
        self.reasoningEffort = reasoningEffort; self.extra = extra
    }
    public static let standard = GenerationOptions()
}

/// Incremental events from a streaming completion.
public enum StreamEvent: Sendable {
    case textDelta(String)
    case reasoningDelta(String)
    case toolCallStart(id: String, name: String)
    case toolCallDelta(id: String, argumentsDelta: String)
    /// A complete tool call (always emitted, even for non-streaming providers).
    case toolCall(ToolCall)
    case usage(Usage)
    case finished(FinishReason)
}
