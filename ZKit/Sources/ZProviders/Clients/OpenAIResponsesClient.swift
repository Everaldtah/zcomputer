import Foundation
import ZCore

/// OpenAI Responses API (`POST {base}/responses`), used for models whose `nativeComputerUse == .openAIComputer` and for
/// models whose tool calling only works there (quirk `toolsRequireResponsesAPI`).
///
/// Native computer use follows docs/research/local-models-and-agent-loops.md §7 and B2.2/B3/B4:
/// * declaration `{"type": "computer"}` (GA; no display size — the `computer_use_preview` shape with
///   `display_width`/`display_height`/`environment` is only sent when the provider quirk asks for that legacy type);
/// * each `computer_call` output item (batched `actions[]`, `pending_safety_checks`) becomes ONE ZCore `ToolCall`
///   `(id: call_id, name: "computer", arguments: {"actions": [...], "pending_safety_checks": [...], "response_id": ...})`
///   (the ZAgent `NativeComputerBridge` contract);
/// * its result is sent back as `computer_call_output` with `output: {type: "computer_screenshot", image_url:
///   data URL, detail: "original"}` and `acknowledged_safety_checks` = the call's pending checks when the result is
///   not an error (the agent only runs a call with pending checks after a human approved them);
/// * turns continue with `previous_response_id` (the doc's loop): the response id is kept in the call's arguments
///   and in a process-wide memo keyed by call id, and only the items after that turn are sent.
public struct OpenAIResponsesClient: LLMClient {
    public let model: ModelRef
    public let capabilities: ModelCapabilities
    public let endpoint: ProviderEndpoint
    public let quirks: QuirkSet
    public let http: HTTPClient
    public let modelsEndpoint: String?
    public let catalogModels: [ModelInfo]

    public init(model: ModelRef, capabilities: ModelCapabilities, endpoint: ProviderEndpoint, http: HTTPClient,
                quirks: QuirkSet = .empty, modelsEndpoint: String? = "/models", catalogModels: [ModelInfo] = []) {
        self.model = model; self.capabilities = capabilities; self.endpoint = endpoint; self.http = http
        self.quirks = quirks; self.modelsEndpoint = modelsEndpoint; self.catalogModels = catalogModels
    }

    // MARK: Request

    /// Builds the request body. `responseIDLookup` maps a call id to the response that produced it (memo).
    public func makeRequestBody(messages: [ChatMessage], tools: [ToolSpec], options: GenerationOptions,
                                responseIDLookup: [String: String] = [:]) throws -> JSONValue {
        var body: [String: JSONValue] = ["model": .string(model.model), "stream": true]
        let instructions = Transcript.systemText(messages)
        if !instructions.isEmpty { body["instructions"] = .string(instructions) }

        let conversation = messages.filter { $0.role != .system }
        let calls = Transcript.callIndex(messages)
        var startIndex = 0
        if let anchor = conversation.lastIndex(where: { $0.role == .assistant }),
           let responseID = Self.responseID(of: conversation[anchor], lookup: responseIDLookup) {
            body["previous_response_id"] = .string(responseID)
            startIndex = anchor + 1
        }
        let earlierImages = conversation[..<startIndex].flatMap { m in m.images + m.toolResults.flatMap(\.images) }
        body["input"] = .array(try encodeItems(Array(conversation[startIndex...]), calls: calls,
                                               fallbackImage: earlierImages.last))

        var toolEntries: [JSONValue] = []
        for spec in tools {
            if spec.native == .openAIComputer, capabilities.nativeComputerUse == .openAIComputer {
                toolEntries.append(computerDeclaration(spec))
            } else {
                toolEntries.append([
                    "type": "function",
                    "name": .string(spec.name),
                    "description": .string(spec.description),
                    "parameters": spec.parameters,
                ])
            }
        }
        if !toolEntries.isEmpty { body["tools"] = .array(toolEntries) }
        if let maxTokens = options.maxTokens { body["max_output_tokens"] = .number(Double(maxTokens)) }
        if let temperature = options.temperature { body["temperature"] = .number(temperature) }
        if let effort = options.reasoningEffort {
            body["reasoning"] = ["effort": .string(effort), "summary": "auto"]
        }
        if options.jsonMode { body["text"] = ["format": ["type": "json_object"]] }
        for (key, value) in options.extra { body[key] = value }
        return .object(body)
    }

