import Foundation
import ZCore

/// Which client class serves a provider/model.
public enum ClientKind: String, Sendable, Hashable {
    case openAIChat, openAIResponses, anthropic, gemini, ollama
}

/// Builds `LLMClient`s from catalogue entries: resolves the key and base URL (override + `{placeholders}`), picks the
/// client by `apiStyle` and native capability.
public enum ProviderClientFactory {
    /// The client for `model` (default: the provider's default model) on `provider`.
    /// Throws `ZError.unsupported` for `apiStyle: custom` providers (Perplexity's Agent API), `ZError.missingAPIKey`
    /// when a required key is absent, and `ZError.invalidArgument` for unfilled base-URL placeholders.
    public static func makeClient(provider: ProviderDescriptor, model: String? = nil, keyStore: any KeyStore,
                                  transport: any Transport = URLSessionTransport.shared,
                                  retry: RetryPolicy = .standard) async throws -> any LLMClient {
        try await makeClient(provider: provider, model: model, keyStore: keyStore,
                             http: HTTPClient(transport: transport, retry: retry))
    }

    /// Same, for a `ModelRef` looked up in a catalogue.
    public static func makeClient(_ ref: ModelRef, catalog: ProviderCatalog, keyStore: any KeyStore,
                                  transport: any Transport = URLSessionTransport.shared) async throws -> any LLMClient {
        guard let provider = catalog.provider(ref.provider) else {
            throw ZError.notFound("Provider \(ref.provider.rawValue) is not in the catalogue")
        }
        return try await makeClient(provider: provider, model: ref.model, keyStore: keyStore, transport: transport)
    }

    /// Full control over the HTTP client (timeouts, logging, retry sleeper).
    public static func makeClient(provider: ProviderDescriptor, model: String?, keyStore: any KeyStore,
                                  http: HTTPClient) async throws -> any LLMClient {
        if provider.apiStyle == .custom {
            throw ZError.unsupported("\(provider.name) uses its own API format (apiStyle \"custom\"), which Z Computer "
                                     + "does not speak yet. Pick another provider.")
        }
        let modelID = (model ?? provider.defaultModel).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else {
            throw ZError.invalidArgument("Choose a model for \(provider.name) (it has no default model).")
        }
        let endpoint = try await resolveEndpoint(provider: provider, keyStore: keyStore)
        let capabilities = provider.capabilities(forModel: modelID)
        let ref = ModelRef(provider: provider.id, model: modelID)
        let quirks = provider.quirkSet
        let catalog = provider.modelInfos
        switch clientKind(provider: provider, modelID: modelID) {
        case .openAIChat:
            return OpenAIChatClient(model: ref, capabilities: capabilities, endpoint: endpoint, http: http,
                                    quirks: quirks, modelsEndpoint: provider.modelsEndpoint, catalogModels: catalog)
        case .openAIResponses:
            return OpenAIResponsesClient(model: ref, capabilities: capabilities, endpoint: endpoint, http: http,
                                         quirks: quirks, modelsEndpoint: provider.modelsEndpoint, catalogModels: catalog)
        case .anthropic:
            return AnthropicClient(model: ref, capabilities: capabilities, endpoint: endpoint, http: http,
                                   quirks: quirks, modelsEndpoint: provider.modelsEndpoint, catalogModels: catalog)
        case .gemini:
            return GeminiClient(model: ref, capabilities: capabilities, endpoint: endpoint, http: http,
                                quirks: quirks, modelsEndpoint: provider.modelsEndpoint, catalogModels: catalog)
        case .ollama:
            return OllamaClient(model: ref, capabilities: capabilities, endpoint: endpoint, http: http,
                                quirks: quirks, modelsEndpoint: provider.modelsEndpoint ?? "/api/tags", catalogModels: catalog)
        }
    }

