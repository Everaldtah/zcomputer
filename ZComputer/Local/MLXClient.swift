#if ZC_MLX
import CoreImage
import Foundation
import MLXLLM
import MLXLMCommon
import MLXVLM
import ZCore
import ZLocal

/// Keeps one loaded MLX model in memory (models are GBs; switching models releases the previous one).
actor MLXModelCache {
    static let shared = MLXModelCache()

    private var loadedID: String?
    private var loaded: ModelContainer?

    /// The container for a downloaded model directory; vision models load through MLXVLM, text models through MLXLLM.
    func container(for directory: URL, id: String, vision: Bool) async throws -> ModelContainer {
        if loadedID == id, let loaded { return loaded }
        loaded = nil
        loadedID = nil
        let loader = MLXTransformersLoader()
        let container: ModelContainer
        if vision {
            container = try await VLMModelFactory.shared.loadContainer(from: directory, using: loader)
        } else {
            container = try await LLMModelFactory.shared.loadContainer(from: directory, using: loader)
        }
        loaded = container
        loadedID = id
        return container
    }

    func unload() {
        loaded = nil
        loadedID = nil
    }
}

/// An in-app MLX model (downloaded by Settings ▸ Local models into `LocalModelStore`) as an `LLMClient`, on
/// mlx-swift-lm 3.32.3: `ModelContainer` + `ChatSession` + `GenerateParameters`. Vision models (the catalogue's
/// `vision` entries) get screenshots as `UserInput.Image`s through MLXVLM. Models with a native tool-call dialect
/// (`tools` in the catalogue) get the tools through the chat template and report parsed `.toolCall`s; the others
/// report no tool support, so ZAgent falls back to its fenced-JSON text protocol.
struct MLXClient: LLMClient {
    let model: ModelRef
    let directory: URL
    let spec: LocalModelSpec?
    let capabilities: ModelCapabilities

    /// Screenshot budget for vision models (the default 512x512 resize is too small for screens).
    static let maxImagePixels = 1280 * 800

    init(ref: ModelRef, directory: URL, spec: LocalModelSpec?, host: HostCapabilities) {
        self.model = ref
        self.directory = directory
        self.spec = spec
        let context = host.ramGB >= 24 ? 32_768 : 16_384
        self.capabilities = ModelCapabilities(vision: spec?.vision ?? false, tools: spec?.tools ?? false, streaming: true,
                                              jsonMode: false, nativeComputerUse: nil, contextWindow: context,
                                              maxOutputTokens: 2048)
    }