    func computerDeclaration(_ spec: ToolSpec) -> JSONValue {
        if let declaration = NativeToolNaming.declaration(of: spec) { return declaration }
        let type = quirks.value(Quirk.computerToolType) ?? "computer"
        guard type == "computer_use_preview" else { return ["type": .string(type)] }
        // Legacy preview shape (shut down 2026-07-23 for computer-use-preview; kept for compatible gateways).
        var entry: [String: JSONValue] = ["type": .string(type)]
        entry["display_width"] = .number(Double(NativeToolNaming.int(spec, ["display_width_px", "displayWidth"]) ?? 1440))
        entry["display_height"] = .number(Double(NativeToolNaming.int(spec, ["display_height_px", "displayHeight"]) ?? 900))
        entry["environment"] = spec.metadata["environment"] ?? "linux"
        return .object(entry)
    }

    /// The response id of an assistant turn: from a computer call's `response_id` argument or the memo.
    static func responseID(of message: ChatMessage, lookup: [String: String]) -> String? {
        for call in message.toolCalls {
            if let id = call.arguments["response_id"]?.stringValue, !id.isEmpty { return id }
            if let id = lookup[call.id] { return id }
        }
        return nil
    }

    static func isComputerCall(_ call: ToolCall) -> Bool {
        call.name == NativeToolNaming.computer
            && (call.arguments["actions"]?.arrayValue != nil || call.arguments["action"]?.objectValue != nil)
    }

    func encodeItems(_ messages: [ChatMessage], calls: [String: ToolCall], fallbackImage: ImageData?) throws -> [JSONValue] {
        var items: [JSONValue] = []
        var lastImage = fallbackImage
        for message in messages {
            switch message.role {
            case .system:
                continue
            case .user:
                var content: [JSONValue] = []
                for part in message.parts {
                    switch part {
                    case .text(let t): content.append(["type": "input_text", "text": .string(t)])
                    case .image(let image):
                        content.append(["type": "input_image", "image_url": .string(image.dataURL)])
                        lastImage = image
                    case .toolResult(let r): content.append(["type": "input_text", "text": .string(Transcript.resultText(r))])
                    case .toolUse, .reasoning: break
                    }
                }
                if !content.isEmpty { items.append(["role": "user", "content": .array(content)]) }
            case .assistant:
                let text = message.text
                if !text.isEmpty { items.append(["role": "assistant", "content": .string(text)]) }
                for call in message.toolCalls {
                    if Self.isComputerCall(call) {
                        // UNVERIFIED: a stateless replay without the original item id (`cu_…`); the normal path
                        // continues with previous_response_id instead.
                        var item: [String: JSONValue] = ["type": "computer_call", "status": "completed"]
                        item["call_id"] = .string(call.id)
                        item["actions"] = .array(Self.actions(of: call))
                        item["pending_safety_checks"] = call.arguments["pending_safety_checks"] ?? .array([])
                        items.append(.object(item))
                    } else {
                        items.append([
                            "type": "function_call",
                            "call_id": .string(call.id),
                            "name": .string(call.name),
                            "arguments": .string(OpenAIChatClient.argumentsString(call.arguments)),
                        ])
                    }
                }
            case .tool:
                var followUp: [JSONValue] = []
                for result in message.toolResults {
                    if let call = calls[result.callID], Self.isComputerCall(call) {
                        guard let image = result.images.last ?? lastImage else {
                            throw ZError.invalidArgument("computer_call_output for \(result.callID) needs a screenshot")
                        }
                        lastImage = image
                        let acknowledged: JSONValue = result.isError
                            ? .array([]) : (call.arguments["pending_safety_checks"] ?? .array([]))
                        let screenshot: JSONValue = [
                            "type": "computer_screenshot",
                            "image_url": .string(image.dataURL),
                            "detail": "original",
                        ]
                        var output: [String: JSONValue] = ["type": "computer_call_output"]
                        output["call_id"] = .string(result.callID)
                        output["output"] = screenshot
                        output["acknowledged_safety_checks"] = acknowledged
                        items.append(.object(output))
                        if result.isError || !result.text.isEmpty {
                            followUp.append(["type": "input_text",
                                             "text": .string("computer \(result.callID): \(Transcript.resultText(result))")])
                        }
                    } else {
                        items.append([
                            "type": "function_call_output",
                            "call_id": .string(result.callID),
                            "output": .string(Transcript.resultText(result)),
                        ])
                        for image in result.images {
                            followUp.append(["type": "input_image", "image_url": .string(image.dataURL)])
                            lastImage = image
                        }
                    }
                }
                if !followUp.isEmpty {
                    items.append(["role": "user", "content": .array(followUp)])
                }
            }
        }
        return items
    }

