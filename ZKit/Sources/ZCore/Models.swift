import Foundation

/// Identifies a provider in the catalogue ("anthropic", "groq", "ollama", ...).
public struct ProviderID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ raw: String) { self.rawValue = raw }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
}

/// A concrete model on a concrete provider.
public struct ModelRef: Hashable, Codable, Sendable, CustomStringConvertible {
    public var provider: ProviderID
    public var model: String
    public init(provider: ProviderID, model: String) { self.provider = provider; self.model = model }
    public var description: String { "\(provider.rawValue)/\(model)" }
}

/// What a model can do. Used by the agent loop to pick the right tool strategy.
public struct ModelCapabilities: Hashable, Codable, Sendable {
    public var vision: Bool
    public var tools: Bool
    public var streaming: Bool
    public var jsonMode: Bool
    public var nativeComputerUse: NativeToolKind?
    public var contextWindow: Int?
    public var maxOutputTokens: Int?
    public init(vision: Bool = false, tools: Bool = false, streaming: Bool = true, jsonMode: Bool = false,
                nativeComputerUse: NativeToolKind? = nil, contextWindow: Int? = nil, maxOutputTokens: Int? = nil) {
        self.vision = vision; self.tools = tools; self.streaming = streaming; self.jsonMode = jsonMode
        self.nativeComputerUse = nativeComputerUse; self.contextWindow = contextWindow; self.maxOutputTokens = maxOutputTokens
    }
}

/// A model as listed by a provider.
public struct ModelInfo: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var displayName: String
    public var capabilities: ModelCapabilities
    public var free: Bool
    public var notes: String?
    public init(id: String, displayName: String? = nil, capabilities: ModelCapabilities = .init(), free: Bool = false, notes: String? = nil) {
        self.id = id; self.displayName = displayName ?? id; self.capabilities = capabilities; self.free = free; self.notes = notes
    }
}
