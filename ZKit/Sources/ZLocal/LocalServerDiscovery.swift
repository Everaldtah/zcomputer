import Foundation
import ZCore

/// Finds local inference servers (Ollama, LM Studio, llama.cpp, Jan, vLLM, KoboldCpp, user endpoints) and lists
/// their models. Servers are identified by **response shape**, never by port alone, because 8000/8080 are common
/// dev ports. Probes run concurrently; each request has its own timeout.
public actor LocalServerDiscovery {

    /// Loopback endpoints probed on every scan, in result order.
    public static let defaultEndpoints: [LocalEndpoint] = [
        LocalEndpoint(port: 11434, kindHint: .ollama),
        LocalEndpoint(port: 1234, kindHint: .lmStudio),
        LocalEndpoint(port: 9931, kindHint: .llamaCpp),
        LocalEndpoint(port: 8080, kindHint: .llamaCpp),
        LocalEndpoint(port: 1337, kindHint: .jan),
        LocalEndpoint(port: 8000, kindHint: .vllm),
        LocalEndpoint(port: 5001, kindHint: .koboldCpp),
    ]

    /// Default per-request timeout (seconds): loopback answers in a few ms or refuses at once.
    public static let defaultTimeout: TimeInterval = 0.4

    private let transport: any LocalTransport
    private let includeDefaults: Bool
    public private(set) var customEndpoints: [LocalEndpoint]
    /// Result of the most recent `scan`.
    public private(set) var lastScan: [LocalServer] = []

    public init(transport: any LocalTransport = URLSessionLocalTransport(), customEndpoints: [LocalEndpoint] = [],
                includeDefaults: Bool = true) {
        self.transport = transport
        self.customEndpoints = customEndpoints
        self.includeDefaults = includeDefaults
    }

    /// Replaces the user-entered endpoints (Settings ▸ Local models).
    public func setCustomEndpoints(_ endpoints: [LocalEndpoint]) { customEndpoints = endpoints }

    /// The endpoints a scan will probe: defaults then custom ones, de-duplicated by host:port (a custom entry for a
    /// default port replaces it, keeping the default's kind hint when the custom one has none).
    public var endpoints: [LocalEndpoint] {
        var ordered: [LocalEndpoint] = []
        var index: [String: Int] = [:]
        for ep in (includeDefaults ? Self.defaultEndpoints : []) + customEndpoints {
            if let i = index[ep.normalizedKey] {
                var merged = ep
                if merged.kindHint == nil { merged.kindHint = ordered[i].kindHint }
                ordered[i] = merged
            } else {
                index[ep.normalizedKey] = ordered.count
                ordered.append(ep)
            }
        }
        return ordered
    }

    /// Probes every endpoint concurrently and returns the servers that answered, in endpoint order.
    /// Unreachable endpoints and endpoints that answer with an unrecognised shape are left out.
    public func scan(timeout: TimeInterval = LocalServerDiscovery.defaultTimeout) async -> [LocalServer] {
        let targets = endpoints
        let prober = LocalServerProber(transport: transport, timeout: timeout)
        let found = await withTaskGroup(of: (Int, LocalServer?).self) { group in
            for (i, ep) in targets.enumerated() {
                group.addTask {
                    let server = await prober.identify(ep)
                    return (i, server)
                }
            }
            var results: [(Int, LocalServer)] = []
            for await (i, server) in group {
                if let server { results.append((i, server)) }
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
        lastScan = found
        return found
    }

    /// Probes one endpoint (Settings ▸ "Test connection"). Always returns a value; `reachable` is false when nothing
    /// recognisable answered.
    public func probe(_ endpoint: LocalEndpoint, timeout: TimeInterval = LocalServerDiscovery.defaultTimeout) async -> LocalServer {
        let prober = LocalServerProber(transport: transport, timeout: timeout)
        if let server = await prober.identify(endpoint) { return server }
        let kind = endpoint.kindHint ?? .openAICompatible
        let base = LocalServerProber.baseURL(for: kind, endpoint: endpoint)
        return LocalServer(id: LocalServerProber.serverID(kind: kind, endpoint: endpoint),
                           name: LocalServerProber.serverName(kind: kind, endpoint: endpoint),
                           kind: kind, baseURL: base, apiStyle: kind.apiStyle, models: [], reachable: false,
                           latencyMs: 0, endpoint: endpoint)
    }
}

// MARK: - Probing

/// Stateless probe logic; Sendable so every endpoint can be probed from its own child task.
struct LocalServerProber: Sendable {
    let transport: any LocalTransport
    let timeout: TimeInterval

    /// Maximum number of Ollama models whose `/api/show` capabilities are fetched (the rest use name heuristics).
    static let maxOllamaShowRequests = 64

    enum Detector: Sendable { case ollama, lmStudio, llamaCpp, openAI }

    /// Outcome of one detector on one endpoint.
    enum Outcome: Sendable {
        case found(LocalServer)
        /// The endpoint answered HTTP but not in this detector's shape; try the next detector.
        case notThisKind
        /// No HTTP answer at all (refused / timed out); stop probing this endpoint.
        case unreachable
    }

    static func detectors(for hint: LocalServerKind?) -> [Detector] {
        switch hint {
        case .ollama: return [.ollama, .openAI]
        case .lmStudio: return [.lmStudio, .openAI]
        case .llamaCpp: return [.llamaCpp, .openAI]
        case .jan, .vllm, .koboldCpp, .openAICompatible: return [.openAI]
        // Unknown user endpoint: llama.cpp before Ollama, because llama-server also answers `/api/tags`.
        case nil: return [.llamaCpp, .ollama, .lmStudio, .openAI]
        }
    }

    func identify(_ endpoint: LocalEndpoint) async -> LocalServer? {
        for detector in Self.detectors(for: endpoint.kindHint) {
            let outcome: Outcome
            switch detector {
            case .ollama: outcome = await detectOllama(endpoint)
            case .lmStudio: outcome = await detectLMStudio(endpoint)
            case .llamaCpp: outcome = await detectLlamaCpp(endpoint)
            case .openAI: outcome = await detectOpenAI(endpoint)
            }
            switch outcome {
            case .found(let server): return server
            case .unreachable: return nil
            case .notThisKind: continue
            }
        }
        return nil
    }

    // MARK: HTTP helpers

    /// A timed GET. `nil` response means no HTTP answer (transport error / timeout).
    struct Timed: Sendable { let response: LocalHTTPResponse; let ms: Int }

    func get(_ endpoint: LocalEndpoint, _ path: String) async -> Timed? {
        guard let url = endpoint.url(path) else { return nil }
        let req = LocalHTTPRequest(method: "GET", url: url, headers: endpoint.authHeaders, timeout: timeout)
        return await send(req)
    }

    func postJSON(_ endpoint: LocalEndpoint, _ path: String, _ body: JSONValue) async -> Timed? {
        guard let url = endpoint.url(path), let data = try? body.jsonData() else { return nil }
        var headers = endpoint.authHeaders
        headers["Content-Type"] = "application/json"
        return await send(LocalHTTPRequest(method: "POST", url: url, headers: headers, body: data, timeout: timeout))
    }

    private func send(_ req: LocalHTTPRequest) async -> Timed? {
        let transport = self.transport
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let response = try await withLocalTimeout(timeout) { try await transport.send(req) }
            return Timed(response: response, ms: Self.milliseconds(clock.now - start))
        } catch {
            return nil
        }
    }

    static func milliseconds(_ d: Duration) -> Int {
        let c = d.components
        return max(0, Int(c.seconds) * 1000 + Int(c.attoseconds / 1_000_000_000_000_000))
    }

    static func json(_ r: LocalHTTPResponse) -> JSONValue? { try? JSONValue.parse(r.data) }

    // MARK: Identity

    static func serverID(kind: LocalServerKind, endpoint: LocalEndpoint) -> String {
        "\(kind.rawValue)@\(endpoint.host):\(endpoint.port)"
    }

    static func serverName(kind: LocalServerKind, endpoint: LocalEndpoint) -> String {
        let isLoopback = endpoint.normalizedKey.hasPrefix("127.0.0.1:")
        if isLoopback {
            if kind.defaultPorts.first == endpoint.port { return kind.displayName }
            return "\(kind.displayName) (port \(endpoint.port))"
        }
        return "\(kind.displayName) @ \(endpoint.host):\(endpoint.port)"
    }

    static func baseURL(for kind: LocalServerKind, endpoint: LocalEndpoint) -> URL {
        let fallback = URL(fileURLWithPath: "/")
        guard let origin = endpoint.origin else { return fallback }
        return kind.apiStyle == .ollama ? origin : origin.appendingPathComponent("v1")
    }

    func makeServer(_ kind: LocalServerKind, _ endpoint: LocalEndpoint, models: [ModelInfo], latencyMs: Int,
                    requiresAuth: Bool = false, loading: Bool = false, version: String? = nil) -> LocalServer {
        LocalServer(id: Self.serverID(kind: kind, endpoint: endpoint), name: Self.serverName(kind: kind, endpoint: endpoint),
                    kind: kind, baseURL: Self.baseURL(for: kind, endpoint: endpoint), apiStyle: kind.apiStyle,
                    models: models, reachable: true, latencyMs: latencyMs, requiresAuth: requiresAuth, loading: loading,
                    version: version, endpoint: endpoint)
    }

    // MARK: Ollama

    func detectOllama(_ ep: LocalEndpoint) async -> Outcome {
        guard let tags = await get(ep, "/api/tags") else { return .unreachable }
        if tags.response.status == 401 || tags.response.status == 403, ep.kindHint == .ollama {
            return .found(makeServer(.ollama, ep, models: [], latencyMs: tags.ms, requiresAuth: true))
        }
        // Ollama answers `{"models": [...]}` only; llama-server's Ollama-compat alias also carries `data`/`object`.
        guard tags.response.isSuccess, let body = Self.json(tags.response), body["data"] == nil, body["object"] == nil,
              let list = body["models"]?.arrayValue,
              list.allSatisfy({ $0["name"]?.stringValue != nil || $0["model"]?.stringValue != nil })
        else { return .notThisKind }

        let names: [String] = list.compactMap { $0["name"]?.stringValue ?? $0["model"]?.stringValue }
        async let versionAnswer = get(ep, "/api/version")
        let shows = await ollamaShow(ep, names: Array(names.prefix(Self.maxOllamaShowRequests)))
        let versionTimed = await versionAnswer
        let version = versionTimed.flatMap { Self.json($0.response)?["version"]?.stringValue }

        let models = list.compactMap { entry -> ModelInfo? in
            guard let name = entry["name"]?.stringValue ?? entry["model"]?.stringValue else { return nil }
            return Self.ollamaModel(entry, name: name, show: shows[name])
        }
        return .found(makeServer(.ollama, ep, models: models, latencyMs: tags.ms, version: version))
    }

    /// `POST /api/show` per model, concurrently; failures are simply absent from the result.
    func ollamaShow(_ ep: LocalEndpoint, names: [String]) async -> [String: JSONValue] {
        await withTaskGroup(of: (String, JSONValue?).self) { group in
            for name in names {
                group.addTask {
                    guard let r = await postJSON(ep, "/api/show", ["model": .string(name)]), r.response.isSuccess else {
                        return (name, nil)
                    }
                    return (name, Self.json(r.response))
                }
            }
            var out: [String: JSONValue] = [:]
            for await (name, value) in group { if let value { out[name] = value } }
            return out
        }
    }

    static func ollamaModel(_ entry: JSONValue, name: String, show: JSONValue?) -> ModelInfo {
        let details = entry["details"]
        let families = (details?["families"]?.arrayValue ?? []).compactMap(\.stringValue).map { $0.lowercased() }
        var vision = LocalModelHeuristics.likelyVision(name) || families.contains("clip") || families.contains("mllama")
        var tools = LocalModelHeuristics.likelyTools(name)
        var context: Int?
        if let show {
            if let caps = show["capabilities"]?.arrayValue?.compactMap(\.stringValue) {
                vision = caps.contains("vision")
                tools = caps.contains("tools")
            }
            if let info = show["model_info"]?.objectValue {
                context = info.first(where: { $0.key.hasSuffix(".context_length") })?.value.intValue
            }
        }
        var noteParts: [String] = []
        if let p = details?["parameter_size"]?.stringValue, !p.isEmpty { noteParts.append(p) }
        if let q = details?["quantization_level"]?.stringValue, !q.isEmpty { noteParts.append(q) }
        if let size = entry["size"]?.doubleValue, size > 0 { noteParts.append(formatBytes(size)) }
        if LocalModelHeuristics.isEmbeddingModel(name) { noteParts.append("embedding") }
        return ModelInfo(id: name, displayName: name,
                         capabilities: ModelCapabilities(vision: vision, tools: tools, streaming: true, contextWindow: context),
                         free: true, notes: noteParts.isEmpty ? nil : noteParts.joined(separator: " · "))
    }

    // MARK: LM Studio

    func detectLMStudio(_ ep: LocalEndpoint) async -> Outcome {
        guard let v1 = await get(ep, "/api/v1/models") else { return .unreachable }
        if v1.response.status == 401 || v1.response.status == 403 {
            // Only LM Studio's own port/hint counts a bare 401 as LM Studio.
            guard ep.kindHint == .lmStudio else { return .notThisKind }
            return .found(makeServer(.lmStudio, ep, models: [], latencyMs: v1.ms, requiresAuth: true))
        }
        if v1.response.isSuccess, let body = Self.json(v1.response), let list = body["models"]?.arrayValue,
           body["data"] == nil, list.allSatisfy({ $0["key"]?.stringValue != nil }) {
            let models = list.compactMap(Self.lmStudioV1Model)
            return .found(makeServer(.lmStudio, ep, models: models, latencyMs: v1.ms))
        }
        // Legacy (< 0.4) REST: `{"data": [{"id", "type": "llm" | "vlm" | "embeddings", ...}]}`.
        if let v0 = await get(ep, "/api/v0/models"), v0.response.isSuccess, let body = Self.json(v0.response),
           let list = body["data"]?.arrayValue, list.allSatisfy({ $0["id"]?.stringValue != nil && $0["type"] != nil }) {
            let models = list.compactMap(Self.lmStudioV0Model)
            return .found(makeServer(.lmStudio, ep, models: models, latencyMs: v0.ms))
        }
        return .notThisKind
    }

    static func lmStudioV1Model(_ entry: JSONValue) -> ModelInfo? {
        guard let key = entry["key"]?.stringValue else { return nil }
        let type = entry["type"]?.stringValue?.lowercased() ?? "llm"
        guard type == "llm" || type == "vlm" else { return nil }   // skip "embedding"
        let caps = entry["capabilities"]
        let vision = caps?["vision"]?.boolValue ?? (type == "vlm" || LocalModelHeuristics.likelyVision(key))
        let tools = caps?["trained_for_tool_use"]?.boolValue ?? LocalModelHeuristics.likelyTools(key)
        var notes: [String] = []
        if let q = entry["quantization"]?["name"]?.stringValue { notes.append(q) }
        if let f = entry["format"]?.stringValue { notes.append(f) }
        if let size = entry["size_bytes"]?.doubleValue, size > 0 { notes.append(formatBytes(size)) }
        if let loaded = entry["loaded_instances"]?.arrayValue, !loaded.isEmpty { notes.append("loaded") }
        return ModelInfo(id: key, displayName: entry["display_name"]?.stringValue ?? key,
                         capabilities: ModelCapabilities(vision: vision, tools: tools, streaming: true,
                                                         contextWindow: entry["max_context_length"]?.intValue),
                         free: true, notes: notes.isEmpty ? nil : notes.joined(separator: " · "))
    }

    static func lmStudioV0Model(_ entry: JSONValue) -> ModelInfo? {
        guard let id = entry["id"]?.stringValue else { return nil }
        let type = entry["type"]?.stringValue?.lowercased() ?? "llm"
        guard type == "llm" || type == "vlm" else { return nil }
        let toolCap = entry["capabilities"]?.arrayValue?.compactMap(\.stringValue).contains("tool_use")
        var notes: [String] = []
        if let q = entry["quantization"]?.stringValue { notes.append(q) }
        if let state = entry["state"]?.stringValue { notes.append(state) }
        return ModelInfo(id: id, displayName: id,
                         capabilities: ModelCapabilities(vision: type == "vlm" || LocalModelHeuristics.likelyVision(id),
                                                         tools: toolCap ?? LocalModelHeuristics.likelyTools(id),
                                                         streaming: true,
                                                         contextWindow: entry["max_context_length"]?.intValue),
                         free: true, notes: notes.isEmpty ? nil : notes.joined(separator: " · "))
    }

    // MARK: llama.cpp

    func detectLlamaCpp(_ ep: LocalEndpoint) async -> Outcome {
        guard let health = await get(ep, "/health") else { return .unreachable }
        let body = Self.json(health.response)
        if health.response.status == 503,
           let message = body?["error"]?["message"]?.stringValue, message.lowercased().contains("loading") {
            return .found(makeServer(.llamaCpp, ep, models: [], latencyMs: health.ms, loading: true))
        }
        guard health.response.isSuccess, body?["status"]?.stringValue?.lowercased() == "ok" else { return .notThisKind }

        // `/health` = ok is common in other apps too, so require a llama-shaped model list or `/props`.
        async let propsAnswer = get(ep, "/props")
        var models: [ModelInfo] = []
        var shaped = false
        if let list = await get(ep, "/v1/models"), list.response.isSuccess, let json = Self.json(list.response),
           let data = json["data"]?.arrayValue {
            let kind = Self.classify(json)
            // Another server that happens to answer /health (vLLM, KoboldCpp): let the OpenAI detector name it.
            if let kind, kind != .llamaCpp { return .notThisKind }
            models = data.compactMap { Self.openAIModel($0) }
            shaped = kind == .llamaCpp || !data.isEmpty
        }
        if models.isEmpty, let router = await get(ep, "/models"), router.response.isSuccess,
           let data = Self.json(router.response)?["data"]?.arrayValue {
            models = data.compactMap { Self.openAIModel($0) }
            shaped = shaped || !data.isEmpty
        }
        let propsTimed = await propsAnswer
        let props = propsTimed.flatMap { $0.response.isSuccess ? Self.json($0.response) : nil }
        let propsShaped = props.map { $0["default_generation_settings"] != nil || $0["model_path"] != nil || $0["build_info"] != nil } ?? false
        guard shaped || propsShaped else { return .notThisKind }
        if let props { models = Self.applyLlamaProps(props, to: models) }
        return .found(makeServer(.llamaCpp, ep, models: models, latencyMs: health.ms,
                                 version: props?["build_info"]?.stringValue))
    }

    /// `/props`: nicer name (alias or file name), runtime context (`n_ctx`), `modalities.vision`.
    static func applyLlamaProps(_ props: JSONValue, to models: [ModelInfo]) -> [ModelInfo] {
        let ctx = props["default_generation_settings"]?["n_ctx"]?.intValue
            ?? props["default_generation_settings"]?["params"]?["n_ctx"]?.intValue
        let vision = props["modalities"]?["vision"]?.boolValue
        let alias = props["model_alias"]?.stringValue
        let fileName = props["model_path"]?.stringValue.map(displayName(fromPath:))
        var out = models
        if out.isEmpty, let id = alias ?? props["model_path"]?.stringValue {
            out = [openAIModel(["id": .string(id)]) ?? ModelInfo(id: id)]
        }
        // A single-model server: props describe that model.
        if out.count == 1 {
            if let name = alias ?? fileName { out[0].displayName = name }
            if let ctx, ctx > 0 { out[0].capabilities.contextWindow = ctx }
            if let vision { out[0].capabilities.vision = vision }
        }
        return out
    }

    static func displayName(fromPath path: String) -> String {
        let last = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
        return last.lowercased().hasSuffix(".gguf") ? String(last.dropLast(5)) : last
    }

    // MARK: OpenAI-compatible (`/v1/models`)

    func detectOpenAI(_ ep: LocalEndpoint) async -> Outcome {
        guard let answer = await get(ep, "/v1/models") else { return .unreachable }
        if answer.response.status == 401 || answer.response.status == 403 {
            guard let hint = ep.kindHint else { return .notThisKind }
            return .found(makeServer(hint, ep, models: [], latencyMs: answer.ms, requiresAuth: true))
        }
        guard answer.response.isSuccess, let json = Self.json(answer.response), let data = json["data"]?.arrayValue,
              data.allSatisfy({ $0["id"]?.stringValue != nil })
        else { return .notThisKind }
        let kind = Self.classify(json) ?? ep.kindHint ?? .openAICompatible
        var models = data.compactMap { Self.openAIModel($0) }
        var version: String?
        if kind == .llamaCpp, let props = await get(ep, "/props"), props.response.isSuccess, let p = Self.json(props.response) {
            models = Self.applyLlamaProps(p, to: models)
            version = p["build_info"]?.stringValue
        }
        return .found(makeServer(kind, ep, models: models, latencyMs: answer.ms, version: version))
    }

    /// Identifies the server behind an OpenAI-shaped model list, or nil when the shape is generic.
    static func classify(_ list: JSONValue) -> LocalServerKind? {
        let data = list["data"]?.arrayValue ?? []
        let owners = Set(data.compactMap { $0["owned_by"]?.stringValue?.lowercased() })
        if owners.contains("llamacpp") || data.contains(where: { $0["meta"] != nil || $0["architecture"]?["input_modalities"] != nil }) {
            return .llamaCpp
        }
        if owners.contains("vllm") || data.contains(where: { $0["max_model_len"] != nil }) { return .vllm }
        if owners.contains("koboldcpp") { return .koboldCpp }
        if owners.contains("jan") { return .jan }
        return nil
    }

    /// Maps one `/v1/models` entry (OpenAI, llama.cpp, vLLM, KoboldCpp, Jan shapes).
    static func openAIModel(_ entry: JSONValue) -> ModelInfo? {
        guard let id = entry["id"]?.stringValue else { return nil }
        let modalities = entry["architecture"]?["input_modalities"]?.arrayValue?.compactMap { $0.stringValue?.lowercased() }
        let vision = modalities.map { $0.contains("image") } ?? LocalModelHeuristics.likelyVision(id)
        let context = entry["meta"]?["n_ctx_train"]?.intValue ?? entry["max_model_len"]?.intValue
            ?? entry["context_length"]?.intValue
        var notes: [String] = []
        if let size = entry["meta"]?["size"]?.doubleValue, size > 0 { notes.append(formatBytes(size)) }
        if let state = entry["status"]?["value"]?.stringValue { notes.append(state) }
        if LocalModelHeuristics.isEmbeddingModel(id) { notes.append("embedding") }
        let name = id.contains("/") && id.lowercased().hasSuffix(".gguf") ? displayName(fromPath: id) : id
        return ModelInfo(id: id, displayName: name,
                         capabilities: ModelCapabilities(vision: vision, tools: LocalModelHeuristics.likelyTools(id),
                                                         streaming: true, contextWindow: context),
                         free: true, notes: notes.isEmpty ? nil : notes.joined(separator: " · "))
    }

    // MARK: Formatting

    static func formatBytes(_ bytes: Double) -> String {
        let gb = bytes / 1_000_000_000
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", bytes / 1_000_000)
    }
}
