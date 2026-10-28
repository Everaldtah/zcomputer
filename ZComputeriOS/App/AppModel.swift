import Foundation
import Observation
import ZAgent
import ZCore
import ZLocal
import ZMemory
import ZProviders

/// The tabs of the iPhone/iPad app.
enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case machines, agent, team, library, terminal, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .machines: return "Machines"
        case .agent: return "Agent"
        case .team: return "Team"
        case .library: return "Library"
        case .terminal: return "Terminal"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .machines: return "desktopcomputer"
        case .agent: return "sparkles"
        case .team: return "person.3"
        case .library: return "books.vertical"
        case .terminal: return "terminal"
        case .settings: return "gearshape"
        }
    }
}

/// Root state of the iOS app: the Mac app's `AppModel` minus Virtualization.framework and host processes. Shared
/// services (Keychain, event bus, library, catalogue, local models, emulated machines) and the per-screen models.
@Observable
@MainActor
final class AppModel {
    var tab: AppTab = .machines

    let keyStore: KeychainKeyStore
    /// Every agent (the Agent view's and each team member) emits here; the activity views subscribe.
    let bus: EventBus
    let imageResizer: CoreGraphicsImageResizer
    let customProviderStore: FileCustomProviderStore
    /// Bundled providers.json (ZProviders) plus the user's custom providers.
    private(set) var catalog: ProviderCatalog
    /// The personal library (nil only when the database cannot be opened; `memoryStatus` says why).
    let memory: SQLiteMemoryStore?
    let memoryStatus: String
    let host: HostCapabilities

    let agent: AgentSession
    let library: LibraryModel
    let localModels: LocalModelsModel
    let machines: MachinesModel
    let team: TeamModel
    /// Model servers the user added by address (persisted), e.g. Ollama on their Mac over Tailscale.
    private(set) var remoteHosts: [String]

    @ObservationIgnored private var started = false

    static let remoteHostsKey = "local.remoteHosts"

