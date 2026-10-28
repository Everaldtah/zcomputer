import Foundation
import Observation
import UIKit
import ZCore

/// The Machines screen on iPhone/iPad: emulated machines from the `MachineEngine` (ZEmu), their runtimes (kept for
/// the session so machines keep running across tabs), the image catalogue with downloads, ISOs the user dropped into
/// the app's Documents folder, the Demo machine, and the surface the Agent view drives.
@Observable
@MainActor
final class MachinesModel {
    let demo: MockComputerSurface
    let engine: any MachineEngine
    let parking = MachineViewParking()
    let keyStore: KeychainKeyStore

    private(set) var machines: [MachineSummary] = []
    private(set) var states: [UUID: MachineRunState] = [:]
    /// Guest display sizes of machines with a runtime (they change with the guest's video mode).
    private(set) var screenSizes: [UUID: PixelSize] = [:]
    private(set) var errors: [UUID: String] = [:]
    private(set) var listError: String?
    /// The image catalogue (refreshed when an image's manifest is fetched).
    private(set) var catalogue: [MachineImage] = []
    private(set) var isRefreshingCatalogue = false
    private(set) var imageStates: [String: ImageDownloadState] = [:]
    private(set) var userISOs: [URL] = []
    private(set) var isImportingISO = false
    /// Set through `setAgentChoice` (persisted).
    var agentChoice: AgentMachineChoice
    /// The machine shown full screen.
    var presented: MachineEntry?
    /// A machine created from the image library; opened full screen once the library sheet has closed.
    var justCreated: UUID?
    /// A message for the Machines screen's alert.
    var message: String?

    @ObservationIgnored private var runtimes: [UUID: any MachineRuntime] = [:]
    @ObservationIgnored private var surfaces: [UUID: any ComputerSurface] = [:]
    @ObservationIgnored private var watchers: [UUID: [Task<Void, Never>]] = [:]
    @ObservationIgnored private var downloadTasks: [String: Task<Void, Never>] = [:]

    init(keyStore: KeychainKeyStore, engine: any MachineEngine) {
        self.keyStore = keyStore
        self.engine = engine
        self.demo = MockComputerSurface()
        self.catalogue = engine.catalogue()
        let saved = AgentMachineChoice(key: UserDefaults.standard.string(forKey: SettingsKey.agentMachine))
        self.agentChoice = engine.unavailableReason == nil ? saved : (saved == .none ? .none : .demo)
    }

    var isEngineAvailable: Bool { engine.unavailableReason == nil }

    // MARK: List

    func reload() {
        do {
            machines = try engine.listMachines()
            listError = nil
            for machine in machines where states[machine.id] == nil { states[machine.id] = .stopped }
            if case .machine(let id) = agentChoice, !machines.contains(where: { $0.id == id }) { setAgentChoice(.demo) }
        } catch {
            listError = Format.describe(error)
        }
        refreshImageStates()
        refreshISOs()
    }

    func summary(_ id: UUID) -> MachineSummary? { machines.first { $0.id == id } }

    func state(_ id: UUID) -> MachineRunState { states[id] ?? .stopped }

    /// The guest display size of a machine (its spec's screen until the runtime reports the video mode).
    func screenSize(_ id: UUID) -> PixelSize {
        if let size = screenSizes[id], size.width > 0, size.height > 0 { return size }
        guard let summary = summary(id) else { return PixelSize(width: 1024, height: 768) }
        return PixelSize(width: summary.screenWidth, height: summary.screenHeight)
    }

    func dismissError(_ id: UUID) { errors[id] = nil }

    /// The runtime of a machine, made on first use. Its screen view is parked in the window right away.
    func runtime(for id: UUID) throws -> any MachineRuntime {
        if let existing = runtimes[id] {
            // A stopped machine picks up a changed guest-network setting with a new runtime.
            guard !existing.state.isActive, existing.guestNetworkEnabled != MachineSettings.guestNetworkEnabled else {
                return existing
            }
            release(id)
        }
        let runtime = try engine.makeRuntime(for: id)
        runtimes[id] = runtime
        parking.park(runtime.screenView)
        states[id] = runtime.state
        screenSizes[id] = runtime.screenSize
        let updates = runtime.stateStream()
        let sizes = runtime.screenSizeStream()
        watchers[id] = [
            Task { [weak self] in
                for await state in updates {
                    guard let self else { return }
                    self.states[id] = state
                    if case .error(let message) = state { self.errors[id] = message }
                }
            },
            Task { [weak self] in
                for await size in sizes {
                    guard let self else { return }
                    if self.screenSizes[id] != size { self.screenSizes[id] = size }
                }
            },
        ]
        return runtime
    }

