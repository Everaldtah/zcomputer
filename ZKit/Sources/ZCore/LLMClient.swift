import Foundation

/// A chat-completion client for one model on one provider.
public protocol LLMClient: Sendable {
    var model: ModelRef { get }
    var capabilities: ModelCapabilities { get }

    /// Streams a completion. Implementations must emit `.toolCall` for every complete tool call and end with `.finished`.
    func stream(messages: [ChatMessage], tools: [ToolSpec], options: GenerationOptions) -> AsyncThrowingStream<StreamEvent, Error>

    /// Lists the models available on this provider (falls back to the catalogue when unsupported).
    func listModels() async throws -> [ModelInfo]

    /// Embeddings; throws `ZError.unsupported` when the provider has none.
    func embed(texts: [String], model: String?) async throws -> [[Float]]
}

public struct CompletionResult: Sendable {
    public var message: ChatMessage
    public var usage: Usage
    public var finishReason: FinishReason
    public init(message: ChatMessage, usage: Usage, finishReason: FinishReason) {
        self.message = message; self.usage = usage; self.finishReason = finishReason
    }
}

public extension LLMClient {
    /// Collects a stream into a single assistant message.
    func complete(messages: [ChatMessage], tools: [ToolSpec] = [], options: GenerationOptions = .standard) async throws -> CompletionResult {
        var text = ""
        var reasoning = ""
        var calls: [ToolCall] = []
        var usage = Usage()
        var finish: FinishReason = .stop
        for try await ev in stream(messages: messages, tools: tools, options: options) {
            switch ev {
            case .textDelta(let d): text += d
            case .reasoningDelta(let d): reasoning += d
            case .toolCall(let c): calls.append(c)
            case .usage(let u): usage = usage + u
            case .finished(let f): finish = f
            case .toolCallStart, .toolCallDelta: break
            }
        }
        var parts: [ContentPart] = []
        if !reasoning.isEmpty { parts.append(.reasoning(reasoning)) }
        if !text.isEmpty { parts.append(.text(text)) }
        parts.append(contentsOf: calls.map { .toolUse($0) })
        if !calls.isEmpty, finish == .stop { finish = .toolCalls }
        return CompletionResult(message: ChatMessage(role: .assistant, parts: parts), usage: usage, finishReason: finish)
    }

    func embed(texts: [String], model: String?) async throws -> [[Float]] { throw ZError.unsupported("embeddings") }
}
