import Foundation
import ZCore

/// How a provider is paid for (`kind` in providers.json).
public enum ProviderKind: String, Codable, Sendable, Hashable, CaseIterable {
    case free, freemium, paid, local

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ProviderKind(rawValue: raw.lowercased()) ?? .paid
    }
}

/// Which wire protocol a provider speaks (`apiStyle` in providers.json).
public enum APIStyle: String, Codable, Sendable, Hashable, CaseIterable {
    case openai, anthropic, gemini, ollama, custom

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = APIStyle(rawValue: raw.lowercased()) ?? .custom
    }
}

/// How the API key is sent (`authHeader` in providers.json): `bearer`, a header name such as `x-api-key` /
/// `x-goog-api-key`, `query:<param>`, or `none`.
public enum AuthStyle: Hashable, Sendable, Codable, CustomStringConvertible {
    case bearer
    case header(String)
    case query(String)
    /// No key is sent (`"none"` in the JSON; named `noAuth` to avoid confusion with `Optional.none`).
    case noAuth

    public init(rawValue: String) {
        let raw = rawValue.trimmingCharacters(in: .whitespaces)
        switch raw.lowercased() {
        case "bearer", "authorization": self = .bearer
        case "none", "": self = .noAuth
        default:
            if raw.lowercased().hasPrefix("query:") {
                let name = String(raw.dropFirst("query:".count))
                self = .query(name.isEmpty ? "key" : name)
            } else {
                self = .header(raw)
            }
        }
    }

    public var rawValue: String {
        switch self {
        case .bearer: return "bearer"
        case .header(let name): return name
        case .query(let name): return "query:\(name)"
        case .noAuth: return "none"
        }
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// The `freeTier` object of a provider.
public struct FreeTier: Codable, Sendable, Hashable {
    public var available: Bool
    public var limits: String?
    public var notes: String?

    public init(available: Bool, limits: String? = nil, notes: String? = nil) {
        self.available = available; self.limits = limits; self.notes = notes
    }

    private enum CodingKeys: String, CodingKey { case available, limits, notes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = (try? c.decodeIfPresent(Bool.self, forKey: .available)) ?? false
        limits = try? c.decodeIfPresent(String.self, forKey: .limits)
        notes = try? c.decodeIfPresent(String.self, forKey: .notes)
    }
}

/// One model entry of a provider in providers.json.
public struct ModelDescriptor: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var vision: Bool
    public var tools: Bool
    public var free: Bool
    public var contextTokens: Int?
    public var nativeComputerUse: NativeToolKind?
    public var recommended: Bool

    public init(id: String, name: String? = nil, vision: Bool = false, tools: Bool = false, free: Bool = false,
                contextTokens: Int? = nil, nativeComputerUse: NativeToolKind? = nil, recommended: Bool = false) {
        self.id = id; self.name = name ?? id; self.vision = vision; self.tools = tools; self.free = free
        self.contextTokens = contextTokens; self.nativeComputerUse = nativeComputerUse; self.recommended = recommended
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, vision, tools, free, contextTokens, nativeComputerUse, recommended
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        let decodedName = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil
        name = decodedName ?? id
        vision = (try? c.decodeIfPresent(Bool.self, forKey: .vision)) ?? false
        tools = (try? c.decodeIfPresent(Bool.self, forKey: .tools)) ?? false
        free = (try? c.decodeIfPresent(Bool.self, forKey: .free)) ?? false
        contextTokens = (try? c.decodeIfPresent(Int.self, forKey: .contextTokens)) ?? nil
        let native = (try? c.decodeIfPresent(String.self, forKey: .nativeComputerUse)) ?? nil
        nativeComputerUse = native.flatMap { NativeToolKind(rawValue: $0) }
        recommended = (try? c.decodeIfPresent(Bool.self, forKey: .recommended)) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(vision, forKey: .vision)
        try c.encode(tools, forKey: .tools)
        try c.encode(free, forKey: .free)
        try c.encode(contextTokens, forKey: .contextTokens)
        try c.encode(nativeComputerUse?.rawValue, forKey: .nativeComputerUse)
        try c.encode(recommended, forKey: .recommended)
    }
}

/// Codable mirror of one entry of `Resources/providers.json`. Decoding is lenient: unknown keys are ignored and
/// every field but `id` has a default.
public struct ProviderDescriptor: Codable, Sendable, Hashable, Identifiable {
    public var id: ProviderID
    public var name: String
    public var kind: ProviderKind
    public var apiStyle: APIStyle
    /// Base URL template; may contain `{placeholders}` (`{account_id}`, `{region}`, `{resource}`) that are filled from
    /// the KeyStore base-URL override (see `ProviderClientFactory.resolveBaseURL`). Empty for the custom template.
    public var baseURL: String
    public var authHeader: AuthStyle
    public var keyURL: String?
    public var docsURL: String?
    /// Path appended to the base URL to list models (`/models`, `/api/tags`), nil when the provider has none.
    public var modelsEndpoint: String?
    public var freeTier: FreeTier?
    public var models: [ModelDescriptor]
    public var quirks: [String]
    /// Empty for local / template providers.
    public var defaultModel: String

