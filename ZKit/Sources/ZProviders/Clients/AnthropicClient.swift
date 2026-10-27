import Foundation
import ZCore

/// Anthropic Messages API (`POST {base}/messages`, headers `x-api-key` + `anthropic-version`), streaming.
///
/// Native tools (docs/research/local-models-and-agent-loops.md §6, B2.1, B3), used when the model's
/// `nativeComputerUse == .anthropicComputer` and the `ToolSpec` carries the native kind:
/// * computer: `metadata["declaration"]` verbatim (plus `metadata["beta_header"]`), else
///   `{"type": "computer_toolset_20260801", "configs": {"hold_key": {"enabled": false}, "zoom": {"enabled": false}}}`
///   (GA, no beta header; version from `metadata["toolVersion"]` or the `computerToolset:` quirk). Toolset member calls
///   arrive as separately named `tool_use` blocks tagged `"toolset_name": "computer"`; they become
///   `ToolCall(name: "computer.<member>")` and every `tool_use` / `tool_result` sent back echoes the tag. Legacy
///   `computer_20251124` / `computer_20250124` (`name: "computer"`, display size, beta header
///   `computer-use-2025-11-24` / `computer-use-2025-01-24`) keep `ToolCall(name: "computer", arguments: {action…})`.
/// * bash: `{"type": "bash_20250124", "name": "bash"}`; text editor: `{"type": "text_editor_20250728",
///   "name": "str_replace_based_edit_tool"}`. Calls are renamed to the agent's spec names and back.
///
/// Thinking: `options.reasoningEffort` → `thinking: {type: "adaptive", display: "summarized"}` +
/// `output_config: {effort}`; `thinking_delta` → `.reasoningDelta`. Thinking blocks are never replayed (ZCore keeps
/// no signatures, and agents edit history, which would invalidate replayed blocks); removing every thinking block is
/// the documented-safe form. Sampling parameters (`temperature`) are not sent: current Claude models reject them —
/// pass them through `options.extra` for older models if needed.
public struct AnthropicClient: LLMClient {
    public let model: ModelRef
    public let capabilities: ModelCapabilities
    public let endpoint: ProviderEndpoint
    public let quirks: QuirkSet
    public let http: HTTPClient
    public let modelsEndpoint: String?
    public let catalogModels: [ModelInfo]
    /// `max_tokens` when neither the options nor the capabilities give one (the field is required).
    public var defaultMaxTokens: Int = 64_000

    public static let defaultVersion = "2023-06-01"
    public static let defaultComputerToolset = "computer_toolset_20260801"
    public static let bashTool: JSONValue = ["type": "bash_20250124", "name": "bash"]
    public static let textEditorTool: JSONValue = ["type": "text_editor_20250728", "name": "str_replace_based_edit_tool"]

    public init(model: ModelRef, capabilities: ModelCapabilities, endpoint: ProviderEndpoint, http: HTTPClient,
                quirks: QuirkSet = .empty, modelsEndpoint: String? = "/models", catalogModels: [ModelInfo] = []) {
        self.model = model; self.capabilities = capabilities; self.endpoint = endpoint; self.http = http
        self.quirks = quirks; self.modelsEndpoint = modelsEndpoint; self.catalogModels = catalogModels
    }

    /// What the native tools of one request look like on the wire.
    struct NativeSetup: Sendable {
        var computerType: String?
        /// Native tool name → agent spec name (bash, text editor).
        var nativeToSpec: [String: String] = [:]
        var specToNative: [String: String] = [:]
        var betas: [String] = []

        var isLegacyComputer: Bool {
            guard let type = computerType else { return false }
            return !type.hasPrefix("computer_toolset")
        }
        var isToolset: Bool { computerType?.hasPrefix("computer_toolset") ?? false }
    }

    static func betaHeader(forComputerType type: String) -> String? {
        switch type {
        case "computer_20251124": return "computer-use-2025-11-24"
        case "computer_20250124": return "computer-use-2025-01-24"
        default: return nil
        }
    }

    // MARK: Request

