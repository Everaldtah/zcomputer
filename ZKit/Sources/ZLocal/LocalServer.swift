import Foundation
import ZCore

/// Which local inference server answered. Raw values match the provider ids in `providers.json`.
public enum LocalServerKind: String, Codable, Sendable, CaseIterable, Hashable {
    case ollama
    case lmStudio = "lmstudio"
    case llamaCpp = "llamacpp"
    case jan
    case vllm
    case koboldCpp = "koboldcpp"
    /// Something that speaks the OpenAI `/v1/models` shape but could not be identified further.
    case openAICompatible = "openai-compatible"

    public var displayName: String {
        switch self {
        case .ollama: return "Ollama"
        case .lmStudio: return "LM Studio"
        case .llamaCpp: return "llama.cpp server"
        case .jan: return "Jan"
        case .vllm: return "vLLM"
        case .koboldCpp: return "KoboldCpp"
        case .openAICompatible: return "OpenAI-compatible server"
        }
    }

    /// The catalogue provider this server maps to (`ollama`, `lmstudio`, ...).
    public var providerID: ProviderID { ProviderID(rawValue) }

    /// Ports the server listens on by default, most current first.
    public var defaultPorts: [Int] {
        switch self {
        case .ollama: return [11434]
        case .lmStudio: return [1234]
        case .llamaCpp: return [9931, 8080]   // 9931 since 2026-10-09; older builds and Docker images use 8080
        case .jan: return [1337]
        case .vllm: return [8000]
        case .koboldCpp: return [5001]
        case .openAICompatible: return []
        }
    }

    /// The wire format ZProviders should use to talk to it.
    public var apiStyle: LocalAPIStyle { self == .ollama ? .ollama : .openai }
}

/// Wire format of a discovered server.
public enum LocalAPIStyle: String, Codable, Sendable, Hashable {
    /// OpenAI Chat Completions under `baseURL` (which already ends in `/v1`).
    case openai
    /// Ollama native `/api/chat` under `baseURL` (no `/v1`).
    case ollama
}

/// A host:port to probe. Default endpoints are loopback only; user-entered endpoints may point at the LAN.
public struct LocalEndpoint: Sendable, Hashable, Codable {
    public var scheme: String
    public var host: String
    public var port: Int
    /// What we expect to find there; the response shape still decides the final kind.
    public var kindHint: LocalServerKind?
    /// Optional bearer token (LM Studio "Require Authentication", llama-server `--api-key`, Jan, vLLM).
    /// Never encoded, so persisting endpoints does not write secrets to settings; keep it in the KeyStore.
    public var apiKey: String? = nil

    public init(scheme: String = "http", host: String = "127.0.0.1", port: Int, kindHint: LocalServerKind? = nil, apiKey: String? = nil) {
        self.scheme = scheme.lowercased(); self.host = host; self.port = port; self.kindHint = kindHint; self.apiKey = apiKey
    }

    /// Parses `"host:port"`, `"http://host:port"`, `"https://host:port/v1"` or a bare `"host"` (port from `defaultPort`).
    public init?(string: String, kindHint: LocalServerKind? = nil, defaultPort: Int? = nil, apiKey: String? = nil) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard let comps = URLComponents(string: withScheme), let host = comps.host, !host.isEmpty else { return nil }
        let scheme = (comps.scheme ?? "http").lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        guard let port = comps.port ?? defaultPort ?? kindHint?.defaultPorts.first ?? (scheme == "https" ? 443 : nil) else { return nil }
        guard (1...65535).contains(port) else { return nil }
        self.init(scheme: scheme, host: host, port: port, kindHint: kindHint, apiKey: apiKey)
    }

    enum CodingKeys: String, CodingKey { case scheme, host, port, kindHint }

    /// `localhost` and `127.0.0.1` are the same server.
    var normalizedKey: String {
        let h = host.lowercased()
        let canonical = (h == "localhost" || h == "::1" || h == "[::1]") ? "127.0.0.1" : h
        return "\(canonical):\(port)"
    }

    /// `scheme://host:port` (IPv6 hosts bracketed).
    public var origin: URL? {
        let h = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return URL(string: "\(scheme)://\(h):\(port)")
    }

    func url(_ path: String) -> URL? {
        guard let origin else { return nil }
        return URL(string: origin.absoluteString + path)
    }

    var authHeaders: [String: String] {
        guard let apiKey, !apiKey.isEmpty else { return [:] }
        return ["Authorization": "Bearer \(apiKey)"]
    }
}

/// A local inference server found by `LocalServerDiscovery`.
public struct LocalServer: Sendable, Hashable, Codable, Identifiable {
    /// Stable id: `"<kind>@<host>:<port>"`, e.g. `"ollama@127.0.0.1:11434"`.
    public var id: String
    public var name: String
    public var kind: LocalServerKind
    /// Base URL for the client: Ollama native root (`http://127.0.0.1:11434`) or OpenAI root ending in `/v1`.
    public var baseURL: URL
    public var apiStyle: LocalAPIStyle
    public var models: [ModelInfo]
    /// False only for a user endpoint passed to `probe(_:)` that did not answer.
    public var reachable: Bool
    /// Round trip of the identifying request, in milliseconds (0 when unreachable).
    public var latencyMs: Int
    /// The server answered 401/403: it exists, but needs a token before it will list models.
    public var requiresAuth: Bool
    /// llama-server is up but still loading its model (503 "Loading model").
    public var loading: Bool
    /// Server version when it reports one (Ollama `/api/version`, llama.cpp `build_info`).
    public var version: String?
    public var endpoint: LocalEndpoint

    public init(id: String, name: String, kind: LocalServerKind, baseURL: URL, apiStyle: LocalAPIStyle, models: [ModelInfo],
                reachable: Bool, latencyMs: Int, requiresAuth: Bool = false, loading: Bool = false, version: String? = nil,
                endpoint: LocalEndpoint) {
        self.id = id; self.name = name; self.kind = kind; self.baseURL = baseURL; self.apiStyle = apiStyle
        self.models = models; self.reachable = reachable; self.latencyMs = latencyMs; self.requiresAuth = requiresAuth
        self.loading = loading; self.version = version; self.endpoint = endpoint
    }

    /// The catalogue provider id (`ollama`, `lmstudio`, `llamacpp`, ...).
    public var providerID: ProviderID { kind.providerID }

    /// OpenAI-compatible root for every kind (Ollama also serves `/v1`).
    public var openAIBaseURL: URL {
        apiStyle == .ollama ? baseURL.appendingPathComponent("v1") : baseURL
    }

    /// Model refs for the agent picker.
    public var modelRefs: [ModelRef] { models.map { ModelRef(provider: providerID, model: $0.id) } }
}