    public init(id: ProviderID, name: String, kind: ProviderKind, apiStyle: APIStyle, baseURL: String,
                authHeader: AuthStyle, keyURL: String? = nil, docsURL: String? = nil, modelsEndpoint: String? = "/models",
                freeTier: FreeTier? = nil, models: [ModelDescriptor] = [], quirks: [String] = [], defaultModel: String = "") {
        self.id = id; self.name = name; self.kind = kind; self.apiStyle = apiStyle; self.baseURL = baseURL
        self.authHeader = authHeader; self.keyURL = keyURL; self.docsURL = docsURL; self.modelsEndpoint = modelsEndpoint
        self.freeTier = freeTier; self.models = models; self.quirks = quirks; self.defaultModel = defaultModel
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, apiStyle, baseURL, authHeader, keyURL, docsURL, modelsEndpoint, freeTier, models, quirks,
             defaultModel
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = try c.decode(String.self, forKey: .id)
        id = ProviderID(rawID)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? rawID
        kind = (try? c.decodeIfPresent(ProviderKind.self, forKey: .kind)) ?? .paid
        apiStyle = (try? c.decodeIfPresent(APIStyle.self, forKey: .apiStyle)) ?? .openai
        baseURL = (try? c.decodeIfPresent(String.self, forKey: .baseURL)) ?? ""
        authHeader = (try? c.decodeIfPresent(AuthStyle.self, forKey: .authHeader)) ?? .bearer
        keyURL = (try? c.decodeIfPresent(String.self, forKey: .keyURL)) ?? nil
        docsURL = (try? c.decodeIfPresent(String.self, forKey: .docsURL)) ?? nil
        modelsEndpoint = (try? c.decodeIfPresent(String.self, forKey: .modelsEndpoint)) ?? nil
        freeTier = (try? c.decodeIfPresent(FreeTier.self, forKey: .freeTier)) ?? nil
        models = ((try? c.decodeIfPresent([ModelDescriptor].self, forKey: .models)) ?? nil) ?? []
        quirks = ((try? c.decodeIfPresent([String].self, forKey: .quirks)) ?? nil) ?? []
        defaultModel = ((try? c.decodeIfPresent(String.self, forKey: .defaultModel)) ?? nil) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id.rawValue, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encode(apiStyle, forKey: .apiStyle)
        try c.encode(baseURL, forKey: .baseURL)
        try c.encode(authHeader, forKey: .authHeader)
        try c.encode(keyURL, forKey: .keyURL)
        try c.encode(docsURL, forKey: .docsURL)
        try c.encode(modelsEndpoint, forKey: .modelsEndpoint)
        try c.encode(freeTier, forKey: .freeTier)
        try c.encode(models, forKey: .models)
        try c.encode(quirks, forKey: .quirks)
        try c.encode(defaultModel, forKey: .defaultModel)
    }

    // MARK: Derived

