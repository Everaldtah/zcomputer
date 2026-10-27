import Foundation
import ZCore

/// OpenAI Chat Completions (`POST {base}/chat/completions`) and every OpenAI-compatible server in the catalogue.
///
/// Quirks honoured (from the provider descriptor): `noTools`, `noJSONMode`, `noStreaming` (non-streaming fallback),
/// `noStreamOptions`, `maxCompletionTokens`, `noSystemRole` (system text folded into the first user message),
/// `noImageDetail`, `noMessageName`, `preserveReasoningContent`, `thinkTagsInContent`, `maxImagesPerRequest:N`,
/// `textOnly`, `reasoningEffortViaExtraBody`, `reasoningEffortNoneOrHighOnly`, `chatToolsOnlyWithReasoningNone:<models>`,
/// `embeddingModel:<id>`.
///
/// Tool messages accept only text (research §7.4), so images returned by tools are sent in a `user` message right
/// after the tool messages of that turn.
public struct OpenAIChatClient: LLMClient {
    public let model: ModelRef
    public let capabilities: ModelCapabilities
    public let endpoint: ProviderEndpoint
    public let quirks: QuirkSet
    public let http: HTTPClient
    /// Path of the models list (`/models`); nil → `listModels()` returns the catalogue.
    public let modelsEndpoint: String?
    public let catalogModels: [ModelInfo]
    /// `detail` for image parts (omitted with the `noImageDetail` quirk).
    public var imageDetail: String = "high"

    public init(model: ModelRef, capabilities: ModelCapabilities, endpoint: ProviderEndpoint, http: HTTPClient,
                quirks: QuirkSet = .empty, modelsEndpoint: String? = "/models", catalogModels: [ModelInfo] = []) {
        self.model = model; self.capabilities = capabilities; self.endpoint = endpoint; self.http = http
        self.quirks = quirks; self.modelsEndpoint = modelsEndpoint; self.catalogModels = catalogModels
    }

    private func has(_ quirk: String) -> Bool { quirks.applies(quirk, toModel: model.model) }

    /// Whether this client streams (false with the `noStreaming` quirk or `capabilities.streaming == false`).
    public var usesStreaming: Bool { capabilities.streaming && !has(Quirk.noStreaming) }

    // MARK: Request

