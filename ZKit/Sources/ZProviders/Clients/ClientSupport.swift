import Foundation
import ZCore

/// Resolved connection details for one provider: base URL (placeholders filled), auth style and key.
public struct ProviderEndpoint: Sendable, Hashable {
    public var providerID: ProviderID
    public var baseURL: URL
    public var auth: AuthStyle
    public var apiKey: String?
    /// Sent with every request (e.g. `anthropic-version`).
    public var extraHeaders: [String: String]

    public init(providerID: ProviderID, baseURL: URL, auth: AuthStyle, apiKey: String?, extraHeaders: [String: String] = [:]) {
        self.providerID = providerID; self.baseURL = baseURL; self.auth = auth; self.apiKey = apiKey
        self.extraHeaders = extraHeaders
    }

    /// `baseURL` + `/path` (slashes normalised) + query items, with the key added for `query:` auth.
    public func url(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        var tail = path
        while tail.hasPrefix("/") { tail.removeFirst() }
        let joined = tail.isEmpty ? base : base + "/" + tail
        guard var components = URLComponents(string: joined) else {
            throw ZError.invalidArgument("Invalid URL: \(joined)")
        }
        var items = components.queryItems ?? []
        items.append(contentsOf: query)
        if case .query(let name) = auth, let apiKey, !apiKey.isEmpty {
            items.append(URLQueryItem(name: name, value: apiKey))
        }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else { throw ZError.invalidArgument("Invalid URL: \(joined)") }
        return url
    }

    /// Auth + extra headers. With `.noAuth`, a key that the user set anyway (optional tokens on local servers) is
    /// sent as a bearer token.
    public func headers(_ extra: [String: String] = [:]) -> [String: String] {
        var headers = extraHeaders
        if let apiKey, !apiKey.isEmpty {
            switch auth {
            case .bearer, .noAuth: headers["Authorization"] = "Bearer \(apiKey)"
            case .header(let name): headers[name] = apiKey
            case .query: break
            }
        }
        for (name, value) in extra { headers[name] = value }
        return headers
    }
}

/// Bridges an async producer into the `AsyncThrowingStream` that `LLMClient.stream` returns; cancelling the consumer
/// cancels the producer (and with it the HTTP request).
enum StreamPump {
    static func run(_ body: @escaping @Sendable (AsyncThrowingStream<StreamEvent, Error>.Continuation) async throws -> Void)
        -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await body(continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: HTTPClient.normalize(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func failing(_ error: Error) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: error) }
    }
}

/// Helpers over ZCore transcripts shared by the clients.
enum Transcript {
    /// All system-message text joined with blank lines.
    static func systemText(_ messages: [ChatMessage]) -> String {
        messages.filter { $0.role == .system }.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Tool call id → call, over every assistant message.
    static func callIndex(_ messages: [ChatMessage]) -> [String: ToolCall] {
        var index: [String: ToolCall] = [:]
        for message in messages {
            for call in message.toolCalls { index[call.id] = call }
        }
        return index
    }

    /// Text for a tool result: its text parts, "ERROR: " prefixed when it failed.
    static func resultText(_ result: ToolResult, emptyFallback: String = "(no output)") -> String {
        var text = result.text
        if text.isEmpty { text = result.images.isEmpty ? emptyFallback : "(see the attached image)" }
        return result.isError ? "ERROR: \(text)" : text
    }
}

/// Naming conventions for native computer-use calls in ZCore transcripts (shared with ZAgent's NativeComputerBridge):
///
/// * Anthropic `computer_toolset_*` member blocks → `ToolCall(id: tool_use.id, name: "computer.<member>", arguments:
///   input)`; the client re-adds `"toolset_name": "computer"` on `tool_use` and `tool_result` blocks. Legacy
///   `computer_20251124` / `computer_20250124` calls stay `ToolCall(name: "computer", arguments: input)` with `action`.
/// * OpenAI Responses `computer_call` → one `ToolCall(id: call_id, name: "computer", arguments: {"actions": [...],
///   "pending_safety_checks": [...], "response_id": "resp_…"})`; its result's image becomes the
///   `computer_call_output` screenshot.
/// * Gemini `computerUse` function calls → `ToolCall(id: id ?? synthesised, name: "computer.<function>", arguments:
///   args)`; coordinates stay on Gemini's 0–999 grid.
public enum NativeToolNaming {
    public static let computer = "computer"
    public static let prefix = "computer."

    public static func member(of name: String) -> String? {
        name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : nil
    }

    public static func memberCall(_ member: String) -> String { prefix + member }

    /// The declaration the agent supplied verbatim in `ToolSpec.metadata["declaration"]`, if any.
    static func declaration(of spec: ToolSpec) -> JSONValue? {
        guard let value = spec.metadata["declaration"], value.objectValue != nil else { return nil }
        return value
    }

    static func int(_ spec: ToolSpec, _ keys: [String]) -> Int? {
        for key in keys { if let value = spec.metadata[key]?.intValue { return value } }
        return nil
    }
}

/// A small process-wide LRU used to replay provider data that ZCore transcripts have no slot for (Gemini thought
/// signatures, OpenAI response ids), keyed by tool call id.
actor KeyedMemo {
    private var values: [String: String] = [:]
    private var order: [String] = []
    private let capacity: Int

    init(capacity: Int = 2048) { self.capacity = capacity }

    func set(_ value: String, for key: String) {
        if values[key] == nil { order.append(key) }
        values[key] = value
        if order.count > capacity {
            let drop = order.count - capacity
            for old in order.prefix(drop) { values[old] = nil }
            order.removeFirst(drop)
        }
    }

    func get(_ key: String) -> String? { values[key] }

    static let geminiThoughtSignatures = KeyedMemo()
    static let openAIResponseIDs = KeyedMemo()
}

/// Finish-reason mapping shared by OpenAI-compatible servers.
enum FinishReasons {
    static func openAI(_ raw: String?) -> FinishReason? {
        guard let raw else { return nil }
        switch raw {
        case "stop", "end_turn", "eos": return .stop
        case "length", "max_tokens": return .length
        case "tool_calls", "function_call", "tool_use": return .toolCalls
        case "content_filter", "safety": return .contentFilter
        default: return .other
        }
    }
}

extension JSONValue {
    /// Int from a number or a numeric string.
    var lenientInt: Int? {
        switch self {
        case .number(let n) where n.isFinite && abs(n) < 9.0e15: return Int(n)
        case .string(let s): return Int(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// Arguments as an object (non-object values are wrapped so providers that require an object accept them).
    var asArgumentsObject: [String: JSONValue] {
        switch self {
        case .object(let o): return o
        case .null: return [:]
        default: return ["value": self]
        }
    }
}

extension ImageData {
    /// Mime type with a safe default.
    var mimeType: String { mime.isEmpty ? "image/png" : mime }
}