    public var quirkSet: QuirkSet { QuirkSet(quirks) }
    public var isLocal: Bool { kind == .local }
    /// True for providers with a renewing no-cost quota or a meaningful trial (`free` / `freemium`).
    public var offersFreeUse: Bool { kind == .free || kind == .freemium }

    /// Whether a request needs a key from the KeyStore.
    public var requiresAPIKey: Bool {
        if authHeader == .noAuth || kind == .local { return false }
        let q = quirkSet
        return !(q.contains(Quirk.apiKeyOptional) || q.contains(Quirk.optionalAPIKey) || q.contains(Quirk.optionalAPIToken))
    }

    /// `{placeholder}` names in the base URL template.
    public var baseURLPlaceholders: [String] { Placeholders.names(in: baseURL) }

    public func model(_ id: String) -> ModelDescriptor? { models.first { $0.id == id } }

    /// Capabilities for a model of this provider: from the catalogue entry, or conservative defaults for models the
    /// catalogue does not list (local servers, custom ids): tools assumed, vision not.
    public func capabilities(forModel modelID: String) -> ModelCapabilities {
        capabilities(of: model(modelID), modelID: modelID)
    }

    func capabilities(of entry: ModelDescriptor?, modelID: String) -> ModelCapabilities {
        let q = quirkSet
        var vision = entry?.vision ?? false
        var tools = entry?.tools ?? (apiStyle != .custom)
        if q.applies(Quirk.textOnly, toModel: modelID) { vision = false }
        if q.applies(Quirk.noTools, toModel: modelID) { tools = false }
        let jsonMode: Bool
        switch apiStyle {
        case .anthropic, .custom: jsonMode = false
        case .openai, .gemini, .ollama: jsonMode = !q.applies(Quirk.noJSONMode, toModel: modelID)
        }
        return ModelCapabilities(vision: vision, tools: tools, streaming: !q.applies(Quirk.noStreaming, toModel: modelID),
                                 jsonMode: jsonMode, nativeComputerUse: entry?.nativeComputerUse,
                                 contextWindow: entry?.contextTokens, maxOutputTokens: nil)
    }

    public func modelInfo(_ entry: ModelDescriptor) -> ModelInfo {
        ModelInfo(id: entry.id, displayName: entry.name, capabilities: capabilities(of: entry, modelID: entry.id),
                  free: entry.free, notes: entry.recommended ? "Recommended" : nil)
    }

    /// All catalogue models as ZCore `ModelInfo`s.
    public var modelInfos: [ModelInfo] { models.map(modelInfo) }

    /// A user-added OpenAI-compatible provider.
    public static func custom(id: ProviderID, name: String, baseURL: String, requiresKey: Bool = true,
                              models: [ModelDescriptor] = [], defaultModel: String? = nil, kind: ProviderKind? = nil,
                              quirks: [String] = []) -> ProviderDescriptor {
        let host = URL(string: baseURL)?.host?.lowercased() ?? ""
        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local")
        return ProviderDescriptor(id: id, name: name, kind: kind ?? (isLoopback ? .local : .paid), apiStyle: .openai,
                                  baseURL: baseURL, authHeader: requiresKey ? .bearer : .noAuth, modelsEndpoint: "/models",
                                  models: models, quirks: quirks, defaultModel: defaultModel ?? models.first?.id ?? "")
    }
}

/// `{placeholder}` helpers for base URL templates.
public enum Placeholders {
    /// Names between braces, in order of appearance.
    public static func names(in template: String) -> [String] {
        var names: [String] = []
        var current: String?
        for ch in template {
            if ch == "{" { current = "" } else if ch == "}" {
                if let name = current, !name.isEmpty { names.append(name) }
                current = nil
            } else if current != nil {
                current?.append(ch)
            }
        }
        return names
    }

    /// Replaces `{name}` with the value for each known name; unknown placeholders stay.
    public static func fill(_ template: String, values: [String: String]) -> String {
        var out = template
        for (name, value) in values {
            out = out.replacingOccurrences(of: "{\(name)}", with: value)
        }
        return out
    }
}