    public func makeRequestBody(messages: [ChatMessage], tools: [ToolSpec], options: GenerationOptions,
                                stream: Bool) throws -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(model.model),
            "messages": .array(encodeMessages(messages)),
        ]
        let sendTools = !tools.isEmpty && !has(Quirk.noTools)
        if sendTools {
            body["tools"] = .array(tools.map(Self.functionTool))
        }
        if let maxTokens = options.maxTokens {
            body[has(Quirk.maxCompletionTokens) ? "max_completion_tokens" : "max_tokens"] = .number(Double(maxTokens))
        }
        if let temperature = options.temperature { body["temperature"] = .number(temperature) }
        if !options.stop.isEmpty { body["stop"] = .array(options.stop.map { .string($0) }) }
        if options.jsonMode, !has(Quirk.noJSONMode) {
            body["response_format"] = ["type": "json_object"]
        }
        if sendTools, has(Quirk.chatToolsOnlyWithReasoningNone) {
            body["reasoning_effort"] = "none"
        } else if let effort = options.reasoningEffort {
            var value = effort
            if has(Quirk.reasoningEffortNoneOrHighOnly) { value = effort == "none" ? "none" : "high" }
            if has(Quirk.reasoningEffortViaExtraBody) {
                body["extra_body"] = ["reasoning_effort": .string(value)]
            } else {
                body["reasoning_effort"] = .string(value)
            }
        }
        if stream {
            body["stream"] = true
            if !has(Quirk.noStreamOptions) { body["stream_options"] = ["include_usage": true] }
        } else {
            body["stream"] = false
        }
        for (key, value) in options.extra { body[key] = value }
        return .object(body)
    }

    static func functionTool(_ spec: ToolSpec) -> JSONValue {
        let function: [String: JSONValue] = [
            "name": .string(spec.name),
            "description": .string(spec.description),
            "parameters": spec.parameters,
        ]
        return ["type": "function", "function": .object(function)]
    }

    func encodeMessages(_ messages: [ChatMessage]) -> [JSONValue] {
        let noSystem = has(Quirk.noSystemRole)
        let textOnly = has(Quirk.textOnly)
        let maxImages = quirks.intValue(Quirk.maxImagesPerRequest)
        let totalImages = messages.reduce(0) { sum, m in
            sum + m.images.count + m.toolResults.reduce(0) { $0 + $1.images.count }
        }
        let firstKeptImage = maxImages.map { max(0, totalImages - $0) } ?? 0
        var imageCounter = 0
        var out: [JSONValue] = []
        var pendingSystem: [String] = []
        var pendingToolImages: [ImageData] = []

        func imagePart(_ image: ImageData) -> JSONValue {
            defer { imageCounter += 1 }
            if textOnly { return ["type": "text", "text": "[image omitted: this provider does not accept images]"] }
            if imageCounter < firstKeptImage { return ["type": "text", "text": "[earlier image omitted]"] }
            var imageURL: [String: JSONValue] = ["url": .string(image.dataURL)]
            if !has(Quirk.noImageDetail) { imageURL["detail"] = .string(imageDetail) }
            return ["type": "image_url", "image_url": .object(imageURL)]
        }

        func flushToolImages() {
            guard !pendingToolImages.isEmpty else { return }
            var parts: [JSONValue] = [["type": "text", "text": "Image(s) returned by the tool call(s) above:"]]
            parts += pendingToolImages.map(imagePart)
            pendingToolImages.removeAll()
            out.append(["role": "user", "content": .array(parts)])
        }

        for message in messages {
            if message.role != .tool { flushToolImages() }
            switch message.role {
            case .system:
                let text = message.text
                guard !text.isEmpty else { continue }
                if noSystem { pendingSystem.append(text) } else { out.append(["role": "system", "content": .string(text)]) }
            case .user:
                var parts: [JSONValue] = []
                if !pendingSystem.isEmpty {
                    parts.append(["type": "text", "text": .string(pendingSystem.joined(separator: "\n\n"))])
                    pendingSystem.removeAll()
                }
                var hasImage = false
                for part in message.parts {
                    switch part {
                    case .text(let t): parts.append(["type": "text", "text": .string(t)])
                    case .image(let image):
                        let encoded = imagePart(image)
                        if encoded["type"]?.stringValue == "image_url" { hasImage = true }
                        parts.append(encoded)
                    case .toolResult(let result):
                        // Unusual (results normally live in `.tool` messages); keep them as text.
                        parts.append(["type": "text", "text": .string("Result of \(result.callID): \(Transcript.resultText(result))")])
                    case .toolUse, .reasoning: break
                    }
                }
                var entry: [String: JSONValue] = ["role": "user"]
                if hasImage {
                    entry["content"] = .array(parts)
                } else {
                    entry["content"] = .string(parts.compactMap { $0["text"]?.stringValue }.joined(separator: "\n"))
                }
                if let name = message.name, !name.isEmpty, !has(Quirk.noMessageName) { entry["name"] = .string(name) }
                out.append(.object(entry))
            case .assistant:
                var entry: [String: JSONValue] = ["role": "assistant"]
                let text = message.text
                let calls = message.toolCalls
                entry["content"] = text.isEmpty && !calls.isEmpty ? JSONValue.null : JSONValue.string(text)
                if !calls.isEmpty {
                    entry["tool_calls"] = .array(calls.map { call -> JSONValue in
                        let function: [String: JSONValue] = [
                            "name": .string(call.name),
                            "arguments": .string(Self.argumentsString(call.arguments)),
                        ]
                        return ["id": .string(call.id), "type": "function", "function": .object(function)]
                    })
                }
                if has(Quirk.preserveReasoningContent) {
                    let reasoning = message.parts.compactMap { part -> String? in
                        if case .reasoning(let r) = part { return r }
                        return nil
                    }.joined()
                    if !reasoning.isEmpty { entry["reasoning_content"] = .string(reasoning) }
                }
                if let name = message.name, !name.isEmpty, !has(Quirk.noMessageName) { entry["name"] = .string(name) }
                out.append(.object(entry))
            case .tool:
                for result in message.toolResults {
                    out.append([
                        "role": "tool",
                        "tool_call_id": .string(result.callID),
                        "content": .string(Transcript.resultText(result)),
                    ])
                    pendingToolImages += result.images
                }
                let stray = message.text
                if !stray.isEmpty { out.append(["role": "user", "content": .string(stray)]) }
            }
        }
        flushToolImages()
        if !pendingSystem.isEmpty {
            out.append(["role": "user", "content": .string(pendingSystem.joined(separator: "\n\n"))])
        }
        return out
    }

    static func argumentsString(_ arguments: JSONValue) -> String {
        if case .string(let raw) = arguments { return raw }
        return arguments.jsonString()
    }

    // MARK: LLMClient

    public func stream(messages: [ChatMessage], tools: [ToolSpec], options: GenerationOptions)
        -> AsyncThrowingStream<StreamEvent, Error> {
        let streaming = usesStreaming
        let request: HTTPRequest
        do {
            let body = try makeRequestBody(messages: messages, tools: tools, options: options, stream: streaming)
            request = try http.request(url: try endpoint.url("chat/completions"), method: "POST",
                                       headers: endpoint.headers(), json: body, stream: streaming)
        } catch {
            return StreamPump.failing(error)
        }
        let http = self.http
        let thinkTags = has(Quirk.thinkTagsInContent)
        return StreamPump.run { continuation in
            var state = OpenAIChatStreamState(splitThinkTags: thinkTags)
            if streaming {
                var parser = SSEParser()
                let chunks = try await http.stream(request)
                streamLoop: for try await chunk in chunks {
                    for event in parser.feed(chunk) {
                        if event.isDone { break streamLoop }
                        for out in try state.handle(sse: event) { continuation.yield(out) }
                    }
                }
                for event in parser.finish() where !event.isDone {
                    for out in try state.handle(sse: event) { continuation.yield(out) }
                }
            } else {
                let response = try await http.send(request)
                for out in try state.handle(completion: try HTTPClient.decodeJSON(response)) { continuation.yield(out) }
            }
            for out in state.finish() { continuation.yield(out) }
        }
    }

    public func listModels() async throws -> [ModelInfo] {
        try await OpenAICompatible.listModels(http: http, endpoint: endpoint, modelsEndpoint: modelsEndpoint,
                                              catalog: catalogModels, template: capabilities)
    }

    public func embed(texts: [String], model: String?) async throws -> [[Float]] {
        try await OpenAICompatible.embed(http: http, endpoint: endpoint, texts: texts,
                                         model: model ?? quirks.value(Quirk.embeddingModel) ?? self.model.model)
    }
}

