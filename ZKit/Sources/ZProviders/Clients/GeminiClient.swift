import Foundation
import ZCore

/// Google Gemini API: `POST {base}/models/{model}:streamGenerateContent?alt=sse` (or `:generateContent` when not
/// streaming), header `x-goog-api-key`, `functionDeclarations`, `inlineData` images, `embedContent`.
///
/// Native computer use (research §8, B2.3, B3) when the model's `nativeComputerUse == .geminiComputer` and a
/// `ToolSpec` carries that kind: `metadata["declaration"]` is sent verbatim as a tool entry, else
/// `{"computerUse": {"environment": "ENVIRONMENT_DESKTOP", "excludedPredefinedFunctions": ["key_down", "key_up"]}}`.
/// UNVERIFIED (research B8.5): `computerUse` on `generateContent` (every guide example uses the Interactions API).
/// Predefined functions come back as plain `functionCall`s; names that are not our own declarations become
/// `ToolCall(name: "computer.<function>")` with the model's 0–999 grid coordinates untouched. Results go back as
/// `functionResponse {id?, name, response, parts: [inlineData]}`: the result's first text part is used as the
/// `response` object when it is JSON (the ZAgent bridge puts `safety_acknowledgement` there), images go in `parts`.
///
/// `FunctionCall.id` is optional: a local id (`zc-gemini-…`) is synthesised and only model-sent ids are echoed.
/// Gemini 3 thought signatures are remembered per call id (process-wide) and replayed on the matching
/// `functionCall` part; when one is missing, the documented validator-skip value is sent on the first call of a turn
/// (UNVERIFIED whether a hand-rolled client needs it; research B8.5).
public struct GeminiClient: LLMClient {
    public let model: ModelRef
    public let capabilities: ModelCapabilities
    public let endpoint: ProviderEndpoint
    public let quirks: QuirkSet
    public let http: HTTPClient
    public let modelsEndpoint: String?
    public let catalogModels: [ModelInfo]

    static let syntheticIDPrefix = "zc-gemini-"
    /// UNVERIFIED: value Google documents for replaying function calls whose signature was lost.
    static let skipSignature = "skip_thought_signature_validator"
    public static let defaultComputerDeclaration: JSONValue = [
        "computerUse": ["environment": "ENVIRONMENT_DESKTOP", "excludedPredefinedFunctions": ["key_down", "key_up"]],
    ]

    public init(model: ModelRef, capabilities: ModelCapabilities, endpoint: ProviderEndpoint, http: HTTPClient,
                quirks: QuirkSet = .empty, modelsEndpoint: String? = "/models", catalogModels: [ModelInfo] = []) {
        self.model = model; self.capabilities = capabilities; self.endpoint = endpoint; self.http = http
        self.quirks = quirks; self.modelsEndpoint = modelsEndpoint; self.catalogModels = catalogModels
    }

    var modelPath: String {
        let id = model.model.hasPrefix("models/") ? String(model.model.dropFirst("models/".count)) : model.model
        return "models/\(id)"
    }

    var usesStreaming: Bool { capabilities.streaming && !quirks.applies(Quirk.noStreaming, toModel: model.model) }

    struct ToolSetup: Sendable {
        var entries: [JSONValue] = []
        var declaredNames: Set<String> = []
        var computerActive = false
    }

    // MARK: Request

    func encodeTools(_ tools: [ToolSpec]) -> ToolSetup {
        var setup = ToolSetup()
        var declarations: [JSONValue] = []
        var natives: [JSONValue] = []
        for spec in tools {
            if spec.native == .geminiComputer, capabilities.nativeComputerUse == .geminiComputer {
                natives.append(NativeToolNaming.declaration(of: spec) ?? Self.defaultComputerDeclaration)
                setup.computerActive = true
            } else {
                var declaration: [String: JSONValue] = ["name": .string(spec.name), "description": .string(spec.description)]
                let schema = Self.geminiSchema(spec.parameters)
                if let properties = schema["properties"]?.objectValue, !properties.isEmpty {
                    declaration["parameters"] = schema
                } else if schema["type"]?.stringValue != "object", schema.objectValue?.isEmpty == false {
                    declaration["parameters"] = schema
                }
                declarations.append(.object(declaration))
                setup.declaredNames.insert(spec.name)
            }
        }
        if !declarations.isEmpty { setup.entries.append(["functionDeclarations": .array(declarations)]) }
        setup.entries += natives
        return setup
    }