    /// The request body and the extra headers (`anthropic-version`, `anthropic-beta`).
    public func makeRequest(messages: [ChatMessage], tools: [ToolSpec], options: GenerationOptions)
        throws -> (body: JSONValue, headers: [String: String]) {
        let (toolEntries, setup) = try encodeTools(tools)
        var body: [String: JSONValue] = [
            "model": .string(model.model),
            "max_tokens": .number(Double(options.maxTokens ?? capabilities.maxOutputTokens ?? defaultMaxTokens)),
            "messages": .array(encodeMessages(messages, setup: setup)),
            "stream": true,
        ]
        let system = Transcript.systemText(messages)
        if !system.isEmpty { body["system"] = .string(system) }
        if !toolEntries.isEmpty { body["tools"] = .array(toolEntries) }
        if !options.stop.isEmpty { body["stop_sequences"] = .array(options.stop.map { .string($0) }) }
        if let effort = options.reasoningEffort {
            body["thinking"] = ["type": "adaptive", "display": "summarized"]
            body["output_config"] = ["effort": .string(Self.effortLevel(effort))]
        }
        for (key, value) in options.extra { body[key] = value }

        var headers: [String: String] = ["anthropic-version": quirks.value(Quirk.anthropicVersion) ?? Self.defaultVersion]
        var betas: [String] = []
        for beta in setup.betas where !betas.contains(beta) { betas.append(beta) }
        if !betas.isEmpty { headers["anthropic-beta"] = betas.joined(separator: ",") }
        return (.object(body), headers)
    }

