import Foundation
import ZCore

/// Ollama's native API (local `http://localhost:11434` or Ollama Cloud `https://ollama.com` with a bearer key):
/// `POST /api/chat` (tools, base64 `images`, NDJSON streaming), `GET /api/tags`, `POST /api/embed`.
public struct OllamaClient: LLMClient {
    public let model: ModelRef
    public let capabilities: ModelCapabilities
    public let endpoint: ProviderEndpoint
    public let quirks: QuirkSet
    public let http: HTTPClient
    public let modelsEndpoint: String?
    public let catalogModels: [ModelInfo]

    public init(model: ModelRef, capabilities: ModelCapabilities, endpoint: ProviderEndpoint, http: HTTPClient,
                quirks: QuirkSet = .empty, modelsEndpoint: String? = "/api/tags", catalogModels: [ModelInfo] = []) {
        self.model = model; self.capabilities = capabilities; self.endpoint = endpoint; self.http = http
        self.quirks = quirks; self.modelsEndpoint = modelsEndpoint; self.catalogModels = catalogModels
    }

    var usesStreaming: Bool { capabilities.streaming && !quirks.applies(Quirk.noStreaming, toModel: model.model) }

    // MARK: Request

    public func makeRequestBody(messages: [ChatMessage], tools: [ToolSpec], options: GenerationOptions,
                                stream: Bool) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(model.model),
            "messages": .array(encodeMessages(messages)),
            "stream": .bool(stream),
        ]
        if !tools.isEmpty, !quirks.applies(Quirk.noTools, toModel: model.model) {
            body["tools"] = .array(tools.map(OpenAIChatClient.functionTool))
        }
        var modelOptions: [String: JSONValue] = [:]
        if let temperature = options.temperature { modelOptions["temperature"] = .number(temperature) }
        if let maxTokens = options.maxTokens { modelOptions["num_predict"] = .number(Double(maxTokens)) }
        if !options.stop.isEmpty { modelOptions["stop"] = .array(options.stop.map { .string($0) }) }
        if !modelOptions.isEmpty { body["options"] = .object(modelOptions) }
        if options.jsonMode { body["format"] = "json" }
        if let effort = options.reasoningEffort { body["think"] = .bool(effort.lowercased() != "none") }
        for (key, value) in options.extra { body[key] = value }
        return .object(body)
    }

    func encodeMessages(_ messages: [ChatMessage]) -> [JSONValue] {
        let calls = Transcript.callIndex(messages)
        var out: [JSONValue] = []
        var pendingImages: [ImageData] = []

        func flushImages() {
            guard !pendingImages.isEmpty else { return }
            out.append([
                "role": "user",
                "content": "Image(s) returned by the tool call(s) above:",
                "images": .array(pendingImages.map { .string($0.base64) }),
            ])
            pendingImages.removeAll()
        }

        for message in messages {
            if message.role != .tool { flushImages() }
            switch message.role {
            case .system:
                let text = message.text
                if !text.isEmpty { out.append(["role": "system", "content": .string(text)]) }
            case .user:
                var entry: [String: JSONValue] = ["role": "user", "content": .string(message.text)]
                let images = message.images
                if !images.isEmpty { entry["images"] = .array(images.map { .string($0.base64) }) }
                out.append(.object(entry))
            case .assistant:
                var entry: [String: JSONValue] = ["role": "assistant", "content": .string(message.text)]
                let toolCalls = message.toolCalls
                if !toolCalls.isEmpty {
                    entry["tool_calls"] = .array(toolCalls.map { call -> JSONValue in
                        let function: [String: JSONValue] = [
                            "name": .string(call.name),
                            "arguments": .object(call.arguments.asArgumentsObject),
                        ]
                        return ["function": .object(function)]
                    })
                }
                out.append(.object(entry))
            case .tool:
                for result in message.toolResults {
                    var entry: [String: JSONValue] = ["role": "tool", "content": .string(Transcript.resultText(result))]
                    if let name = calls[result.callID]?.name { entry["tool_name"] = .string(name) }
                    out.append(.object(entry))
                    pendingImages += result.images
                }
            }
        }
        flushImages()
        return out
    }

    // MARK: LLMClient

    public func stream(messages: [ChatMessage], tools: [ToolSpec], options: GenerationOptions)
        -> AsyncThrowingStream<StreamEvent, Error> {
        let streaming = usesStreaming
        let request: HTTPRequest
        do {
            let body = makeRequestBody(messages: messages, tools: tools, options: options, stream: streaming)
            request = try http.request(url: try endpoint.url("api/chat"), method: "POST", headers: endpoint.headers(),
                                       json: body, stream: streaming)
        } catch {
            return StreamPump.failing(error)
        }
        let http = self.http
        return StreamPump.run { continuation in
            var state = OllamaStreamState()
            if streaming {
                var splitter = LineSplitter()
                let chunks = try await http.stream(request)
                for try await chunk in chunks {
                    for line in splitter.feed(chunk) {
                        for out in try state.handle(line: line) { continuation.yield(out) }
                    }
                }
                for line in splitter.finish() {
                    for out in try state.handle(line: line) { continuation.yield(out) }
                }
            } else {
                let response = try await http.send(request)
                for out in try state.handle(try HTTPClient.decodeJSON(response)) { continuation.yield(out) }
            }
            for out in state.finish() { continuation.yield(out) }
        }
    }

    public func listModels() async throws -> [ModelInfo] {
        guard let path = modelsEndpoint, !path.isEmpty else { return catalogModels }
        let json = try await http.getJSON(try endpoint.url(path), headers: endpoint.headers())
        var known: [String: ModelInfo] = [:]
        for info in catalogModels { known[info.id] = info }
        return (json["models"]?.arrayValue ?? []).compactMap { item -> ModelInfo? in
            guard let id = item["name"]?.stringValue ?? item["model"]?.stringValue else { return nil }
            if let info = known[id] { return info }
            let details = item["details"]
            let notes = [details?["parameter_size"]?.stringValue, details?["quantization_level"]?.stringValue]
                .compactMap { $0 }.joined(separator: " ")
            // Vision / tool support is per model; `POST /api/show` reports it (ZLocal's discovery does that).
            let caps = ModelCapabilities(vision: false, tools: capabilities.tools, streaming: true, jsonMode: true)
            return ModelInfo(id: id, displayName: id, capabilities: caps, free: true, notes: notes.isEmpty ? nil : notes)
        }
    }

    public func embed(texts: [String], model: String?) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let body: JSONValue = [
            "model": .string(model ?? quirks.value(Quirk.embeddingModel) ?? self.model.model),
            "input": .array(texts.map { .string($0) }),
        ]
        let json = try await http.postJSON(try endpoint.url("api/embed"), headers: endpoint.headers(), body: body)
        guard let vectors = json["embeddings"]?.arrayValue else {
            throw ZError.decoding("/api/embed response without embeddings")
        }
        return vectors.map { GeminiClient.floats($0.arrayValue ?? []) }
    }
}