    static func actions(of call: ToolCall) -> [JSONValue] {
        if let list = call.arguments["actions"]?.arrayValue { return list }
        if let single = call.arguments["action"], single.objectValue != nil { return [single] }
        return []
    }

    // MARK: LLMClient

    public func stream(messages: [ChatMessage], tools: [ToolSpec], options: GenerationOptions)
        -> AsyncThrowingStream<StreamEvent, Error> {
        let client = self
        return StreamPump.run { continuation in
            var lookup: [String: String] = [:]
            if let last = messages.last(where: { $0.role == .assistant }) {
                for call in last.toolCalls {
                    if let id = await KeyedMemo.openAIResponseIDs.get(call.id) { lookup[call.id] = id }
                }
            }
            let body = try client.makeRequestBody(messages: messages, tools: tools, options: options,
                                                  responseIDLookup: lookup)
            let request = try client.http.request(url: try client.endpoint.url("responses"), method: "POST",
                                                  headers: client.endpoint.headers(), json: body, stream: true)
            var state = ResponsesStreamState()
            var parser = SSEParser()
            let chunks = try await client.http.stream(request)
            for try await chunk in chunks {
                for event in parser.feed(chunk) where !event.isDone {
                    for out in try state.handle(sse: event) { continuation.yield(out) }
                }
            }
            for event in parser.finish() where !event.isDone {
                for out in try state.handle(sse: event) { continuation.yield(out) }
            }
            let (events, callIDs) = state.finish()
            if let responseID = state.responseID {
                for id in callIDs { await KeyedMemo.openAIResponseIDs.set(responseID, for: id) }
            }
            for out in events { continuation.yield(out) }
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

/// Parses the Responses API event stream (`response.*` events).
struct ResponsesStreamState {
    var responseID: String?
    var assembler = ToolCallAssembler()
    var doneItems: [Int: JSONValue] = [:]
    var finalOutput: [JSONValue]?
    var sawText = false
    var sawReasoning = false
    var refused = false
    var usage: Usage?
    var incompleteReason: String?
    var incomplete = false

    mutating func handle(sse event: SSEEvent) throws -> [StreamEvent] {
        let trimmed = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let json = try? JSONValue.parse(trimmed) else {
            throw ZError.decoding("Unreadable Responses event: \(String(trimmed.prefix(200)))")
        }
        return try handle(json, eventName: event.event)
    }

    mutating func handle(_ json: JSONValue, eventName: String? = nil) throws -> [StreamEvent] {
        let type = json["type"]?.stringValue ?? eventName ?? ""
        let outputIndex = json["output_index"]?.lenientInt
        switch type {
        case "response.created", "response.in_progress":
            if let id = json["response"]?["id"]?.stringValue { responseID = id }
        case "response.output_text.delta":
            if let delta = json["delta"]?.stringValue, !delta.isEmpty {
                sawText = true
                return [.textDelta(delta)]
            }
        case "response.refusal.delta":
            refused = true
            if let delta = json["delta"]?.stringValue, !delta.isEmpty {
                sawText = true
                return [.textDelta(delta)]
            }
        case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
            if let delta = json["delta"]?.stringValue, !delta.isEmpty {
                sawReasoning = true
                return [.reasoningDelta(delta)]
            }
        case "response.output_item.added":
            if let item = json["item"], item["type"]?.stringValue == "function_call" {
                let arguments = item["arguments"]?.stringValue ?? ""
                return assembler.ingest(index: outputIndex, id: item["call_id"]?.stringValue,
                                        name: item["name"]?.stringValue,
                                        argumentsDelta: arguments.isEmpty ? nil : arguments)
            }
        case "response.function_call_arguments.delta":
            if let delta = json["delta"]?.stringValue {
                return assembler.ingest(index: outputIndex, id: nil, name: nil, argumentsDelta: delta)
            }
        case "response.function_call_arguments.done":
            if let arguments = json["arguments"]?.stringValue {
                assembler.setArguments(index: outputIndex, id: nil, arguments: arguments)
            }
        case "response.output_item.done":
            if let item = json["item"] { doneItems[outputIndex ?? doneItems.count] = item }
        case "response.completed", "response.incomplete":
            let response = json["response"] ?? .object([:])
            if responseID == nil { responseID = response["id"]?.stringValue }
            finalOutput = response["output"]?.arrayValue
            readUsage(response["usage"])
            if type == "response.incomplete" || response["status"]?.stringValue == "incomplete" {
                incomplete = true
                incompleteReason = response["incomplete_details"]?["reason"]?.stringValue
            }
        case "response.failed":
            throw ProviderErrorMapper.streamError(["error": json["response"]?["error"] ?? json])
        case "error":
            throw ProviderErrorMapper.streamError(json)
        default:
            break
        }
        return []
    }

    private mutating func readUsage(_ value: JSONValue?) {
        guard let u = value, u.objectValue != nil else { return }
        usage = Usage(inputTokens: u["input_tokens"]?.lenientInt ?? 0,
                      outputTokens: u["output_tokens"]?.lenientInt ?? 0,
                      cachedInputTokens: u["input_tokens_details"]?["cached_tokens"]?.lenientInt ?? 0)
    }

    /// Final events plus the call ids produced in this response (for the response-id memo).
    mutating func finish() -> (events: [StreamEvent], callIDs: [String]) {
        var events: [StreamEvent] = []
        var calls: [ToolCall] = []
        let items: [JSONValue] = doneItems.isEmpty
            ? (finalOutput ?? [])
            : doneItems.keys.sorted().compactMap { doneItems[$0] }
        var functionIDs = Set<String>()
        for item in items {
            switch item["type"]?.stringValue ?? "" {
            case "function_call":
                guard let callID = item["call_id"]?.stringValue, let name = item["name"]?.stringValue else { continue }
                functionIDs.insert(callID)
                calls.append(ToolCall(id: callID, name: name,
                                      arguments: ToolCallAssembler.parseArguments(item["arguments"]?.stringValue ?? "")))
            case "computer_call":
                guard let callID = item["call_id"]?.stringValue ?? item["id"]?.stringValue else { continue }
                var actions = item["actions"]?.arrayValue ?? []
                if actions.isEmpty, let single = item["action"], single.objectValue != nil { actions = [single] }
                var arguments: [String: JSONValue] = [
                    "actions": .array(actions),
                    "pending_safety_checks": item["pending_safety_checks"] ?? .array([]),
                ]
                if let responseID { arguments["response_id"] = .string(responseID) }
                let call = ToolCall(id: callID, name: NativeToolNaming.computer, arguments: .object(arguments))
                events.append(.toolCallStart(id: callID, name: call.name))
                calls.append(call)
            case "message":
                guard !sawText else { continue }
                for content in item["content"]?.arrayValue ?? [] {
                    if let text = content["text"]?.stringValue ?? content["refusal"]?.stringValue, !text.isEmpty {
                        events.append(.textDelta(text))
                    }
                    if content["type"]?.stringValue == "refusal" { refused = true }
                }
            case "reasoning":
                guard !sawReasoning else { continue }
                for summary in item["summary"]?.arrayValue ?? [] {
                    if let text = summary["text"]?.stringValue, !text.isEmpty { events.append(.reasoningDelta(text)) }
                }
            default:
                continue
            }
        }
        // Function calls seen only as deltas (no output_item.done / completed output).
        for call in assembler.finish() where !functionIDs.contains(call.id) {
            calls.append(call)
        }
        events += calls.map { StreamEvent.toolCall($0) }
        if let usage { events.append(.usage(usage)) }
        let reason: FinishReason
        if incomplete {
            switch incompleteReason {
            case "max_output_tokens"?: reason = .length
            case "content_filter"?: reason = .contentFilter
            default: reason = .other
            }
        } else if !calls.isEmpty {
            reason = .toolCalls
        } else {
            reason = refused ? .contentFilter : .stop
        }
        events.append(.finished(reason))
        return (events, calls.map(\.id))
    }
}