    func stream(messages: [ChatMessage], tools: [ZCore.ToolSpec],
                options: ZCore.GenerationOptions) -> AsyncThrowingStream<StreamEvent, Error> {
        let directory = self.directory
        let id = model.model
        let caps = capabilities
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let container = try await MLXModelCache.shared.container(for: directory, id: id, vision: caps.vision)
                    try await Self.generate(container: container, messages: messages, tools: tools, options: options,
                                            capabilities: caps, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Task.isCancelled ? CancellationError() : error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func listModels() async throws -> [ModelInfo] {
        [spec?.modelInfo ?? ModelInfo(id: model.model, capabilities: capabilities, free: true)]
    }

    // MARK: Generation

    private static func generate(container: ModelContainer, messages: [ChatMessage], tools: [ZCore.ToolSpec],
                                 options: ZCore.GenerationOptions, capabilities: ModelCapabilities,
                                 continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation) async throws {
        var instructions: [String] = []
        var history: [Chat.Message] = []
        for message in messages {
            switch message.role {
            case .system:
                instructions.append(message.text)
            case .user:
                history.append(.user(message.text, images: capabilities.vision ? images(message.images) : []))
            case .assistant:
                let calls = message.toolCalls
                if capabilities.tools, !calls.isEmpty {
                    let mlxCalls = calls.map { call in
                        MLXLMCommon.ToolCall(function: .init(name: call.name, arguments: mlxObject(call.arguments)),
                                             id: call.id)
                    }
                    history.append(.assistant(message.text, toolCalls: mlxCalls))
                } else {
                    history.append(.assistant(message.text))
                }
            case .tool:
                for result in message.toolResults {
                    let body = result.text.isEmpty ? "(no output)" : result.text
                    history.append(.tool(result.isError ? "Error: \(body)" : body, id: result.callID))
                    // Tool messages cannot carry images: the screenshot follows as a user turn.
                    if capabilities.vision, !result.images.isEmpty {
                        history.append(.user("Screenshot after that action:", images: images(result.images)))
                    }
                }
            }
        }
        guard let last = history.popLast() else { throw ZError.invalidArgument("nothing to answer") }

        let parameters = GenerateParameters(maxTokens: options.maxTokens ?? 2048,
                                            maxKVSize: capabilities.contextWindow ?? 16_384,
                                            temperature: Float(options.temperature ?? 0.2))
        let mlxTools: [MLXLMCommon.ToolSpec]? = capabilities.tools && !tools.isEmpty ? tools.map(toolSpec) : nil
        let session = ChatSession(container,
                                  instructions: instructions.isEmpty ? nil : instructions.joined(separator: "\n\n"),
                                  history: history,
                                  generateParameters: parameters,
                                  processing: UserInput.Processing(maxPixels: maxImagePixels),
                                  tools: mlxTools)
        var callCount = 0
        for try await event in session.streamDetails(to: [last]) {
            try Task.checkCancellation()
            switch event {
            case .chunk(let text):
                continuation.yield(.textDelta(text))
            case .toolCall(let call):
                let args = ZCore.JSONValue.object(call.function.arguments.mapValues(zValue))
                let id = call.id ?? "mlx_call_\(callCount)"
                continuation.yield(.toolCall(ZCore.ToolCall(id: id, name: call.function.name, arguments: args)))
                callCount += 1
            case .rejectedToolCall(let rejected):
                continuation.yield(.textDelta("\n[The local model wrote a tool call that could not be parsed: "
                                              + "\(rejected.reason.rawValue)]\n"))
            case .info(let info):
                continuation.yield(.usage(Usage(inputTokens: info.promptTokenCount, outputTokens: info.generationTokenCount)))
            }
        }
        continuation.yield(.finished(callCount > 0 ? .toolCalls : .stop))
    }

    private static func images(_ images: [ImageData]) -> [UserInput.Image] {
        images.compactMap { image in CIImage(data: image.data).map { UserInput.Image.ciImage($0) } }
    }

    // MARK: Tool and JSON conversion

    /// An OpenAI-style function declaration for the chat template.
    private static func toolSpec(_ spec: ZCore.ToolSpec) -> MLXLMCommon.ToolSpec {
        let function: [String: any Sendable] = [
            "name": spec.name,
            "description": spec.description,
            "parameters": sendable(spec.parameters),
        ]
        return ["type": "function", "function": function]
    }

    private static func sendable(_ value: ZCore.JSONValue) -> any Sendable {
        switch value {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n.rounded() == n && abs(n) < 9.0e15 ? Int(n) : n
        case .string(let s): return s
        case .array(let a): return a.map { sendable($0) }
        case .object(let o): return o.mapValues { sendable($0) }
        }
    }

    private static func mlxObject(_ value: ZCore.JSONValue) -> [String: MLXLMCommon.JSONValue] {
        guard case .object(let object) = value else { return [:] }
        return object.mapValues(mlxValue)
    }

    private static func mlxValue(_ value: ZCore.JSONValue) -> MLXLMCommon.JSONValue {
        switch value {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .number(let n): return n.rounded() == n && abs(n) < 9.0e15 ? .int(Int(n)) : .double(n)
        case .string(let s): return .string(s)
        case .array(let a): return .array(a.map(mlxValue))
        case .object(let o): return .object(o.mapValues(mlxValue))
        }
    }

    private static func zValue(_ value: MLXLMCommon.JSONValue) -> ZCore.JSONValue {
        switch value {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .int(let i): return .number(Double(i))
        case .double(let d): return .number(d)
        case .string(let s): return .string(s)
        case .array(let a): return .array(a.map(zValue))
        case .object(let o): return .object(o.mapValues(zValue))
        }
    }
}
#endif
