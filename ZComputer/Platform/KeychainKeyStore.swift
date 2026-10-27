import Foundation
import Security
import ZCore

/// API keys, base-URL overrides and other small secrets (VM passwords) in the login Keychain, as generic passwords
/// under the service `com.everaldtah.zcomputer`. Sandboxed apps get their own Keychain access group automatically.
final class KeychainKeyStore: KeyStore, Sendable {
    let service: String

    init(service: String = "com.everaldtah.zcomputer") {
        self.service = service
    }

    // MARK: KeyStore

    func apiKey(for provider: ProviderID) async -> String? {
        secret(account: Self.keyAccount(provider))
    }

    func setAPIKey(_ key: String?, for provider: ProviderID) async throws {
        try setSecret(key?.trimmingCharacters(in: .whitespacesAndNewlines), account: Self.keyAccount(provider))
    }

    func baseURLOverride(for provider: ProviderID) async -> URL? {
        guard let text = secret(account: Self.baseURLAccount(provider)), !text.isEmpty else { return nil }
        return URL(string: text)
    }

    func setBaseURLOverride(_ url: URL?, for provider: ProviderID) async throws {
        try setSecret(url?.absoluteString, account: Self.baseURLAccount(provider))
    }

    // MARK: Generic secrets

    /// The stored string for `account`, or nil.
    func secret(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores `value` for `account`; nil or empty deletes the item.
    func setSecret(_ value: String?, account: String) throws {
        let query = baseQuery(account: account)
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(status, "delete") }
            return
        }
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            add[kSecAttrLabel as String] = "Z Computer: \(account)"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Self.error(status, "save") }
    }

    func hasSecret(account: String) -> Bool { secret(account: account) != nil }

    // MARK: Helpers

    static func keyAccount(_ provider: ProviderID) -> String { "apikey.\(provider.rawValue)" }
    static func baseURLAccount(_ provider: ProviderID) -> String { "baseurl.\(provider.rawValue)" }
    static func vmPasswordAccount(_ id: UUID) -> String { "vm.password.\(id.uuidString)" }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func error(_ status: OSStatus, _ action: String) -> ZError {
        let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
        return ZError.unsupported("Keychain \(action) failed: \(message)")
    }
}