    /// Builds the request body. `signatures` maps tool call ids to remembered thought signatures.
    public func makeRequestBody(messages: [ChatMessage], tools: [ToolSpec], options: GenerationOptions,
                                signatures: [String: String] = [:]) throws -> JSONValue {
        let setup = encodeTools(tools)
        let allowSkipSignature = capabilities.nativeComputerUse == .geminiComputer || options.reasoningEffort != nil
        var body: [String: JSONValue] = [
            "contents": .array(encodeContents(messages, signatures: signatures, allowSkipSignature: allowSkipSignature)),
        ]
        let system = Transcript.systemText(messages)
        if !system.isEmpty { body["systemInstruction"] = ["parts": [["text": .string(system)]]] }
        if !setup.entries.isEmpty { body["tools"] = .array(setup.entries) }

        var config: [String: JSONValue] = [:]
        if let temperature = options.temperature { config["temperature"] = .number(temperature) }
        if let maxTokens = options.maxTokens { config["maxOutputTokens"] = .number(Double(maxTokens)) }
        if !options.stop.isEmpty { config["stopSequences"] = .array(options.stop.map { .string($0) }) }
        if options.jsonMode, !quirks.applies(Quirk.noJSONMode, toModel: model.model) {
            config["responseMimeType"] = "application/json"
        }
        if let effort = options.reasoningEffort {
            config["thinkingConfig"] = ["thinkingLevel": .string(thinkingLevel(effort)), "includeThoughts": true]
        }
        if !config.isEmpty { body["generationConfig"] = .object(config) }
        for (key, value) in options.extra { body[key] = value }
        return .object(body)
    }

    func thinkingLevel(_ effort: String) -> String {
        switch effort.lowercased() {
        case "none", "minimal":
            return quirks.applies(Quirk.thinkingMinimalUnsupported, toModel: model.model) ? "low" : "minimal"
        case "low": return "low"
        case "medium": return "medium"
        default: return "high"
        }
    }

    func encodeContents(_ messages: [ChatMessage], signatures: [String: String], allowSkipSignature: Bool) -> [JSONValue] {
        let calls = Transcript.callIndex(messages)
        var turns: [(role: String, parts: [JSONValue])] = []

        func append(_ role: String, _ parts: [JSONValue]) {
            guard !parts.isEmpty else { return }
            if let last = turns.last, last.role == role {
                turns[turns.count - 1].parts += parts
            } else {
                turns.append((role, parts))
            }
        }

        for message in messages {
            switch message.role {
            case .system:
                continue
            case .user:
                var parts: [JSONValue] = []
                for part in message.parts {
                    switch part {
                    case .text(let t) where !t.isEmpty: parts.append(["text": .string(t)])
                    case .image(let image): parts.append(Self.inlineData(image))
                    case .toolResult(let r): parts.append(functionResponsePart(r, calls: calls))
                    default: break
                    }
                }
                append("user", parts)
            case .assistant:
                var parts: [JSONValue] = []
                var firstCall = true
                for part in message.parts {
                    switch part {
                    case .text(let t) where !t.isEmpty:
                        parts.append(["text": .string(t)])
                    case .toolUse(let call):
                        var functionCall: [String: JSONValue] = [
                            "name": .string(Self.nativeName(call.name)),
                            "args": .object(call.arguments.asArgumentsObject),
                        ]
                        if !call.id.hasPrefix(Self.syntheticIDPrefix) { functionCall["id"] = .string(call.id) }
                        var entry: [String: JSONValue] = ["functionCall": .object(functionCall)]
                        if let signature = signatures[call.id] {
                            entry["thoughtSignature"] = .string(signature)
                        } else if firstCall, allowSkipSignature {
                            entry["thoughtSignature"] = .string(Self.skipSignature)
                        }
                        firstCall = false
                        parts.append(.object(entry))
                    default:
                        break   // reasoning (thought summaries) is not replayed
                    }
                }
                append("model", parts)
            case .tool:
                var parts = message.toolResults.map { functionResponsePart($0, calls: calls) }
                let stray = message.text
                if !stray.isEmpty { parts.append(["text": .string(stray)]) }
                append("user", parts)
            }
        }
        return turns.map { turn -> JSONValue in
            ["role": .string(turn.role), "parts": .array(turn.parts)]
        }
    }

