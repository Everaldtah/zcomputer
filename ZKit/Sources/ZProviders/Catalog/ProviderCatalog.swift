import Foundation
import ZCore

/// The provider catalogue: the bundled `providers.json` plus any user-added providers.
public struct ProviderCatalog: Sendable, Hashable {
    /// Every provider, bundled ones first, in catalogue order.
    public private(set) var all: [ProviderDescriptor]
    public private(set) var byID: [ProviderID: ProviderDescriptor]

    public init(providers: [ProviderDescriptor]) {
        var seen: [ProviderID: Int] = [:]
        var list: [ProviderDescriptor] = []
        for provider in providers {
            if let index = seen[provider.id] {
                list[index] = provider          // later entries replace earlier ones with the same id
            } else {
                seen[provider.id] = list.count
                list.append(provider)
            }
        }
        all = list
        byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Decodes a providers.json document (a JSON array of providers).
    public init(data: Data) throws {
        do {
            self.init(providers: try JSONDecoder().decode([ProviderDescriptor].self, from: data))
        } catch {
            throw ZError.decoding("providers.json: \(error)")
        }
    }

    /// Loads the catalogue bundled with ZProviders (`Resources/providers.json`).
    public static func loadBundled() throws -> ProviderCatalog {
        guard let url = Bundle.module.url(forResource: "providers", withExtension: "json") else {
            throw ZError.notFound("providers.json is missing from the ZProviders bundle")
        }
        return try ProviderCatalog(data: try Data(contentsOf: url))
    }

    /// The bundled catalogue (empty only if the resource could not be read, which `loadBundled()` reports).
    public static let bundled: ProviderCatalog = (try? loadBundled()) ?? ProviderCatalog(providers: [])

    // MARK: Queries

    /// Providers with a renewing free quota or a meaningful trial (`kind` free or freemium).
    public var free: [ProviderDescriptor] { all.filter(\.offersFreeUse) }
    /// Servers on the user's Mac or LAN.
    public var local: [ProviderDescriptor] { all.filter(\.isLocal) }

    public func provider(_ id: ProviderID) -> ProviderDescriptor? { byID[id] }

    public subscript(id: ProviderID) -> ProviderDescriptor? { byID[id] }

    /// Catalogue models of a provider as ZCore `ModelInfo`s.
    public func models(for id: ProviderID) -> [ModelInfo] { byID[id]?.modelInfos ?? [] }

    public func modelInfo(_ ref: ModelRef) -> ModelInfo? {
        guard let provider = byID[ref.provider], let entry = provider.model(ref.model) else { return nil }
        return provider.modelInfo(entry)
    }

    /// Capabilities of a model (catalogue entry, or defaults for unlisted ids); nil for an unknown provider.
    public func capabilities(_ ref: ModelRef) -> ModelCapabilities? {
        byID[ref.provider]?.capabilities(forModel: ref.model)
    }

    /// The provider's default model, or its first catalogue model, or nil (local servers, templates).
    public func defaultModel(for id: ProviderID) -> ModelRef? {
        guard let provider = byID[id] else { return nil }
        if !provider.defaultModel.isEmpty { return ModelRef(provider: id, model: provider.defaultModel) }
        if let first = provider.models.first { return ModelRef(provider: id, model: first.id) }
        return nil
    }

    /// Every model marked free, across providers.
    public var freeModels: [ModelRef] {
        all.flatMap { p in p.models.filter(\.free).map { ModelRef(provider: p.id, model: $0.id) } }
    }

    /// Models with a native computer-use tool.
    public var nativeComputerUseModels: [ModelRef] {
        all.flatMap { p in p.models.filter { $0.nativeComputerUse != nil }.map { ModelRef(provider: p.id, model: $0.id) } }
    }

    // MARK: Custom providers

    /// A catalogue with the given user-added providers appended (a custom provider with an existing id replaces it).
    public func merge(custom: [ProviderDescriptor]) -> ProviderCatalog {
        ProviderCatalog(providers: all + custom)
    }

    /// Merges whatever the store holds; a failing store leaves the catalogue unchanged.
    public func merging(customStore: any CustomProviderStore) async -> ProviderCatalog {
        guard let custom = try? await customStore.customProviders() else { return self }
        return merge(custom: custom)
    }
}

/// Where user-added (OpenAI-compatible) providers are kept. The app persists them; tests use the in-memory store.
public protocol CustomProviderStore: Sendable {
    func customProviders() async throws -> [ProviderDescriptor]
    func save(_ provider: ProviderDescriptor) async throws
    func remove(_ id: ProviderID) async throws
}

public actor InMemoryCustomProviderStore: CustomProviderStore {
    private var providers: [ProviderDescriptor]

    public init(providers: [ProviderDescriptor] = []) { self.providers = providers }

    public func customProviders() async throws -> [ProviderDescriptor] { providers }

    public func save(_ provider: ProviderDescriptor) async throws {
        if let index = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[index] = provider
        } else {
            providers.append(provider)
        }
    }

    public func remove(_ id: ProviderID) async throws {
        providers.removeAll { $0.id == id }
    }
}