    init(engine: any MachineEngine) {
        let keyStore = KeychainKeyStore()
        let bus = EventBus(historyLimit: 3000)
        let resizer = CoreGraphicsImageResizer()

        // Library: on-device sentence embeddings (NaturalLanguage), hashing embeddings when the OS has none.
        let embedder: any Embedder
        let embedderName: String
        if let nl = NLEmbedder(languageCode: "en") {
            embedder = nl
            embedderName = "Apple NaturalLanguage sentence embeddings (\(nl.dimensions)-d)"
        } else {
            embedder = HashingEmbedder()
            embedderName = "hashing embeddings (NaturalLanguage has no English sentence model here)"
        }
        let memory: SQLiteMemoryStore?
        let status: String
        do {
            try FileManager.default.createDirectory(at: AppPaths.libraryDatabase.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            memory = try SQLiteMemoryStore(path: AppPaths.libraryDatabase.path, embedder: embedder)
            status = "On this device, \(embedderName)"
        } catch {
            memory = nil
            status = "The library could not be opened: \(Format.describe(error))"
        }

        let modelsRoot = (try? LocalModelStore.defaultRoot())
            ?? AppPaths.supportDirectory.appendingPathComponent("Models", isDirectory: true)
        let host = DeviceInfo.capabilities(modelsRoot: modelsRoot)

        self.keyStore = keyStore
        self.bus = bus
        self.imageResizer = resizer
        self.customProviderStore = FileCustomProviderStore.standard()
        self.catalog = ProviderCatalog.bundled
        self.memory = memory
        self.memoryStatus = status
        self.host = host
        self.remoteHosts = UserDefaults.standard.stringArray(forKey: Self.remoteHostsKey) ?? []
        self.localModels = LocalModelsModel(store: LocalModelStore(root: modelsRoot), host: host, keyStore: keyStore)
        self.library = LibraryModel(store: memory)
        self.machines = MachinesModel(keyStore: keyStore, engine: engine)
        self.agent = AgentSession(bus: bus, memory: memory, resizer: resizer)
        self.team = TeamModel(bus: bus, memory: memory, resizer: resizer)

        agent.resolver = self
        agent.machines = machines
        agent.team = team
        team.resolver = self
        team.machines = machines
    }

    /// First-launch work: custom providers, remote model hosts, installed models, library counts, machines.
    func start() async {
        guard !started else { return }
        started = true
        machines.reload()
        await reloadCatalog()
        await library.reload()
        await localModels.refreshInstalled()
        await applyRemoteHosts()
    }

    func reloadCatalog() async {
        catalog = await ProviderCatalog.bundled.merging(customStore: customProviderStore)
    }

    /// Adds (or replaces) a user-defined OpenAI-compatible provider.
    func saveCustomProvider(_ provider: ProviderDescriptor) async throws {
        try await customProviderStore.save(provider)
        await reloadCatalog()
    }

    func removeCustomProvider(_ id: ProviderID) async throws {
        try await customProviderStore.remove(id)
        await reloadCatalog()
    }

    /// Ids of user-added providers (for the Settings list).
    var customProviderIDs: Set<ProviderID> {
        let bundled = Set(ProviderCatalog.bundled.all.map(\.id))
        return Set(catalog.all.map(\.id)).subtracting(bundled)
    }

    // MARK: Remote model hosts

    /// Adds a model server by address ("100.101.102.103:11434", "http://mac.tailnet.ts.net:1234") and rescans.
    func addRemoteHost(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard LocalEndpoint(string: trimmed) != nil else {
            localModels.lastError = "Not an address: \(trimmed) (use host:port or http://host:port)"
            return
        }
        if !remoteHosts.contains(trimmed) { remoteHosts.append(trimmed) }
        UserDefaults.standard.set(remoteHosts, forKey: Self.remoteHostsKey)
        await applyRemoteHosts()
    }

    func removeRemoteHost(_ text: String) async {
        remoteHosts.removeAll { $0 == text }
        UserDefaults.standard.set(remoteHosts, forKey: Self.remoteHostsKey)
        await applyRemoteHosts()
    }

    /// Hands the saved hosts to ZLocal's discovery and probes them (iOS asks for local-network permission once).
    func applyRemoteHosts() async {
        let endpoints = remoteHosts.compactMap { LocalEndpoint(string: $0) }
        await localModels.discovery.setCustomEndpoints(endpoints)
        await localModels.rescan()
    }

    // MARK: Model pickers

    /// Every model the pickers offer: catalogue models, models on the user's servers, downloaded MLX models and
    /// Apple's on-device model.
    func pickerModels() -> [ModelChoice] {
        var choices: [ModelChoice] = []
        for provider in catalog.all where !provider.isLocal {
            for model in provider.models {
                choices.append(ModelChoice(ref: ModelRef(provider: provider.id, model: model.id),
                                           title: "\(model.name)", group: provider.name, free: model.free))
            }
        }
        for server in localModels.servers where server.reachable {
            for model in server.models {
                choices.append(ModelChoice(ref: ModelRef(provider: server.providerID, model: model.id),
                                           title: model.displayName, group: server.name, free: true))
            }
        }
        #if ZC_MLX
        for model in localModels.installed {
            choices.append(ModelChoice(ref: ModelRef(provider: AppProviders.mlx, model: model.id),
                                       title: model.spec?.name ?? model.id, group: "On this device (MLX)", free: true))
        }
        #endif
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            choices.append(ModelChoice(ref: ModelRef(provider: AppProviders.apple, model: AppProviders.appleModelID),
                                       title: "Apple on-device model", group: "On this device", free: true))
        }
        #endif
        return choices
    }
}

/// One entry of a model picker.
struct ModelChoice: Identifiable, Hashable {
    var ref: ModelRef
    var title: String
    var group: String
    var free: Bool
    var id: String { ref.description }
}
