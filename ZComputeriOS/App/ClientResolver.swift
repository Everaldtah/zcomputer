import Foundation
import ZCore
import ZLocal
import ZProviders

/// Picks the `LLMClient` for a model reference: catalogue providers through ZProviders' `ProviderClientFactory`,
/// model servers the user added (Ollama / LM Studio on a Mac over Tailscale or the LAN) at the address discovery
/// found them on, the in-app MLX runner (`ZC_MLX` builds) and Apple's on-device model (iOS 26+).
/// `AgentSession` and `TeamModel` (shared with the Mac app) talk to this protocol.
@MainActor
protocol ClientResolver: AnyObject {
    func makeClient(for ref: ModelRef) async throws -> any LLMClient
    /// True when the model runs on this device or on the user's own server (no consent needed for screenshots).
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
        // A server the user added (e.g. Ollama on a Mac at 100.x.y.z:11434) wins over the catalogue's loopback URL,
        // unless a base URL override is set, and its discovered models carry their real capabilities.
        if provider.isLocal, let server = localModels.servers.first(where: { $0.providerID == ref.provider && $0.reachable })
            ?? localModels.servers.first(where: { $0.providerID == ref.provider }) {
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
            return "\(LocalModelCatalog.byID(ref.model)?.name ?? ref.model) (on this device, MLX)"
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
        let spec = LocalModelCatalog.byID(ref.model)
        if let spec, let warning = DeviceInfo.memoryWarning(forModelBytes: spec.sizeBytes) {
            throw ZError.unsupported(warning)
        }
        MLXMemoryBudget.applyForPhone()
        return MLXClient(ref: ref, directory: directory, spec: spec, host: host)
        #else
        throw ZError.unsupported("This build of Z Computer has no MLX runtime (built without ZC_MLX). "
                                 + "Add a model server (Ollama, LM Studio) in Settings ▸ Local models instead.")
        #endif
    }

    private func makeAppleClient() throws -> any LLMClient {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return FoundationModelsClient()
        }
        #endif
        throw ZError.unsupported("Apple's on-device model needs iOS 26 with Apple Intelligence turned on.")
    }
}