    static func effortLevel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "none", "minimal": return "low"
        default: return raw.lowercased()
        }
    }

    func encodeTools(_ tools: [ToolSpec]) throws -> ([JSONValue], NativeSetup) {
        var setup = NativeSetup()
        var natives: [JSONValue] = []
        var functions: [(name: String, entry: JSONValue)] = []
        let nativeOK = capabilities.nativeComputerUse == .anthropicComputer
        for spec in tools {
            switch spec.native {
            case .anthropicComputer? where nativeOK:
                let declaration = try NativeToolNaming.declaration(of: spec) ?? defaultComputerDeclaration(spec)
                let type = declaration["type"]?.stringValue ?? Self.defaultComputerToolset
                setup.computerType = type
                if let beta = spec.metadata["beta_header"]?.stringValue, !beta.isEmpty {
                    setup.betas += beta.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                } else if let beta = Self.betaHeader(forComputerType: type) {
                    setup.betas.append(beta)
                }
                natives.append(declaration)
            case .anthropicBash? where nativeOK, .anthropicTextEditor? where nativeOK:
                let fallback = spec.native == .anthropicBash ? Self.bashTool : Self.textEditorTool
                var declaration = NativeToolNaming.declaration(of: spec) ?? fallback
                if let version = spec.metadata["toolVersion"]?.stringValue, var object = declaration.objectValue {
                    object["type"] = .string(version)
                    declaration = .object(object)
                }
                let nativeName = declaration["name"]?.stringValue ?? (fallback["name"]?.stringValue ?? spec.name)
                setup.nativeToSpec[nativeName] = spec.name
                setup.specToNative[spec.name] = nativeName
                if let beta = spec.metadata["beta_header"]?.stringValue, !beta.isEmpty { setup.betas.append(beta) }
                natives.append(declaration)
            default:
                let entry: JSONValue = [
                    "name": .string(spec.name),
                    "description": .string(spec.description),
                    "input_schema": spec.parameters,
                ]
                functions.append((spec.name, entry))
            }
        }
        // The toolset rejects any other tool named "computer" in the same request.
        if setup.isToolset { functions.removeAll { $0.name == NativeToolNaming.computer } }
        return (natives + functions.map { $0.entry }, setup)
    }

    func defaultComputerDeclaration(_ spec: ToolSpec) throws -> JSONValue {
        let version = spec.metadata["toolVersion"]?.stringValue
            ?? quirks.value(Quirk.computerToolset) ?? Self.defaultComputerToolset
        if version.hasPrefix("computer_toolset") {
            // B3: members we do not implement are disabled rather than answered with errors.
            let disabled = spec.metadata["disabledMembers"]?.arrayValue?.compactMap(\.stringValue) ?? ["hold_key", "zoom"]
            var configs: [String: JSONValue] = [:]
            for member in disabled { configs[member] = ["enabled": false] }
            var entry: [String: JSONValue] = ["type": .string(version)]
            if !configs.isEmpty { entry["configs"] = .object(configs) }
            return .object(entry)
        }
        guard let width = NativeToolNaming.int(spec, ["display_width_px", "displayWidth"]),
              let height = NativeToolNaming.int(spec, ["display_height_px", "displayHeight"]) else {
            throw ZError.invalidArgument("\(version) needs display_width_px / display_height_px in the ToolSpec metadata")
        }
        var entry: [String: JSONValue] = ["type": .string(version), "name": "computer", "display_number": 1]
        entry["display_width_px"] = .number(Double(width))
        entry["display_height_px"] = .number(Double(height))
        // UNVERIFIED (research B8.10): display_*_px is assumed to be the size of the screenshots we send.
        if version == "computer_20251124", spec.metadata["enableZoom"]?.boolValue == true { entry["enable_zoom"] = true }
        return .object(entry)
    }

    func encodeMessages(_ messages: [ChatMessage], setup: NativeSetup) -> [JSONValue] {
        let calls = Transcript.callIndex(messages)
        var turns: [(role: String, content: [JSONValue])] = []

        func append(_ role: String, _ content: [JSONValue]) {
            guard !content.isEmpty else { return }
            if let last = turns.last, last.role == role {
                turns[turns.count - 1].content += content
            } else {
                turns.append((role, content))
            }
        }

        for message in messages {
            switch message.role {
            case .system:
                continue
            case .user:
                var content: [JSONValue] = []
                for part in message.parts {
                    switch part {
                    case .text(let t) where !t.isEmpty: content.append(["type": "text", "text": .string(t)])
                    case .image(let image): content.append(Self.imageBlock(image))
                    case .toolResult(let r): content.append(toolResultBlock(r, calls: calls, setup: setup))
                    default: break
                    }
                }
                append("user", content)
            case .assistant:
                var content: [JSONValue] = []
                for part in message.parts {
                    switch part {
                    case .text(let t) where !t.isEmpty: content.append(["type": "text", "text": .string(t)])
                    case .toolUse(let call): content.append(toolUseBlock(call, setup: setup))
                    default: break   // reasoning is not replayed (see the type comment)
                    }
                }
                append("assistant", content)
            case .tool:
                var content: [JSONValue] = message.toolResults.map { toolResultBlock($0, calls: calls, setup: setup) }
                let stray = message.text
                if !stray.isEmpty { content.append(["type": "text", "text": .string(stray)]) }
                append("user", content)
            }
        }
        return turns.map { turn -> JSONValue in
            ["role": .string(turn.role), "content": .array(turn.content)]
        }
    }

    static func imageBlock(_ image: ImageData) -> JSONValue {
        let source: JSONValue = ["type": "base64", "media_type": .string(image.mimeType), "data": .string(image.base64)]
        return ["type": "image", "source": source]
    }

    func toolUseBlock(_ call: ToolCall, setup: NativeSetup) -> JSONValue {
        var block: [String: JSONValue] = ["type": "tool_use", "id": .string(call.id)]
        var input = call.arguments.asArgumentsObject
        if let member = NativeToolNaming.member(of: call.name) {
            if setup.isLegacyComputer {
                block["name"] = .string(NativeToolNaming.computer)
                input["action"] = .string(member)
            } else {
                block["name"] = .string(member)
                block["toolset_name"] = .string(NativeToolNaming.computer)
            }
        } else if let native = setup.specToNative[call.name] {
            block["name"] = .string(native)
        } else {
            block["name"] = .string(call.name)
        }
        block["input"] = .object(input)
        return .object(block)
    }

    func toolResultBlock(_ result: ToolResult, calls: [String: ToolCall], setup: NativeSetup) -> JSONValue {
        let isToolsetCall = calls[result.callID].map { NativeToolNaming.member(of: $0.name) != nil } ?? false
        var content: [JSONValue] = []
        for part in result.parts {
            switch part {
            case .text(let t) where !t.isEmpty: content.append(["type": "text", "text": .string(t)])
            case .image(let image): content.append(Self.imageBlock(image))
            default: break
            }
        }
        if content.isEmpty { content = [["type": "text", "text": .string(isToolsetCall ? "OK" : "(no output)")]] }
        var block: [String: JSONValue] = ["type": "tool_result", "tool_use_id": .string(result.callID)]
        block["content"] = .array(content)
        if result.isError { block["is_error"] = true }
        if isToolsetCall, !setup.isLegacyComputer { block["toolset_name"] = .string(NativeToolNaming.computer) }
        return .object(block)
    }

    // MARK: LLMClient

    public func stream(messages: [ChatMessage], tools: [ToolSpec], options: GenerationOptions)
        -> AsyncThrowingStream<StreamEvent, Error> {
        let request: HTTPRequest
        let setup: NativeSetup
        do {
            let (body, headers) = try makeRequest(messages: messages, tools: tools, options: options)
            setup = try encodeTools(tools).1
            request = try http.request(url: try endpoint.url("messages"), method: "POST",
                                       headers: endpoint.headers(headers), json: body, stream: true)
        } catch {
            return StreamPump.failing(error)
        }
        let http = self.http
        return StreamPump.run { continuation in
            var state = AnthropicStreamState(nativeToSpec: setup.nativeToSpec)
            var parser = SSEParser()
            let chunks = try await http.stream(request)
            for try await chunk in chunks {
                for event in parser.feed(chunk) {
                    for out in try state.handle(sse: event) { continuation.yield(out) }
                }
            }
            for event in parser.finish() {
                for out in try state.handle(sse: event) { continuation.yield(out) }
            }
            for out in state.finish() { continuation.yield(out) }
        }
    }

    public func listModels() async throws -> [ModelInfo] {
        guard let path = modelsEndpoint, !path.isEmpty else { return catalogModels }
        var known: [String: ModelInfo] = [:]
        for info in catalogModels { known[info.id] = info }
        var out: [ModelInfo] = []
        var after: String?
        let headers = endpoint.headers(["anthropic-version": quirks.value(Quirk.anthropicVersion) ?? Self.defaultVersion])
        for _ in 0..<10 {
            var query = [URLQueryItem(name: "limit", value: "1000")]
            if let after { query.append(URLQueryItem(name: "after_id", value: after)) }
            let json = try await http.getJSON(try endpoint.url(path, query: query), headers: headers)
            for item in json["data"]?.arrayValue ?? [] {
                guard let id = item["id"]?.stringValue else { continue }
                if let info = known[id] {
                    out.append(info)
                } else {
                    // Every current Claude model takes images and tools; native computer use is only known from the catalogue.
                    let caps = ModelCapabilities(vision: true, tools: true, streaming: true, jsonMode: false,
                                                 contextWindow: item["max_input_tokens"]?.lenientInt,
                                                 maxOutputTokens: item["max_tokens"]?.lenientInt)
                    out.append(ModelInfo(id: id, displayName: item["display_name"]?.stringValue, capabilities: caps))
                }
            }
            guard json["has_more"]?.boolValue == true, let last = json["last_id"]?.stringValue else { break }
            after = last
        }
        return out
    }
}

