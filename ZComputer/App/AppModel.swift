import Foundation
import Observation
import ZAgent
import ZCore
import ZLocal
import ZMemory
import ZProviders

/// The sidebar sections of the main window.
enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
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

/// Root state of the app: the shared services (Keychain, event bus, library, catalogue, local models, VMs) and the
/// per-screen models. Lives for the whole app session.
@Observable
@MainActor
final class AppModel {
    var selection: SidebarItem? = .agent

    let keyStore: KeychainKeyStore
    /// Every agent (the Agent view's and each team member) emits here; the activity panel subscribes.
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
    let shell: HostShellSession

    @ObservationIgnored private var started = false

    init() {
        let keyStore = KeychainKeyStore()
        let bus = EventBus(historyLimit: 4000)
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
            memory = try SQLiteMemoryStore(path: AppPaths.libraryDatabase.path, embedder: embedder)
            status = "Library at \(AppPaths.libraryDatabase.path), \(embedderName)"
        } catch {
            memory = nil
            status = "The library could not be opened: \(Format.describe(error))"
        }

        let modelsRoot = (try? LocalModelStore.defaultRoot())
            ?? AppPaths.supportDirectory.appendingPathComponent("Models", isDirectory: true)
        let host = HostCapabilities.current(modelsRoot: modelsRoot)

        self.keyStore = keyStore
        self.bus = bus
        self.imageResizer = resizer
        self.customProviderStore = FileCustomProviderStore.standard()
        self.catalog = ProviderCatalog.bundled
        self.memory = memory
        self.memoryStatus = status
        self.host = host
        self.localModels = LocalModelsModel(store: LocalModelStore(root: modelsRoot), host: host, keyStore: keyStore)
        self.library = LibraryModel(store: memory)
        self.machines = MachinesModel(keyStore: keyStore)
        self.agent = AgentSession(bus: bus, memory: memory, resizer: resizer)
        self.team = TeamModel(bus: bus, memory: memory, resizer: resizer)
        self.shell = HostShellSession()

        agent.resolver = self
        agent.machines = machines
        agent.team = team
        team.resolver = self
        team.machines = machines
    }

    /// First-launch work: custom providers, local server scan, installed models, library counts, VM list.
    func start() async {
        guard !started else { return }
        started = true
        machines.reload()
        await reloadCatalog()
        await library.reload()
        await localModels.refreshInstalled()
        await localModels.rescan()
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

    /// Every model the pickers offer: catalogue models, discovered local-server models, downloaded MLX models and
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
                                       title: model.spec?.name ?? model.id, group: "On this Mac (MLX)", free: true))
        }
        #endif
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            choices.append(ModelChoice(ref: ModelRef(provider: AppProviders.apple, model: AppProviders.appleModelID),
                                       title: "Apple on-device model", group: "On this Mac", free: true))
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
