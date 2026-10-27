import Foundation

/// Provider-native tools that are declared differently from a plain JSON-schema function.
public enum NativeToolKind: String, Codable, Sendable, Hashable {
    case anthropicComputer      // Anthropic computer-use tool (computer_YYYYMMDD)
    case anthropicBash
    case anthropicTextEditor
    case openAIComputer         // OpenAI Responses API computer_use_preview
    case geminiComputer         // Gemini computer_use tool
}

/// A tool as advertised to the model.
public struct ToolSpec: Hashable, Codable, Sendable {
    public var name: String
    public var description: String
    /// JSON schema for the arguments object.
    public var parameters: JSONValue
    /// When set, providers that support it declare the native tool instead of the JSON function.
    public var native: NativeToolKind?
    /// Extra provider-specific fields (e.g. display size for computer tools).
    public var metadata: [String: JSONValue]

    public init(name: String, description: String, parameters: JSONValue = ["type": "object", "properties": [:]],
                native: NativeToolKind? = nil, metadata: [String: JSONValue] = [:]) {
        self.name = name; self.description = description; self.parameters = parameters; self.native = native; self.metadata = metadata
    }
}

public struct ToolCall: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var arguments: JSONValue
    public init(id: String, name: String, arguments: JSONValue) { self.id = id; self.name = name; self.arguments = arguments }
}

public struct ToolResult: Hashable, Codable, Sendable {
    public var callID: String
    public var parts: [ContentPart]
    public var isError: Bool
    public init(callID: String, parts: [ContentPart], isError: Bool = false) { self.callID = callID; self.parts = parts; self.isError = isError }
    public init(callID: String, text: String, isError: Bool = false) { self.init(callID: callID, parts: [.text(text)], isError: isError) }
    public var text: String { parts.compactMap { if case .text(let t) = $0 { return t }; return nil }.joined(separator: "\n") }
    public var images: [ImageData] { parts.compactMap { if case .image(let i) = $0 { return i }; return nil } }
}