    static func nativeName(_ name: String) -> String { NativeToolNaming.member(of: name) ?? name }

    static func inlineData(_ image: ImageData) -> JSONValue {
        ["inlineData": ["mimeType": .string(image.mimeType), "data": .string(image.base64)]]
    }

    func functionResponsePart(_ result: ToolResult, calls: [String: ToolCall]) -> JSONValue {
        let call = calls[result.callID]
        var response: [String: JSONValue]
        let texts = result.parts.compactMap { part -> String? in
            if case .text(let t) = part { return t }
            return nil
        }
        if result.isError {
            response = ["error": .string(result.text.isEmpty ? "The tool failed." : result.text)]
        } else if let first = texts.first, let object = (try? JSONValue.parse(first))?.objectValue {
            response = object
            let rest = texts.dropFirst().joined(separator: "\n")
            if !rest.isEmpty { response["output"] = .string(rest) }
        } else {
            response = ["output": .string(Transcript.resultText(result))]
        }
        if !result.isError, call?.arguments["safety_decision"]?["decision"]?.stringValue == "require_confirmation",
           response["safety_acknowledgement"] == nil {
            response["safety_acknowledgement"] = true
        }
        var functionResponse: [String: JSONValue] = [
            "name": .string(Self.nativeName(call?.name ?? "tool")),
            "response": .object(response),
        ]
        if !result.callID.hasPrefix(Self.syntheticIDPrefix) { functionResponse["id"] = .string(result.callID) }
        let images = result.images
        if !images.isEmpty {
            // UNVERIFIED for models before Gemini 3: multimodal function responses (`FunctionResponse.parts`).
            functionResponse["parts"] = .array(images.map(Self.inlineData))
        }
        return ["functionResponse": .object(functionResponse)]
    }

    /// Reduces a JSON schema to the OpenAPI subset Gemini's `Schema` accepts (drops `additionalProperties`, `$schema`,
    /// `strict`, …; `["integer", "null"]` → `integer` + `nullable`).
    public static func geminiSchema(_ schema: JSONValue) -> JSONValue {
        guard case .object(let object) = schema else { return schema }
        let passThrough: Set<String> = ["description", "enum", "required", "format", "nullable", "minimum", "maximum",
                                        "minItems", "maxItems", "minLength", "maxLength", "pattern", "title",
                                        "propertyOrdering", "default", "example", "minProperties", "maxProperties"]
        var out: [String: JSONValue] = [:]
        for (key, value) in object {
            switch key {
            case "type":
                if case .array(let types) = value {
                    let names = types.compactMap(\.stringValue)
                    out["type"] = .string(names.first(where: { $0 != "null" }) ?? "string")
                    if names.contains("null") { out["nullable"] = true }
                } else {
                    out["type"] = value
                }
            case "properties":
                if case .object(let properties) = value {
                    out["properties"] = .object(properties.mapValues { geminiSchema($0) })
                }
            case "items":
                out["items"] = geminiSchema(value)
            case "anyOf":
                if case .array(let options) = value { out["anyOf"] = .array(options.map { geminiSchema($0) }) }
            default:
                if passThrough.contains(key) { out[key] = value }
            }
        }
        return .object(out)
    }

    // MARK: LLMClient