/// Parses `/api/chat` NDJSON lines (or one non-streaming response object).
struct OllamaStreamState {
    var calls: [ToolCall] = []
    var doneReason: String?
    var usage: Usage?

    mutating func handle(line: String) throws -> [StreamEvent] {
        guard let json = try? JSONValue.parse(line) else {
            throw ZError.decoding("Unreadable Ollama line: \(String(line.prefix(200)))")
        }
        return try handle(json)
    }

    mutating func handle(_ json: JSONValue) throws -> [StreamEvent] {
        if let error = json["error"], !error.isNull { throw ProviderErrorMapper.streamError(json) }
        var events: [StreamEvent] = []
        if let message = json["message"] {
            if let thinking = message["thinking"]?.stringValue, !thinking.isEmpty { events.append(.reasoningDelta(thinking)) }
            if let content = message["content"]?.stringValue, !content.isEmpty { events.append(.textDelta(content)) }
            for call in message["tool_calls"]?.arrayValue ?? [] {
                let function = call["function"] ?? .object([:])
                guard let name = function["name"]?.stringValue, !name.isEmpty else { continue }
                var arguments = function["arguments"] ?? .object([:])
                if case .string(let raw) = arguments { arguments = ToolCallAssembler.parseArguments(raw) }
                let id = call["id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? ToolCallAssembler.synthesizeID()
                let toolCall = ToolCall(id: id, name: name, arguments: arguments)
                calls.append(toolCall)
                events.append(.toolCallStart(id: id, name: name))
                events.append(.toolCall(toolCall))
            }
        }
        if json["done"]?.boolValue == true {
            doneReason = json["done_reason"]?.stringValue ?? "stop"
            if json["prompt_eval_count"] != nil || json["eval_count"] != nil {
                usage = Usage(inputTokens: json["prompt_eval_count"]?.lenientInt ?? 0,
                              outputTokens: json["eval_count"]?.lenientInt ?? 0)
            }
        }
        return events
    }

    func finish() -> [StreamEvent] {
        var events: [StreamEvent] = []
        if let usage { events.append(.usage(usage)) }
        let reason: FinishReason
        switch doneReason {
        case "length"?: reason = .length
        case "stop"?, nil: reason = calls.isEmpty ? .stop : .toolCalls
        default: reason = calls.isEmpty ? .other : .toolCalls
        }
        events.append(.finished(reason))
        return events
    }
}