/// Parses Messages API stream events.
struct AnthropicStreamState {
    struct Block {
        var type: String
        var id: String
        var name: String
        var json: String
        var startInput: JSONValue
    }

    let nativeToSpec: [String: String]
    var blocks: [Int: Block] = [:]
    var inputTokens = 0
    var cachedTokens = 0
    var outputTokens = 0
    var sawUsage = false
    var stopReason: String?
    var callCount = 0

    init(nativeToSpec: [String: String]) { self.nativeToSpec = nativeToSpec }

    mutating func handle(sse event: SSEEvent) throws -> [StreamEvent] {
        let trimmed = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let json = try? JSONValue.parse(trimmed) else {
            throw ZError.decoding("Unreadable Anthropic event: \(String(trimmed.prefix(200)))")
        }
        return try handle(json, eventName: event.event)
    }

    mutating func handle(_ json: JSONValue, eventName: String? = nil) throws -> [StreamEvent] {
        let type = json["type"]?.stringValue ?? eventName ?? ""
        switch type {
        case "message_start":
            readUsage(json["message"]?["usage"])
        case "content_block_start":
            guard let index = json["index"]?.lenientInt, let block = json["content_block"] else { return [] }
            let blockType = block["type"]?.stringValue ?? ""
            switch blockType {
            case "tool_use":
                let rawName = block["name"]?.stringValue ?? ""
                let name: String
                if block["toolset_name"]?.stringValue != nil {
                    name = NativeToolNaming.memberCall(rawName)
                } else {
                    name = nativeToSpec[rawName] ?? rawName
                }
                let id = block["id"]?.stringValue ?? ToolCallAssembler.synthesizeID()
                blocks[index] = Block(type: blockType, id: id, name: name, json: "", startInput: block["input"] ?? .object([:]))
                return [.toolCallStart(id: id, name: name)]
            case "text":
                if let text = block["text"]?.stringValue, !text.isEmpty { return [.textDelta(text)] }
            case "thinking":
                if let text = block["thinking"]?.stringValue, !text.isEmpty { return [.reasoningDelta(text)] }
            default:
                break
            }
        case "content_block_delta":
            guard let delta = json["delta"] else { return [] }
            switch delta["type"]?.stringValue ?? "" {
            case "text_delta":
                if let text = delta["text"]?.stringValue, !text.isEmpty { return [.textDelta(text)] }
            case "thinking_delta":
                if let text = delta["thinking"]?.stringValue, !text.isEmpty { return [.reasoningDelta(text)] }
            case "input_json_delta":
                guard let index = json["index"]?.lenientInt, var block = blocks[index],
                      let partial = delta["partial_json"]?.stringValue, !partial.isEmpty else { return [] }
                block.json += partial
                blocks[index] = block
                return [.toolCallDelta(id: block.id, argumentsDelta: partial)]
            default:
                break   // signature_delta, citations_delta, …
            }
        case "content_block_stop":
            guard let index = json["index"]?.lenientInt, let block = blocks.removeValue(forKey: index),
                  block.type == "tool_use" else { return [] }
            let arguments = block.json.isEmpty ? block.startInput : ToolCallAssembler.parseArguments(block.json)
            callCount += 1
            return [.toolCall(ToolCall(id: block.id, name: block.name, arguments: arguments))]
        case "message_delta":
            if let reason = json["delta"]?["stop_reason"]?.stringValue { stopReason = reason }
            readUsage(json["usage"])
        case "error":
            throw ProviderErrorMapper.streamError(json)
        default:
            break   // message_stop, ping
        }
        return []
    }