    public func stream(messages: [ChatMessage], tools: [ToolSpec], options: GenerationOptions)
        -> AsyncThrowingStream<StreamEvent, Error> {
        let client = self
        return StreamPump.run { continuation in
            var signatures: [String: String] = [:]
            for message in messages where message.role == .assistant {
                for call in message.toolCalls {
                    if let signature = await KeyedMemo.geminiThoughtSignatures.get(call.id) { signatures[call.id] = signature }
                }
            }
            let body = try client.makeRequestBody(messages: messages, tools: tools, options: options, signatures: signatures)
            let setup = client.encodeTools(tools)
            var state = GeminiStreamState(computerActive: setup.computerActive, declaredNames: setup.declaredNames)
            if client.usesStreaming {
                let url = try client.endpoint.url("\(client.modelPath):streamGenerateContent",
                                                  query: [URLQueryItem(name: "alt", value: "sse")])
                let request = try client.http.request(url: url, method: "POST", headers: client.endpoint.headers(),
                                                      json: body, stream: true)
                var parser = SSEParser()
                let chunks = try await client.http.stream(request)
                for try await chunk in chunks {
                    for event in parser.feed(chunk) {
                        for out in try state.handle(sse: event) { continuation.yield(out) }
                    }
                }
                for event in parser.finish() {
                    for out in try state.handle(sse: event) { continuation.yield(out) }
                }
            } else {
                let url = try client.endpoint.url("\(client.modelPath):generateContent")
                let json = try await client.http.postJSON(url, headers: client.endpoint.headers(), body: body)
                for out in try state.handle(json) { continuation.yield(out) }
            }
            for (id, signature) in state.signatures {
                await KeyedMemo.geminiThoughtSignatures.set(signature, for: id)
            }
            for out in state.finish() { continuation.yield(out) }
        }
    }

    public func listModels() async throws -> [ModelInfo] {
        guard let path = modelsEndpoint, !path.isEmpty else { return catalogModels }
        var known: [String: ModelInfo] = [:]
        for info in catalogModels { known[info.id] = info }
        var out: [ModelInfo] = []
        var pageToken: String?
        for _ in 0..<10 {
            var query = [URLQueryItem(name: "pageSize", value: "1000")]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let json = try await http.getJSON(try endpoint.url(path, query: query), headers: endpoint.headers())
            for item in json["models"]?.arrayValue ?? [] {
                guard let name = item["name"]?.stringValue else { continue }
                let id = name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
                let methods = item["supportedGenerationMethods"]?.arrayValue?.compactMap(\.stringValue) ?? []
                guard methods.isEmpty || methods.contains("generateContent") else { continue }
                if let info = known[id] {
                    out.append(info)
                } else {
                    let caps = ModelCapabilities(vision: true, tools: true, streaming: true, jsonMode: true,
                                                 contextWindow: item["inputTokenLimit"]?.lenientInt,
                                                 maxOutputTokens: item["outputTokenLimit"]?.lenientInt)
                    out.append(ModelInfo(id: id, displayName: item["displayName"]?.stringValue, capabilities: caps))
                }
            }
            guard let next = json["nextPageToken"]?.stringValue, !next.isEmpty else { break }
            pageToken = next
        }
        return out
    }

    public func embed(texts: [String], model: String?) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let rawID = model ?? quirks.value(Quirk.embeddingModel) ?? self.model.model
        let id = rawID.hasPrefix("models/") ? String(rawID.dropFirst("models/".count)) : rawID
        if texts.count == 1 {
            let body: JSONValue = ["content": ["parts": [["text": .string(texts[0])]]]]
            let json = try await http.postJSON(try endpoint.url("models/\(id):embedContent"), headers: endpoint.headers(),
                                               body: body)
            guard let values = json["embedding"]?["values"]?.arrayValue else {
                throw ZError.decoding("embedContent response without embedding.values")
            }
            return [Self.floats(values)]
        }
        let requests: [JSONValue] = texts.map { text -> JSONValue in
            ["model": .string("models/\(id)"), "content": ["parts": [["text": .string(text)]]]]
        }
        let json = try await http.postJSON(try endpoint.url("models/\(id):batchEmbedContents"),
                                           headers: endpoint.headers(), body: ["requests": .array(requests)])
        guard let embeddings = json["embeddings"]?.arrayValue else {
            throw ZError.decoding("batchEmbedContents response without embeddings")
        }
        return embeddings.map { Self.floats($0["values"]?.arrayValue ?? []) }
    }

    static func floats(_ values: [JSONValue]) -> [Float] {
        values.compactMap { value -> Float? in value.doubleValue.map { Float($0) } }
    }
}