    /// Forgets a machine's runtime (its web view, surface and watchers).
    private func release(_ id: UUID) {
        for task in watchers[id] ?? [] { task.cancel() }
        watchers[id] = nil
        if let runtime = runtimes[id] { parking.evict(runtime.screenView) }
        runtimes[id] = nil
        surfaces[id] = nil
        screenSizes[id] = nil
    }

    /// The runtime only when it already exists (views must not create machines just by rendering).
    func existingRuntime(for id: UUID) -> (any MachineRuntime)? { runtimes[id] }

    /// The machine's `ComputerSurface` (one per runtime), nil until the runtime exists.
    func surface(for id: UUID) -> (any ComputerSurface)? {
        if let existing = surfaces[id] { return existing }
        guard let runtime = runtimes[id] else { return nil }
        let surface = runtime.makeSurface()
        surfaces[id] = surface
        return surface
    }

    // MARK: Lifecycle

    func start(_ id: UUID) {
        errors[id] = nil
        Task {
            do {
                let runtime = try self.runtime(for: id)
                try await runtime.start()
            } catch {
                errors[id] = Format.describe(error)
            }
        }
    }

    /// Powers a machine off. With `saveState` the next start resumes exactly here; without, it starts afresh.
    func stop(_ id: UUID, saveState: Bool) {
        guard let runtime = runtimes[id] else { return }
        perform(id) {
            try await runtime.stop(saveState: saveState)
            self.reload()
        }
    }

    func pause(_ id: UUID) {
        guard let runtime = runtimes[id] else { return }
        perform(id) { try await runtime.pause() }
    }

    func resume(_ id: UUID) {
        guard let runtime = runtimes[id] else { return }
        perform(id) { try await runtime.resume() }
    }

    func saveState(_ id: UUID) {
        guard let runtime = runtimes[id] else { return }
        perform(id) {
            try await runtime.saveState()
            self.reload()
        }
    }

    func delete(_ id: UUID) {
        let runtime = runtimes[id]
        Task {
            if let runtime, runtime.state.isActive { try? await runtime.stop(saveState: false) }
            release(id)
            states[id] = nil
            errors[id] = nil
            if presented == .machine(id) { presented = nil }
            do { try engine.deleteMachine(id) } catch { message = Format.describe(error) }
            reload()
        }
    }

    private func perform(_ id: UUID, _ action: @escaping @MainActor @Sendable () async throws -> Void) {
        errors[id] = nil
        Task {
            do { try await action() } catch { errors[id] = Format.describe(error) }
        }
    }

    // MARK: App lifecycle

    /// iOS suspends WebKit soon after the app leaves the screen and may end the app later: each running machine is
    /// paused and saved (with background time), and resumes on return; a machine iOS ended resumes from that save.
    func appDidEnterBackground() {
        let active = runtimes.values.filter { $0.state == .running || $0.state == .paused || $0.state == .saving }
        guard !active.isEmpty else { return }
        let time = BackgroundTime(name: "Save running machines")
        Task {
            for runtime in active { await runtime.enterBackground() }
            time.end()
        }
    }

    func appWillEnterForeground() {
        for runtime in runtimes.values {
            Task { await runtime.enterForeground() }
        }
    }

    // MARK: Image catalogue

    func imageState(_ image: MachineImage) -> ImageDownloadState { imageStates[image.id] ?? .notDownloaded }

    func refreshImageStates() {
        catalogue = engine.catalogue()
        for image in catalogue where downloadTasks[image.id] == nil {
            if case .failed? = imageStates[image.id] { continue }
            imageStates[image.id] = engine.isImageReady(image) ? .ready : .notDownloaded
        }
    }

    /// Fetches the manifests of manifest-described images (Z Alpine Desktop), e.g. when the image library opens.
    func refreshCatalogue() {
        guard !isRefreshingCatalogue else { return }
        let needsFetch = catalogue.contains { image in
            if case .available = image.availability { return false }
            return true
        }
        guard needsFetch else { return }
        isRefreshingCatalogue = true
        Task {
            await engine.refreshCatalogue()
            isRefreshingCatalogue = false
            refreshImageStates()
        }
    }