    private mutating func readUsage(_ value: JSONValue?) {
        guard let u = value, u.objectValue != nil else { return }
        sawUsage = true
        let cacheRead = u["cache_read_input_tokens"]?.lenientInt
        let cacheWrite = u["cache_creation_input_tokens"]?.lenientInt
        if let input = u["input_tokens"]?.lenientInt {
            inputTokens = input + (cacheRead ?? 0) + (cacheWrite ?? 0)
        }
        if let cacheRead { cachedTokens = cacheRead }
        if let output = u["output_tokens"]?.lenientInt { outputTokens = output }
    }

    func finish() -> [StreamEvent] {
        var events: [StreamEvent] = []
        if sawUsage {
            events.append(.usage(Usage(inputTokens: inputTokens, outputTokens: outputTokens, cachedInputTokens: cachedTokens)))
        }
        let reason: FinishReason
        switch stopReason {
        case "end_turn"?, "stop_sequence"?: reason = callCount > 0 ? .toolCalls : .stop
        case "max_tokens"?, "model_context_window_exceeded"?: reason = .length
        case "tool_use"?: reason = .toolCalls
        case "refusal"?: reason = .contentFilter
        case nil: reason = callCount > 0 ? .toolCalls : .stop
        default: reason = .other
        }
        events.append(.finished(reason))
        return events
    }
}