/// Parses `GenerateContentResponse` chunks.
struct GeminiStreamState {
    let computerActive: Bool
    let declaredNames: Set<String>
    var signatures: [(String, String)] = []
    var finishReason: String?
    var blocked = false
    var usage: Usage?
    var callCount = 0

    init(computerActive: Bool, declaredNames: Set<String>) {
        self.computerActive = computerActive
        self.declaredNames = declaredNames
    }

    mutating func handle(sse event: SSEEvent) throws -> [StreamEvent] {
        let trimmed = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let json = try? JSONValue.parse(trimmed) else {
            throw ZError.decoding("Unreadable Gemini chunk: \(String(trimmed.prefix(200)))")
        }
        return try handle(json)
    }

    mutating func handle(_ json: JSONValue) throws -> [StreamEvent] {
        if case .array(let items) = json {           // a non-SSE streamGenerateContent body is a JSON array
            var events: [StreamEvent] = []
            for item in items { events += try handle(item) }
            return events
        }
        if let error = json["error"], !error.isNull { throw ProviderErrorMapper.streamError(json) }
        if json["promptFeedback"]?["blockReason"]?.stringValue != nil { blocked = true }
        if let u = json["usageMetadata"], u.objectValue != nil {
            let output = (u["candidatesTokenCount"]?.lenientInt ?? 0) + (u["thoughtsTokenCount"]?.lenientInt ?? 0)
            usage = Usage(inputTokens: u["promptTokenCount"]?.lenientInt ?? 0, outputTokens: output,
                          cachedInputTokens: u["cachedContentTokenCount"]?.lenientInt ?? 0)
        }
        guard let candidate = json["candidates"]?[0] else { return [] }
        var events: [StreamEvent] = []
        for part in candidate["content"]?["parts"]?.arrayValue ?? [] {
            if let call = part["functionCall"], call.objectValue != nil {
                let rawName = call["name"]?.stringValue ?? ""
                let name = computerActive && !declaredNames.contains(rawName) ? NativeToolNaming.memberCall(rawName) : rawName
                let modelID = call["id"]?.stringValue
                let id = (modelID?.isEmpty == false ? modelID : nil)
                    ?? GeminiClient.syntheticIDPrefix + UUID().uuidString.lowercased()
                if let signature = part["thoughtSignature"]?.stringValue, !signature.isEmpty {
                    signatures.append((id, signature))
                }
                let arguments = call["args"].map { $0.isNull ? JSONValue.object([:]) : $0 } ?? .object([:])
                callCount += 1
                events.append(.toolCallStart(id: id, name: name))
                events.append(.toolCall(ToolCall(id: id, name: name, arguments: arguments)))
            } else if let text = part["text"]?.stringValue, !text.isEmpty {
                events.append(part["thought"]?.boolValue == true ? .reasoningDelta(text) : .textDelta(text))
            }
        }
        if let reason = candidate["finishReason"]?.stringValue { finishReason = reason }
        return events
    }

    func finish() -> [StreamEvent] {
        var events: [StreamEvent] = []
        if let usage { events.append(.usage(usage)) }
        let reason: FinishReason
        if blocked {
            reason = .contentFilter
        } else {
            switch finishReason {
            case "STOP"?, nil: reason = callCount > 0 ? .toolCalls : .stop
            case "MAX_TOKENS"?: reason = .length
            case "SAFETY"?, "RECITATION"?, "BLOCKLIST"?, "PROHIBITED_CONTENT"?, "SPII"?, "IMAGE_SAFETY"?:
                reason = .contentFilter
            default: reason = callCount > 0 ? .toolCalls : .other
            }
        }
        events.append(.finished(reason))
        return events
    }
}