/// Parses Chat Completions chunks (streaming) or a whole completion (non-streaming).
struct OpenAIChatStreamState {
    var assembler = ToolCallAssembler()
    var usage: Usage?
    var finishReason: FinishReason?
    var splitter: ThinkTagSplitter?

    init(splitThinkTags: Bool) {
        splitter = splitThinkTags ? ThinkTagSplitter() : nil
    }

    mutating func handle(sse event: SSEEvent) throws -> [StreamEvent] {
        let trimmed = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let json: JSONValue
        do {
            json = try JSONValue.parse(trimmed)
        } catch {
            throw ZError.decoding("Unreadable stream chunk: \(String(trimmed.prefix(200)))")
        }
        return try handle(chunk: json)
    }

    mutating func handle(chunk: JSONValue) throws -> [StreamEvent] {
        if let error = chunk["error"], !error.isNull { throw ProviderErrorMapper.streamError(chunk) }
        readUsage(chunk)
        var events: [StreamEvent] = []
        guard let choice = chunk["choices"]?[0] else { return events }
        let delta = choice["delta"] ?? choice["message"] ?? .object([:])
        if let reasoning = delta["reasoning_content"]?.stringValue ?? delta["reasoning"]?.stringValue, !reasoning.isEmpty {
            events.append(.reasoningDelta(reasoning))
        }
        if let content = delta["content"]?.stringValue, !content.isEmpty {
            events += text(content)
        }
        for (position, call) in (delta["tool_calls"]?.arrayValue ?? []).enumerated() {
            let function = call["function"]
            var arguments = function?["arguments"]
            if let a = arguments, a.stringValue == nil, !a.isNull { arguments = .string(a.jsonString()) }
            events += assembler.ingest(index: call["index"]?.lenientInt ?? (call["id"] == nil ? position : nil),
                                       id: call["id"]?.stringValue,
                                       name: function?["name"]?.stringValue,
                                       argumentsDelta: arguments?.stringValue)
        }
        if let reason = FinishReasons.openAI(choice["finish_reason"]?.stringValue) { finishReason = reason }
        return events
    }

