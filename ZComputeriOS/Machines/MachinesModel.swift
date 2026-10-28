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
    private(set) var errors: [UUID: String] = [:]
    private(set) var listError: String?
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
    @ObservationIgnored private var watchers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var downloadTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var pausedForBackground: Set<UUID> = []

    init(keyStore: KeychainKeyStore, engine: any MachineEngine) {
        self.keyStore = keyStore
        self.engine = engine
        self.demo = MockComputerSurface()
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

    func dismissError(_ id: UUID) { errors[id] = nil }

    /// The runtime of a machine, made on first use. Its screen view is parked in the window right away.
    func runtime(for id: UUID) throws -> any MachineRuntime {
        if let existing = runtimes[id] { return existing }
        let runtime = try engine.makeRuntime(for: id)
        runtimes[id] = runtime
        parking.park(runtime.screenView)
        states[id] = runtime.state
        let updates = runtime.stateStream()
        watchers[id] = Task { [weak self] in
            for await state in updates {
                guard let self else { return }
                self.states[id] = state
                if case .error(let message) = state { self.errors[id] = message }
            }
        }
        return runtime
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

    func stop(_ id: UUID) {
        guard let runtime = runtimes[id] else { return }
        perform(id) { try await runtime.stop() }
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
            if let runtime, runtime.state.isActive { try? await runtime.stop() }
            watchers[id]?.cancel()
            watchers[id] = nil
            if let runtime { parking.evict(runtime.screenView) }
            runtimes[id] = nil
            surfaces[id] = nil
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

    /// iOS suspends WebKit in the background: pause running machines so the guest clock does not jump.
    func appDidEnterBackground() {
        for (id, runtime) in runtimes where runtime.state == .running {
            pausedForBackground.insert(id)
            Task { try? await runtime.pause() }
        }
    }

    func appWillEnterForeground() {
        let ids = pausedForBackground
        pausedForBackground.removeAll()
        for id in ids {
            guard let runtime = runtimes[id] else { continue }
            Task { try? await runtime.resume() }
        }
    }

    // MARK: Image catalogue

    var catalogue: [MachineImage] { engine.catalogue() }

    func imageState(_ image: MachineImage) -> ImageDownloadState { imageStates[image.id] ?? .notDownloaded }

    func refreshImageStates() {
        for image in engine.catalogue() where downloadTasks[image.id] == nil {
            if case .failed? = imageStates[image.id] { continue }
            imageStates[image.id] = engine.isImageReady(image) ? .ready : .notDownloaded
        }
    }

    /// Downloads (resuming a partial download), verifies and unpacks a catalogue image.
    func download(_ image: MachineImage) {
        guard downloadTasks[image.id] == nil else { return }
        let id = image.id
        imageStates[id] = .downloading(ImageProgress(fraction: 0, detail: "Starting"))
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