    /// The client class for a model: Responses for native OpenAI computer use or `toolsRequireResponsesAPI` models,
    /// otherwise by `apiStyle`.
    public static func clientKind(provider: ProviderDescriptor, modelID: String) -> ClientKind {
        switch provider.apiStyle {
        case .anthropic: return .anthropic
        case .gemini: return .gemini
        case .ollama: return .ollama
        case .openai, .custom:
            let native = provider.model(modelID)?.nativeComputerUse
            if native == .openAIComputer || provider.quirkSet.applies(Quirk.toolsRequireResponsesAPI, toModel: modelID) {
                return .openAIResponses
            }
            return .openAIChat
        }
    }

    /// Key + base URL (override and placeholders) for a provider.
    public static func resolveEndpoint(provider: ProviderDescriptor, keyStore: any KeyStore) async throws -> ProviderEndpoint {
        let storedKey = await keyStore.apiKey(for: provider.id)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = (storedKey?.isEmpty ?? true) ? nil : storedKey
        if provider.requiresAPIKey, key == nil { throw ZError.missingAPIKey(provider.id) }
        let override = await keyStore.baseURLOverride(for: provider.id)
        let baseURL = try resolveBaseURL(template: provider.baseURL, override: override, providerName: provider.name)
        return ProviderEndpoint(providerID: provider.id, baseURL: baseURL, auth: provider.authHeader, apiKey: key)
    }

    /// Resolves the base URL:
    /// * an absolute `http(s)` override replaces the template (after filling any placeholders it still has from its
    ///   own query items);
    /// * an override that is only `name=value` pairs (`account_id=abc`, `?region=us-east-1&resource=x`) fills the
    ///   template's `{placeholders}`;
    /// * no override: the template must have no placeholders.
    public static func resolveBaseURL(template: String, override: URL?, providerName: String = "This provider") throws -> URL {
        var base = template
        if let override {
            let values = placeholderValues(from: override)
            if let scheme = override.scheme?.lowercased(), scheme == "http" || scheme == "https", override.host != nil {
                var components = URLComponents(url: override, resolvingAgainstBaseURL: false)
                let usedNames = Set(Placeholders.names(in: template))
                components?.queryItems = components?.queryItems?.filter { !usedNames.contains($0.name) }
                if components?.queryItems?.isEmpty == true { components?.queryItems = nil }
                base = components?.string ?? override.absoluteString
                base = Placeholders.fill(base.removingPercentEncoding ?? base, values: values)
            } else {
                base = Placeholders.fill(template, values: values)
            }
        }
        let missing = Placeholders.names(in: base)
        if !missing.isEmpty {
            let names = missing.map { "{\($0)}" }.joined(separator: ", ")
            throw ZError.invalidArgument("\(providerName) needs \(names) in its base URL: set the base URL override to the "
                                         + "full URL, or to \(missing.map { "\($0)=<value>" }.joined(separator: "&")).")
        }
        guard !base.isEmpty else {
            throw ZError.invalidArgument("\(providerName) needs a base URL: set the base URL override.")
        }
        guard let url = URL(string: base), url.scheme != nil, url.host != nil else {
            throw ZError.invalidArgument("Invalid base URL for \(providerName): \(base)")
        }
        return url
    }

    /// `name=value` pairs from an override's query (or its whole text when it has no scheme).
    static func placeholderValues(from override: URL) -> [String: String] {
        var values: [String: String] = [:]
        if let items = URLComponents(url: override, resolvingAgainstBaseURL: false)?.queryItems {
            for item in items { if let value = item.value, !value.isEmpty { values[item.name] = value } }
        }
        if override.scheme == nil || override.host == nil {
            var text = override.absoluteString.removingPercentEncoding ?? override.absoluteString
            if text.hasPrefix("?") { text.removeFirst() }
            for pair in text.split(whereSeparator: { $0 == "&" || $0 == ";" || $0 == "," }) {
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let name = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, !value.isEmpty { values[name] = value }
            }
        }
        return values
    }
}
