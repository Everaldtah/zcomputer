import Foundation
import ZCore
import ZLocal
import ZProviders

/// Picks the `LLMClient` for a model reference: the catalogue providers through ZProviders'
/// `ProviderClientFactory`, local servers at the address discovery found them on, the in-app MLX runner
/// (`ZC_MLX` builds) and Apple's on-device model (macOS 26+).
@MainActor
protocol ClientResolver: AnyObject {
    func makeClient(for ref: ModelRef) async throws -> any LLMClient
    /// True when the provider runs on this Mac (no consent needed before sending screenshots).
    func isLocal(_ provider: ProviderID) -> Bool
    func displayName(for ref: ModelRef) -> String
}

extension AppModel: ClientResolver {
    func makeClient(for ref: ModelRef) async throws -> any LLMClient {
        switch ref.provider {
        case AppProviders.mlx:
            return try await makeMLXClient(for: ref)
        case AppProviders.apple:
            return try makeAppleClient()
        default:
            break
        }
        guard var provider = catalog.provider(ref.provider) else {
            throw ZError.notFound("Provider \(ref.provider.rawValue) is not in the catalogue")
        }
        // A local server found at a non-default address (e.g. llama-server on 8080) wins over the catalogue URL,
        // unless the user set a base URL override, and its discovered models carry their real capabilities.
        if provider.isLocal, let server = localModels.servers.first(where: { $0.providerID == ref.provider }) {
            if await keyStore.baseURLOverride(for: ref.provider) == nil {
                provider.baseURL = server.baseURL.absoluteString
            }
            let known = Set(provider.models.map(\.id))
            provider.models += server.models.filter { !known.contains($0.id) }.map {
                ModelDescriptor(id: $0.id, name: $0.displayName, vision: $0.capabilities.vision, tools: $0.capabilities.tools,
                                free: true, contextTokens: $0.capabilities.contextWindow)
            }
        }
        return try await ProviderClientFactory.makeClient(provider: provider, model: ref.model, keyStore: keyStore)
    }

    func isLocal(_ provider: ProviderID) -> Bool {
        if provider == AppProviders.mlx || provider == AppProviders.apple { return true }
        return catalog.provider(provider)?.isLocal ?? false
    }

    func displayName(for ref: ModelRef) -> String {
        switch ref.provider {
        case AppProviders.mlx:
            return "\(LocalModelCatalog.byID(ref.model)?.name ?? ref.model) (on this Mac, MLX)"
        case AppProviders.apple:
            return "Apple on-device model"
        default:
            let providerName = catalog.provider(ref.provider)?.name ?? ref.provider.rawValue
            let modelName = catalog.modelInfo(ref)?.displayName ?? ref.model
            return "\(modelName) · \(providerName)"
        }
    }

    // MARK: On-device clients

    private func makeMLXClient(for ref: ModelRef) async throws -> any LLMClient {
        #if ZC_MLX
        let directory = try await localModels.store.directory(for: ref.model)
        guard await localModels.store.isInstalled(ref.model) else {
            throw ZError.notFound("\(ref.model) is not downloaded. Download it in Settings ▸ Local models.")
        }
        return MLXClient(ref: ref, directory: directory, spec: LocalModelCatalog.byID(ref.model), host: host)
        #else
        throw ZError.unsupported("This build of Z Computer has no MLX runtime (built without ZC_MLX). "
                                 + "Use a local server such as Ollama or LM Studio instead.")
        #endif
    }

    private func makeAppleClient() throws -> any LLMClient {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return FoundationModelsClient()
        }
        #endif
        throw ZError.unsupported("Apple's on-device model needs macOS 26 with Apple Intelligence turned on.")
    }
}
