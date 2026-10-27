import Foundation

public enum Role: String, Codable, Sendable, Hashable {
    case system, user, assistant, tool
}

/// Raw image bytes plus mime type ("image/png" or "image/jpeg").
public struct ImageData: Hashable, Codable, Sendable {
    public var mime: String
    public var data: Data
    public var width: Int?
    public var height: Int?
    public init(mime: String, data: Data, width: Int? = nil, height: Int? = nil) {
        self.mime = mime; self.data = data; self.width = width; self.height = height
    }
    public var base64: String { data.base64EncodedString() }
    public var dataURL: String { "data:\(mime);base64,\(base64)" }
}

public enum ContentPart: Hashable, Codable, Sendable {
    case text(String)
    case image(ImageData)
    /// An assistant-authored request to call a tool.
    case toolUse(ToolCall)
    /// The result of a tool call, carried in a `.tool` role message.
    case toolResult(ToolResult)
    /// Model reasoning / thinking text (providers that expose it). Clients decide whether to send it back.
    case reasoning(String)
}

public struct ChatMessage: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var role: Role
    public var parts: [ContentPart]
    /// Optional participant name (used in team mode transcripts).
    public var name: String?
    public var createdAt: Date

    public init(id: UUID = UUID(), role: Role, parts: [ContentPart], name: String? = nil, createdAt: Date = Date()) {
        self.id = id; self.role = role; self.parts = parts; self.name = name; self.createdAt = createdAt
    }

    public static func system(_ text: String) -> ChatMessage { .init(role: .system, parts: [.text(text)]) }
    public static func user(_ text: String, images: [ImageData] = []) -> ChatMessage {
        .init(role: .user, parts: [.text(text)] + images.map { .image($0) })
    }
    public static func assistant(_ text: String) -> ChatMessage { .init(role: .assistant, parts: [.text(text)]) }
    public static func toolResults(_ results: [ToolResult]) -> ChatMessage { .init(role: .tool, parts: results.map { .toolResult($0) }) }

    /// All text parts joined.
    public var text: String {
        parts.compactMap { if case .text(let t) = $0 { return t }; return nil }.joined(separator: "\n")
    }
    public var toolCalls: [ToolCall] { parts.compactMap { if case .toolUse(let c) = $0 { return c }; return nil } }
    public var toolResults: [ToolResult] { parts.compactMap { if case .toolResult(let r) = $0 { return r }; return nil } }
    public var images: [ImageData] { parts.compactMap { if case .image(let i) = $0 { return i }; return nil } }
    public var hasImages: Bool { !images.isEmpty }
}
