import Foundation
import ZCore

/// The outcome of a Settings ▸ Providers "Test" button press.
public struct KeyTestResult: Sendable, Equatable {
    public enum Method: String, Sendable, Hashable { case completion, listModels }

    public var providerID: ProviderID
    public var ok: Bool
    /// Seconds until the first streamed event (completion) or the whole list (listModels).
    public var latency: TimeInterval
    public var method: Method
    public var model: String?
    public var modelCount: Int?
    /// "OK" or the provider's error, ready to show.
    public var message: String
    public var error: ZError?

    public init(providerID: ProviderID, ok: Bool, latency: TimeInterval, method: Method, model: String? = nil,
                modelCount: Int? = nil, message: String, error: ZError? = nil) {
        self.providerID = providerID; self.ok = ok; self.latency = latency; self.method = method; self.model = model
        self.modelCount = modelCount; self.message = message; self.error = error
    }
}

/// Validates a provider key with the cheapest real request: a tiny completion when a model is known (a public
/// `/models` list would not prove the key works), otherwise `listModels()`.
public enum KeyTester {
    public static let prompt = "Reply with the single word OK."

    public static func test(provider: ProviderDescriptor, model: String? = nil, keyStore: any KeyStore,
                            transport: any Transport = URLSessionTransport.shared) async -> KeyTestResult {
        let modelID = (model ?? provider.defaultModel).trimmingCharacters(in: .whitespacesAndNewlines)
        let method: KeyTestResult.Method = modelID.isEmpty ? .listModels : .completion
        let client: any LLMClient
        do {
            client = try await ProviderClientFactory.makeClient(provider: provider, model: modelID.isEmpty ? "probe" : modelID,
                                                                keyStore: keyStore, http: HTTPClient(transport: transport, retry: .none))
        } catch {
            return failure(provider, method: method, model: modelID, latency: 0, error: error)
        }
        let started = Date()
        do {
            switch method {
            case .completion:
                let options = GenerationOptions(maxTokens: 64)
                var sawEvent = false
                for try await _ in client.stream(messages: [.user(prompt)], tools: [], options: options) {
                    sawEvent = true
                    break
                }
                let latency = Date().timeIntervalSince(started)
                return KeyTestResult(providerID: provider.id, ok: true, latency: latency, method: .completion,
                                     model: modelID, message: sawEvent ? "OK" : "OK (empty response)")
            case .listModels:
                let models = try await client.listModels()
                let latency = Date().timeIntervalSince(started)
                return KeyTestResult(providerID: provider.id, ok: true, latency: latency, method: .listModels,
                                     modelCount: models.count, message: "OK, \(models.count) models")
            }
        } catch {
            return failure(provider, method: method, model: modelID, latency: Date().timeIntervalSince(started), error: error)
        }
    }

    static func failure(_ provider: ProviderDescriptor, method: KeyTestResult.Method, model: String, latency: TimeInterval,
                        error: Error) -> KeyTestResult {
        let zError = (HTTPClient.normalize(error) as? ZError) ?? .network(error.localizedDescription)
        let message: String
        switch zError {
        case .http(let status, let body) where status == 401 || status == 403:
            message = "Key rejected (HTTP \(status)): \(body)"
        case .missingAPIKey:
            message = "No API key saved for \(provider.name)."
        default:
            message = zError.description
        }
        return KeyTestResult(providerID: provider.id, ok: false, latency: latency, method: method,
                             model: model.isEmpty ? nil : model, message: message, error: zError)
    }
}
