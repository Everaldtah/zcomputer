#if canImport(FoundationModels)
import Foundation
import FoundationModels
import ZCore

/// Apple's on-device model (macOS 26+, Apple Intelligence) as an `LLMClient`. Text only with a 4,096-token context
/// on macOS 26, so it reports no vision and no native tools: the agent then uses its text tool protocol
/// (docs/research/local-models-and-agent-loops.md §3). Each call is a fresh `LanguageModelSession` seeded with the
/// transcript, because `LLMClient` is stateless.
@available(macOS 26.0, *)
struct FoundationModelsClient: LLMClient {
    let model = ModelRef(provider: ProviderID("apple"), model: "system")

    var capabilities: ModelCapabilities {
        ModelCapabilities(vision: false, tools: false, streaming: false, jsonMode: false, nativeComputerUse: nil,
                          contextWindow: 4096, maxOutputTokens: 1024)
    }

    /// Why the model cannot run here, or nil when it can.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            return "Apple Intelligence is unavailable: \(reason)"
        @unknown default:
            return "Apple Intelligence is unavailable on this Mac."
        }
    }

    func stream(messages: [ChatMessage], tools: [ToolSpec], options: ZCore.GenerationOptions) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let reason = Self.unavailableReason { throw ZError.unsupported(reason) }
                    let (instructions, prompt) = Self.render(messages)
                    let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
                    let fmOptions = FoundationModels.GenerationOptions(temperature: options.temperature,
                                                                       maximumResponseTokens: options.maxTokens ?? 1024)
                    let response = try await session.respond(to: prompt, options: fmOptions)
                    let text = response.content
                    if !text.isEmpty { continuation.yield(.textDelta(text)) }
                    continuation.yield(.finished(.stop))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Task.isCancelled ? CancellationError() : error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func listModels() async throws -> [ModelInfo] {
        [ModelInfo(id: model.model, displayName: "Apple on-device model", capabilities: capabilities, free: true,
                   notes: "Runs on this Mac with Apple Intelligence; text only, 4K context.")]
    }

    /// System text → instructions; the rest of the transcript → one prompt (tool results as text).
    static func render(_ messages: [ChatMessage]) -> (instructions: String, prompt: String) {
        var instructions: [String] = []
        var lines: [String] = []
        for message in messages {
            switch message.role {
            case .system:
                instructions.append(message.text)
            case .user:
                lines.append("User: \(message.text)")
            case .assistant:
                var text = message.text
                for call in message.toolCalls { text += "\n[called \(call.name) with \(call.arguments.jsonString())]" }
                lines.append("Assistant: \(text)")
            case .tool:
                for result in message.toolResults {
                    lines.append("Tool result\(result.isError ? " (error)" : ""): \(result.text)")
                }
            }
        }
        // Keep the newest turns when the transcript is long (4K-token window).
        var prompt = lines.joined(separator: "\n\n")
        if prompt.count > 9000 { prompt = "…" + String(prompt.suffix(9000)) }
        return (instructions.joined(separator: "\n\n"), prompt + "\n\nAssistant:")
    }
}
#endif