    /// Downloads (resuming a partial download), verifies and unpacks a catalogue image.
    func download(_ image: MachineImage) {
        guard downloadTasks[image.id] == nil else { return }
        let id = image.id
        imageStates[id] = .downloading(ImageProgress(fraction: nil, detail: "Starting", phase: .download))
        let model = self   // lives as long as the app
        downloadTasks[id] = Task {
            do {
                try await model.engine.prepareImage(image) { progress in
                    Task { @MainActor in
                        guard model.downloadTasks[id] != nil else { return }
                        model.imageStates[id] = .downloading(progress)
                    }
                }
                model.imageStates[id] = .ready
            } catch is CancellationError {
                model.imageStates[id] = .notDownloaded
            } catch {
                model.imageStates[id] = Task.isCancelled ? .notDownloaded : .failed(Format.describe(error))
            }
            model.downloadTasks[id] = nil
            // The download resolved the image's manifest (sizes, version) or found it unavailable.
            model.catalogue = model.engine.catalogue()
        }
    }

    func cancelDownload(_ image: MachineImage) {
        downloadTasks[image.id]?.cancel()
    }

    func clearFailure(_ image: MachineImage) {
        if case .failed? = imageStates[image.id] { imageStates[image.id] = .notDownloaded }
    }

    func deleteImage(_ image: MachineImage) {
        do {
            try engine.deleteImage(image)
        } catch {
            message = Format.describe(error)
        }
        imageStates[image.id] = nil
        refreshImageStates()
    }

    func create(from image: MachineImage, name: String, memoryMB: Int) {
        do {
            let summary = try engine.createMachine(name: Self.cleanName(name, fallback: image.name), image: image,
                                                   memoryMB: memoryMB)
            reload()
            justCreated = summary.id
            start(summary.id)
        } catch {
            message = Format.describe(error)
        }
    }

    func create(fromISO url: URL, name: String, memoryMB: Int) {
        do {
            let fallback = url.deletingPathExtension().lastPathComponent
            let summary = try engine.createMachine(name: Self.cleanName(name, fallback: fallback), iso: url,
                                                   memoryMB: memoryMB)
            reload()
            justCreated = summary.id
            start(summary.id)
        } catch {
            message = Format.describe(error)
        }
    }

    private static func cleanName(_ name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    // MARK: ISOs in Documents (Files app ▸ On My iPhone ▸ Z Computer)

    /// `Documents/ISOs`, created on first use.
    static var isoDirectory: URL {
        let documents = (try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil,
                                                      create: true)) ?? FileManager.default.temporaryDirectory
        let dir = documents.appendingPathComponent("ISOs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// ISO files in Documents and Documents/ISOs (users drop them there with the Files app).
    func refreshISOs() {
        let fm = FileManager.default
        let isoDir = Self.isoDirectory
        let documents = isoDir.deletingLastPathComponent()
        var found: [URL] = []
        for dir in [documents, isoDir] {
            let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in names where name.lowercased().hasSuffix(".iso") {
                found.append(dir.appendingPathComponent(name))
            }
        }
        userISOs = found.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Copies an ISO picked in the Files sheet into Documents/ISOs (the emulator reads files inside the app only).
    func importISO(_ picked: URL) {
        isImportingISO = true
        let destination = Self.isoDirectory.appendingPathComponent(picked.lastPathComponent)
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    let accessing = picked.startAccessingSecurityScopedResource()
                    defer { if accessing { picked.stopAccessingSecurityScopedResource() } }
                    let fm = FileManager.default
                    if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                    try fm.copyItem(at: picked, to: destination)
                }.value
            } catch {
                message = "Could not copy \(picked.lastPathComponent): \(Format.describe(error))"
            }
            isImportingISO = false
            refreshISOs()
        }
    }

    func deleteISO(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            message = Format.describe(error)
        }
        refreshISOs()
    }
}

/// Extra time from iOS to finish work after the app left the screen (`beginBackgroundTask`); ended by `end()` or
/// when iOS runs out of patience.
@MainActor
final class BackgroundTime {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