    /// A non-streaming completion: same parsing with `message` instead of `delta`.
    mutating func handle(completion: JSONValue) throws -> [StreamEvent] {
        try handle(chunk: completion)
    }

    private mutating func text(_ content: String) -> [StreamEvent] {
        guard var splitter else { return [.textDelta(content)] }
        let events = splitter.feed(content)
        self.splitter = splitter
        return events
    }

    private mutating func readUsage(_ chunk: JSONValue) {
        guard let u = chunk["usage"], u.objectValue != nil else { return }
        let input = u["prompt_tokens"]?.lenientInt ?? u["input_tokens"]?.lenientInt ?? 0
        let output = u["completion_tokens"]?.lenientInt ?? u["output_tokens"]?.lenientInt ?? 0
        let cached = u["prompt_tokens_details"]?["cached_tokens"]?.lenientInt ?? u["prompt_cache_hit_tokens"]?.lenientInt ?? 0
        usage = Usage(inputTokens: input, outputTokens: output, cachedInputTokens: cached)
    }

    mutating func finish() -> [StreamEvent] {
        var events: [StreamEvent] = []
        if var splitter {
            events += splitter.flush()
            self.splitter = splitter
        }
        let calls = assembler.finish()
        events += calls.map { StreamEvent.toolCall($0) }
        if let usage { events.append(.usage(usage)) }
        var reason = finishReason ?? (calls.isEmpty ? .stop : .toolCalls)
        if !calls.isEmpty, reason == .stop { reason = .toolCalls }
        events.append(.finished(reason))
        return events
    }
}

/// `/models` and `/embeddings`, shared by the Chat Completions and Responses clients.
enum OpenAICompatible {
    static func listModels(http: HTTPClient, endpoint: ProviderEndpoint, modelsEndpoint: String?, catalog: [ModelInfo],
                           template: ModelCapabilities) async throws -> [ModelInfo] {
        guard let path = modelsEndpoint, !path.isEmpty else { return catalog }
        let json: JSONValue
        do {
            json = try await http.getJSON(try endpoint.url(path), headers: endpoint.headers())
        } catch ZError.http(let status, _) where status == 404 || status == 405 {
            return catalog
        }
        let items = json["data"]?.arrayValue ?? json["models"]?.arrayValue ?? json.arrayValue ?? []
        var byID: [String: ModelInfo] = [:]
        for info in catalog { byID[info.id] = info }
        var out: [ModelInfo] = []
        var seen = Set<String>()
        for item in items {
            guard let id = item["id"]?.stringValue ?? item["key"]?.stringValue ?? item["name"]?.stringValue,
                  !id.isEmpty, !seen.contains(id) else { continue }
            seen.insert(id)
            if let known = byID[id] {
                out.append(known)
            } else {
                var caps = ModelCapabilities(vision: false, tools: template.tools, streaming: template.streaming,
                                             jsonMode: template.jsonMode)
                caps.contextWindow = item["context_length"]?.lenientInt ?? item["context_window"]?.lenientInt
                    ?? item["max_model_len"]?.lenientInt
                let name = item["name"]?.stringValue ?? item["display_name"]?.stringValue
                out.append(ModelInfo(id: id, displayName: name, capabilities: caps,
                                     free: id.hasSuffix(":free")))
            }
        }
        return out
    }

    static func embed(http: HTTPClient, endpoint: ProviderEndpoint, texts: [String], model: String) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let body: JSONValue = ["model": .string(model), "input": .array(texts.map { .string($0) })]
        let json = try await http.postJSON(try endpoint.url("embeddings"), headers: endpoint.headers(), body: body)
        guard let data = json["data"]?.arrayValue else {
            throw ZError.decoding("Embeddings response without data")
        }
        let ordered = data.enumerated().sorted { a, b in
            (a.element["index"]?.lenientInt ?? a.offset) < (b.element["index"]?.lenientInt ?? b.offset)
        }
        return try ordered.map { item in
            guard let values = item.element["embedding"]?.arrayValue else {
                throw ZError.decoding("Embedding item without a vector")
            }
            return values.compactMap { value -> Float? in value.doubleValue.map { Float($0) } }
        }
    }
}
