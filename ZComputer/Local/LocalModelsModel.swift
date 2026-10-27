import Foundation
import Observation
import ZCore
import ZLocal

/// Where a model download is.
enum ModelDownloadState: Hashable {
    case planning
    case downloading(ModelDownloadProgress)
    case finishing
    case failed(String)
}

/// Settings ▸ Local models: servers found by ZLocal's `LocalServerDiscovery`, the curated MLX catalogue with real
/// downloads into `LocalModelStore`, and what this Mac can run (`HostCapabilities`).
@Observable
@MainActor
final class LocalModelsModel {
    private(set) var servers: [LocalServer] = []
    private(set) var isScanning = false
    private(set) var lastScan: Date?
    private(set) var installed: [InstalledLocalModel] = []
    private(set) var incomplete: [InstalledLocalModel] = []
    private(set) var downloads: [String: ModelDownloadState] = [:]
    private(set) var diskUsage: Int64 = 0
    var lastError: String?

    let store: LocalModelStore
    let host: HostCapabilities
    let keyStore: KeychainKeyStore
    let discovery: LocalServerDiscovery
    private let downloader = ModelDownloader()
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    init(store: LocalModelStore, host: HostCapabilities, keyStore: KeychainKeyStore) {
        self.store = store
        self.host = host
        self.keyStore = keyStore
        self.discovery = LocalServerDiscovery()
    }

    /// True when this build can run MLX models (built with ZC_MLX).
    static var hasMLXRuntime: Bool {
        #if ZC_MLX
        return true
        #else
        return false
        #endif
    }

    func catalogue(includeExperimental: Bool) -> [LocalModelSpec] {
        LocalModelCatalog.models.filter { includeExperimental || !$0.experimental }.sorted { $0.priority < $1.priority }
    }

    var embedders: [LocalModelSpec] { LocalModelCatalog.embedders }

    func fitIssues(_ spec: LocalModelSpec) -> [HostCapabilities.FitIssue] { host.fitIssues(model: spec) }

    func isInstalled(_ id: String) -> Bool { installed.contains { $0.id == id } }

    // MARK: Servers

    func rescan() async {
        guard !isScanning else { return }
        isScanning = true
        servers = await discovery.scan()
        lastScan = Date()
        isScanning = false
    }

    /// Probes a user-entered address (LAN servers are never scanned automatically).
    func addEndpoint(_ text: String) async {
        guard let endpoint = LocalEndpoint(string: text) else {
            lastError = "Not an address: \(text) (use host:port or http://host:port)"
            return
        }
        let custom = await discovery.customEndpoints
        await discovery.setCustomEndpoints(custom + [endpoint])
        await rescan()
    }

    // MARK: Installed models

    func refreshInstalled() async {
        installed = await store.installed
        incomplete = await store.incomplete
        diskUsage = await store.totalSizeOnDisk()
    }

    func delete(_ id: String) async {
        tasks[id]?.cancel()
        do {
            try await store.delete(id: id)
        } catch {
            lastError = Format.describe(error)
        }
        downloads[id] = nil
        await refreshInstalled()
    }

    // MARK: Downloads

    func download(_ spec: LocalModelSpec) {
        guard tasks[spec.id] == nil else { return }
        let id = spec.id
        downloads[id] = .planning
        let model = self   // lives as long as the app
        tasks[id] = Task {
            do {
                let token = await model.keyStore.apiKey(for: ProviderID("huggingface"))
                let plan = try await model.store.downloadPlan(for: id, token: token)
                if let free = model.host.availableDiskBytes, free < plan.totalBytes {
                    throw ZError.unsupported("Not enough disk space: \(Format.bytes(plan.totalBytes)) needed, "
                                             + "\(Format.bytes(free)) free.")
                }
                try await model.store.prepareDirectory(for: id)
                try await model.downloader.download(plan: plan, token: token) { progress in
                    Task { @MainActor in
                        if case .failed = model.downloads[id] { return }
                        model.downloads[id] = .downloading(progress)
                    }
                }
                model.downloads[id] = .finishing
                try await model.store.markInstalled(id: id, plan: plan)
                model.downloads[id] = nil
            } catch is CancellationError {
                model.downloads[id] = nil
            } catch {
                model.downloads[id] = .failed(Format.describe(error))
            }
            model.tasks[id] = nil
            await model.refreshInstalled()
        }
    }

    func cancelDownload(_ id: String) {
        tasks[id]?.cancel()
    }

    func clearFailure(_ id: String) {
        if case .failed = downloads[id] { downloads[id] = nil }
    }
}
