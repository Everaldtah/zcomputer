import Foundation

/// Where API keys live. The app implements this with the Keychain; tests use `InMemoryKeyStore`.
public protocol KeyStore: Sendable {
    func apiKey(for provider: ProviderID) async -> String?
    func setAPIKey(_ key: String?, for provider: ProviderID) async throws
    /// Optional per-provider base URL override (self-hosted gateways, proxies, local servers).
    func baseURLOverride(for provider: ProviderID) async -> URL?
    func setBaseURLOverride(_ url: URL?, for provider: ProviderID) async throws
}

public actor InMemoryKeyStore: KeyStore {
    private var keys: [ProviderID: String] = [:]
    private var urls: [ProviderID: URL] = [:]
    public init(keys: [ProviderID: String] = [:]) { self.keys = keys }
    public func apiKey(for provider: ProviderID) async -> String? { keys[provider] }
    public func setAPIKey(_ key: String?, for provider: ProviderID) async throws { keys[provider] = key }
    public func baseURLOverride(for provider: ProviderID) async -> URL? { urls[provider] }
    public func setBaseURLOverride(_ url: URL?, for provider: ProviderID) async throws { urls[provider] = url }
}
