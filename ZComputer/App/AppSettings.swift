import Foundation
import ZAgent
import ZCore

/// UserDefaults keys (views bind them with `@AppStorage`; models read them through `AgentSettings`).
enum SettingsKey {
    static let agentProvider = "agent.provider"
    static let agentModel = "agent.model"
    /// "none", "demo" or a VM id.
    static let agentMachine = "agent.machine"
    static let maxSteps = "agent.maxSteps"
    static let approvalMode = "agent.approvalMode"
    static let screenshotMaxEdge = "agent.screenshotMaxEdge"
    static let stepDelay = "agent.stepDelay"
    static let toolCallMode = "agent.toolCallMode"
    static let nativeComputerUse = "agent.nativeComputerUse"
    static let keepScreenshots = "agent.keepScreenshots"
    static let showExperimentalModels = "local.showExperimental"
    static let cloudConsentPrefix = "consent.cloud."

    static func cloudConsent(_ provider: ProviderID) -> String { cloudConsentPrefix + provider.rawValue }
}

/// Provider ids that never leave the Mac and are not in providers.json.
enum AppProviders {
    /// In-app MLX models (`ZLocal.LocalModelCatalog.providerID`).
    static let mlx = ProviderID("mlx")
    /// Apple's on-device Foundation Models.
    static let apple = ProviderID("apple")
    static let appleModelID = "system"
}

/// Typed access to the agent settings.
enum AgentSettings {
    static var defaults: UserDefaults { .standard }

    /// The model the Agent view uses (nil until the user picks one).
    static func modelRef() -> ModelRef? {
        guard let provider = defaults.string(forKey: SettingsKey.agentProvider), !provider.isEmpty,
              let model = defaults.string(forKey: SettingsKey.agentModel), !model.isEmpty else { return nil }
        return ModelRef(provider: ProviderID(provider), model: model)
    }

    static func setModel(_ ref: ModelRef?) {
        defaults.set(ref?.provider.rawValue, forKey: SettingsKey.agentProvider)
        defaults.set(ref?.model, forKey: SettingsKey.agentModel)
    }

    /// The policy built from the Settings ▸ Agent values (defaults where unset).
    static func policy() -> AgentPolicy {
        var policy = AgentPolicy()
        let d = defaults
        if d.object(forKey: SettingsKey.maxSteps) != nil { policy.maxSteps = max(1, d.integer(forKey: SettingsKey.maxSteps)) }
        if let raw = d.string(forKey: SettingsKey.approvalMode), let mode = ApprovalMode(rawValue: raw) {
            policy.approvalMode = mode
        }
        if d.object(forKey: SettingsKey.screenshotMaxEdge) != nil {
            policy.screenshotMaxEdge = max(256, d.integer(forKey: SettingsKey.screenshotMaxEdge))
        }
        if d.object(forKey: SettingsKey.stepDelay) != nil { policy.stepDelay = max(0, d.double(forKey: SettingsKey.stepDelay)) }
        if let raw = d.string(forKey: SettingsKey.toolCallMode), let mode = ToolCallMode(rawValue: raw) {
            policy.toolCallMode = mode
        }
        if d.object(forKey: SettingsKey.nativeComputerUse) != nil {
            policy.useNativeComputerUse = d.bool(forKey: SettingsKey.nativeComputerUse)
        }
        if d.object(forKey: SettingsKey.keepScreenshots) != nil {
            policy.keepScreenshots = max(1, d.integer(forKey: SettingsKey.keepScreenshots))
        }
        return policy
    }

    // MARK: Consent (App Review 5.1.2(i) / 2.5.14)

    static func hasCloudConsent(_ provider: ProviderID) -> Bool {
        defaults.bool(forKey: SettingsKey.cloudConsent(provider))
    }

    static func setCloudConsent(_ provider: ProviderID, granted: Bool) {
        defaults.set(granted, forKey: SettingsKey.cloudConsent(provider))
    }

    /// Providers the user allowed to receive screenshots.
    static func consentedProviders() -> [String] {
        defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(SettingsKey.cloudConsentPrefix) && defaults.bool(forKey: $0) }
            .map { String($0.dropFirst(SettingsKey.cloudConsentPrefix.count)) }
            .sorted()
    }

    static func resetCloudConsents() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(SettingsKey.cloudConsentPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}

/// Small formatting helpers shared by the views.
enum Format {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func gigabytes(_ value: Double) -> String {
        String(format: "%.1f GB", value)
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    static func describe(_ error: Error) -> String {
        if let z = error as? ZError { return z.description }
        return error.localizedDescription
    }
}
