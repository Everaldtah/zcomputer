import Foundation
import Observation
import ZCore
import ZVM

/// Which machine the Agent view's runner controls.
enum AgentMachineChoice: Hashable {
    case none
    case demo
    case vm(UUID)

    init(key: String?) {
        switch key {
        case nil, "demo": self = .demo
        case "none": self = .none
        case let key?: self = UUID(uuidString: key).map { .vm($0) } ?? .demo
        }
    }

    var key: String {
        switch self {
        case .none: return "none"
        case .demo: return "demo"
        case .vm(let id): return id.uuidString
        }
    }
}

/// An entry of the Machines list.
enum MachineID: Hashable {
    case demo
    case vm(UUID)
}

/// A long job on a VM (image download, conversion, macOS install).
struct MachineJob: Hashable {
    var title: String
    var fraction: Double?
    var detail: String
}

/// The Machines screen: VMs from ZVM's `VMStore`, their `VMController`s (built on demand), the Demo machine, and the
/// surface the Agent view drives.
@Observable
@MainActor
final class MachinesModel {
    let isSupported: Bool
    let demo: MockComputerSurface
    let store: VMStore?
    let storeError: String?
    let keyStore: KeychainKeyStore

    private(set) var specs: [VMSpec] = []
    private(set) var states: [UUID: VMRunState] = [:]
    private(set) var jobs: [UUID: MachineJob] = [:]
    private(set) var errors: [UUID: String] = [:]
    private(set) var listError: String?
    private(set) var agentChoice: AgentMachineChoice
    var selection: MachineID? = .demo
    /// Bumped when a VM's display view should be rebuilt (new VZVirtualMachine).
    private(set) var displayGeneration = 0

    @ObservationIgnored private var controllers: [UUID: VMController] = [:]
    @ObservationIgnored private var surfaces: [UUID: VMSurface] = [:]
    @ObservationIgnored private var watchers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var jobTasks: [UUID: Task<Void, Never>] = [:]

    init(keyStore: KeychainKeyStore) {
        self.keyStore = keyStore
        self.demo = MockComputerSurface()
        self.isSupported = VMController.isSupported
        do {
            self.store = try VMStore.standard()
            self.storeError = nil
        } catch {
            self.store = nil
            self.storeError = "The VM folder could not be opened: \(Format.describe(error))"
        }
        let saved = AgentMachineChoice(key: UserDefaults.standard.string(forKey: SettingsKey.agentMachine))
        self.agentChoice = VMController.isSupported ? saved : .demo
    }

    // MARK: List

    func reload() {
        guard let store else { return }
        do {
            specs = try store.list().sorted { $0.createdAt < $1.createdAt }
            for spec in specs where states[spec.id] == nil { states[spec.id] = .stopped }
            if case .vm(let id) = agentChoice, !specs.contains(where: { $0.id == id }) { setAgentChoice(.demo) }
        } catch {
            listError = Format.describe(error)
        }
    }

    func spec(_ id: UUID) -> VMSpec? { specs.first { $0.id == id } }

    func state(_ id: UUID) -> VMRunState { states[id] ?? .stopped }

    /// The controller of a VM (loaded from the store on first use; its state is mirrored into `states`).
    func controller(for id: UUID) throws -> VMController {
        if let existing = controllers[id] { return existing }
        guard let store else { throw ZError.vm(storeError ?? "no VM store") }
        let controller = try VMController.load(id: id, store: store, guestAgentDirectory: AppPaths.guestAgentDirectory)
        controllers[id] = controller
        let updates = controller.stateUpdates
        watchers[id] = Task { [weak self] in
            for await state in updates {
                guard let self else { return }
                self.states[id] = state
                if case .error(let message) = state { self.errors[id] = message }
            }
        }
        return controller
    }

    /// The controller only when it already exists (views must not create VMs just by rendering).
    func existingController(for id: UUID) -> VMController? { controllers[id] }

    // MARK: Lifecycle

    func start(_ id: UUID) {
        errors[id] = nil
        Task {
            do {
                let controller = try controller(for: id)
                try controller.buildVirtualMachine()
                displayGeneration += 1
                try await controller.start()
            } catch {
                errors[id] = Format.describe(error)
            }
        }
    }

    func stop(_ id: UUID, force: Bool) {
        guard let controller = controllers[id] else { return }
        Task {
            do {
                if force { try await controller.stop() } else { try controller.requestStop() }
            } catch {
                errors[id] = Format.describe(error)
            }
        }
    }

    func pause(_ id: UUID) {
        guard let controller = controllers[id] else { return }
        Task {
            do { try await controller.pause() } catch { errors[id] = Format.describe(error) }
        }
    }

    func resume(_ id: UUID) {
        guard let controller = controllers[id] else { return }
        Task {
            do { try await controller.resume() } catch { errors[id] = Format.describe(error) }
        }
    }

    /// Stops attaching the installer ISO (after the guest is installed) and saves the spec.
    func finishInstallation(_ id: UUID) {
        do {
            let controller = try controller(for: id)
            try controller.finishInstallation()
            try store?.save(controller.spec)
            reload()
        } catch {
            errors[id] = Format.describe(error)
        }
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let store else { return }
        do {
            _ = try store.rename(id: id, to: trimmed)
            reload()
        } catch {
            errors[id] = Format.describe(error)
        }
    }

    func delete(_ id: UUID) {
        guard let store else { return }
        Task {
            if let controller = controllers[id], controller.state.isActive { try? await controller.stop() }
            jobTasks[id]?.cancel()
            watchers[id]?.cancel()
            controllers[id] = nil
            surfaces[id] = nil
            states[id] = nil
            jobs[id] = nil
            do { try store.delete(id: id) } catch { errors[id] = Format.describe(error) }
            try? keyStore.setSecret(nil, account: KeychainKeyStore.vmPasswordAccount(id))
            if selection == .vm(id) { selection = .demo }
            reload()
        }
    }

    func cancelJob(_ id: UUID) {
        jobTasks[id]?.cancel()
    }

    func dismissError(_ id: UUID) { errors[id] = nil }

    // MARK: Agent surface

    func setAgentChoice(_ choice: AgentMachineChoice) {
        agentChoice = choice
        UserDefaults.standard.set(choice.key, forKey: SettingsKey.agentMachine)
    }

    var agentChoiceKey: String { agentChoice.key }

    /// Name of the machine the agent will control (nil = no machine, chat only).
    var agentMachineName: String? {
        switch agentChoice {
        case .none: return nil
        case .demo: return demo.name
        case .vm(let id): return spec(id)?.name ?? "VM"
        }
    }

    /// The `ComputerSurface` for the agent: the Demo machine, or a running VM's `VMSurface`.
    func agentSurface() throws -> (any ComputerSurface)? {
        switch agentChoice {
        case .none:
            return nil
        case .demo:
            return demo
        case .vm(let id):
            let controller = try controller(for: id)
            guard controller.state.isActive else {
                throw ZError.vm("Start “\(controller.spec.name)” in Machines before giving it to the agent.")
            }
            if let surface = surfaces[id] { return surface }
            let surface = controller.makeSurface(credentials: credentials(for: id))
            surfaces[id] = surface
            return surface
        }
    }

    func credentials(for id: UUID) -> VMSurface.Credentials? {
        guard let stored = keyStore.secret(account: KeychainKeyStore.vmPasswordAccount(id)) else { return nil }
        let parts = stored.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        return VMSurface.Credentials(user: parts[0], password: parts[1].isEmpty ? nil : parts[1])
    }

    func setCredentials(_ credentials: VMSurface.Credentials?, for id: UUID) {
        let value = credentials.map { "\($0.user)\n\($0.password ?? "")" }
        do {
            try keyStore.setSecret(value, account: KeychainKeyStore.vmPasswordAccount(id))
            if let surface = surfaces[id] { Task { await surface.setCredentials(credentials) } }
        } catch {
            errors[id] = Format.describe(error)
        }
    }

    /// Installs `zguest` into a running Linux guest over the serial console (needs the saved login).
    func provisionGuestAgent(_ id: UUID) {
        guard let creds = credentials(for: id) else {
            errors[id] = "Save the guest's login first (user and password) so the serial console can sign in."
            return
        }
        Task {
            do {
                let controller = try controller(for: id)
                jobs[id] = MachineJob(title: "Installing the guest agent", fraction: nil, detail: "over the serial console")
                let result = try await controller.provisionGuestAgent(user: creds.user, password: creds.password)
                jobs[id] = nil
                if result.exitCode != 0 { errors[id] = "Guest agent install exited \(result.exitCode): \(result.stderr)" }
            } catch {
                jobs[id] = nil
                errors[id] = Format.describe(error)
            }
        }
    }

    // MARK: Creating VMs

    /// "Install from ISO": a Linux VM that boots the user's UEFI installer image.
    func createFromISO(_ draft: MachineDraft, iso: URL) throws {
        guard let store else { throw ZError.vm(storeError ?? "no VM store") }
        var spec = draft.makeSpec(guest: .linux)
        spec.install = .iso(iso)
        spec.installBookmark = try FileBookmark.make(for: iso, securityScoped: true, readOnly: true)
        spec.attachInstallMedia = true
        _ = try store.create(spec, createDisk: true)
        finishCreate(spec.id)
    }

    /// "Ready-to-run Linux": download a cloud image, convert it into disk.img and write a cloud-init seed with the
    /// user's login (and the zguest agent install).
    func createFromCloudImage(_ draft: MachineDraft, image: CloudImage, user: String, password: String,
                              desktop: Bool) throws {
        guard let store else { throw ZError.vm(storeError ?? "no VM store") }
        var spec = draft.makeSpec(guest: .linux)
        spec.install = .diskImage(image.url)
        spec.attachInstallMedia = false
        spec.notes = "From \(image.name). Login: \(user)."
        let bundle = try store.create(spec, createDisk: false)
        let id = spec.id
        setCredentials(VMSurface.Credentials(user: user, password: password), for: id)
        let cloudInit = CloudInitConfig(hostname: Self.hostname(for: draft.name), user: user, password: password,
                                        packages: desktop ? CloudInitConfig.desktopPackages : [],
                                        agentBinaryName: "zguest-linux-\(GuestArchitecture.host.debianName)")
        finishCreate(id)
        jobs[id] = MachineJob(title: "Preparing \(image.name)", fraction: 0, detail: "starting download")
        let finalSpec = spec
        let model = self   // the model lives as long as the app
        jobTasks[id] = Task {
            do {
                let cache = try ImagePreparer.defaultCacheDirectory()
                try await ImagePreparer.prepare(image, spec: finalSpec, bundle: bundle, cacheDirectory: cache,
                                                cloudInit: cloudInit) { phase in
                    Task { @MainActor in model.report(phase, for: id) }
                }
                model.jobs[id] = nil
            } catch {
                model.jobs[id] = nil
                model.errors[id] = error is CancellationError ? "Preparation cancelled." : Format.describe(error)
            }
            model.jobTasks[id] = nil
        }
    }

    #if arch(arm64)
    /// macOS guest: download (or use the picked) restore image, prepare the bundle and run `VZMacOSInstaller`.
    func createMacOS(_ draft: MachineDraft, restoreImage: URL?) throws {
        guard let store else { throw ZError.vm(storeError ?? "no VM store") }
        var spec = draft.makeSpec(guest: .macOS)
        spec.install = .macOSRestoreImage(restoreImage)
        if let restoreImage { spec.installBookmark = try FileBookmark.make(for: restoreImage, securityScoped: true, readOnly: true) }
        let bundle = try store.create(spec, createDisk: false)
        let id = spec.id
        let initialSpec = spec
        finishCreate(id)
        jobs[id] = MachineJob(title: "Preparing macOS", fraction: nil, detail: "looking up the restore image")
        let model = self   // the model lives as long as the app
        jobTasks[id] = Task {
            do {
                let imageURL: URL
                if let restoreImage {
                    imageURL = restoreImage
                } else {
                    let remote = try await MacOSInstaller.latestRestoreImageURL()
                    model.jobs[id] = MachineJob(title: "Downloading macOS", fraction: 0, detail: remote.lastPathComponent)
                    try await MacOSInstaller.downloadRestoreImage(from: remote, to: bundle.restoreImageURL) { progress in
                        let fraction = progress.fractionCompleted
                        let detail = Format.bytes(progress.receivedBytes)
                        Task { @MainActor in
                            model.jobs[id] = MachineJob(title: "Downloading macOS", fraction: fraction, detail: detail)
                        }
                    }
                    imageURL = bundle.restoreImageURL
                }
                let accessing = imageURL.startAccessingSecurityScopedResource()
                defer { if accessing { imageURL.stopAccessingSecurityScopedResource() } }
                let info = try await MacOSInstaller.inspect(restoreImage: imageURL)
                var adjusted = MacOSInstaller.adjustedSpec(initialSpec, for: info)
                try MacOSInstaller.prepareBundle(bundle, spec: adjusted, restoreImage: info)
                try store.save(adjusted)
                let controller = try model.controller(for: id)
                try controller.update(spec: adjusted)
                let title = "Installing macOS \(info.operatingSystemVersion)"
                model.jobs[id] = MachineJob(title: title, fraction: 0, detail: "")
                try await MacOSInstaller.install(controller: controller, restoreImage: imageURL) { fraction in
                    Task { @MainActor in
                        model.jobs[id] = MachineJob(title: title, fraction: fraction, detail: "\(Int(fraction * 100))%")
                    }
                }
                adjusted.install = .none
                adjusted.installBookmark = nil
                try controller.update(spec: adjusted)
                try store.save(adjusted)
                model.jobs[id] = nil
                model.reload()
            } catch {
                model.jobs[id] = nil
                model.errors[id] = error is CancellationError ? "Installation cancelled." : Format.describe(error)
            }
            model.jobTasks[id] = nil
        }
    }
    #endif

    /// Inspects a picked ISO and returns a warning when it will probably not boot on this Mac.
    func isoWarning(for url: URL) -> String? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            return try ISOInspector.inspect(url: url).warning(host: .host)
        } catch {
            return "Could not read the image: \(Format.describe(error))"
        }
    }

    private func finishCreate(_ id: UUID) {
        reload()
        selection = .vm(id)
    }

    private func report(_ phase: ImagePreparationPhase, for id: UUID) {
        guard var job = jobs[id] else { return }
        switch phase {
        case .downloading(let progress):
            job.fraction = progress.fractionCompleted
            job.detail = "Downloading: \(Format.bytes(progress.receivedBytes))"
                + (progress.expectedBytes.map { " of \(Format.bytes($0))" } ?? "")
        case .verifying:
            job.fraction = nil
            job.detail = "Verifying the checksum"
        case .converting(let fraction):
            job.fraction = fraction
            job.detail = "Converting to a raw disk"
        case .resizing:
            job.detail = "Growing the disk"
        case .writingSeed:
            job.detail = "Writing the cloud-init seed"
        case .finished:
            job.fraction = 1
            job.detail = "Ready"
        }
        jobs[id] = job
    }

    private static func hostname(for name: String) -> String {
        let allowed = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let host = String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return host.isEmpty ? "zcomputer" : String(host.prefix(40))
    }
}

/// The create-sheet fields (mirrors `VMSpec`).
struct MachineDraft: Hashable {
    var name = "Linux VM"
    var cpuCount = min(4, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
    var memoryGB = 4
    var diskGB = 32
    var displayWidth = 1280
    var displayHeight = 800
    var headless = false
    var rosetta = false
    var audio = true
    var sharedFolders: [URL] = []

    func makeSpec(guest: GuestOS) -> VMSpec {
        var spec = VMSpec(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "VM" : name, guest: guest,
                          cpuCount: cpuCount, memoryBytes: UInt64(memoryGB) << 30, diskBytes: UInt64(diskGB) << 30,
                          display: DisplaySpec(width: displayWidth, height: displayHeight))
        spec.headless = headless
        spec.rosetta = rosetta
        spec.audio = audio
        spec.sharedFolders = sharedFolders.enumerated().map { index, url in
            let tag = index == 0 ? "shared" : "shared\(index + 1)"
            return SharedFolder(hostURL: url, tag: tag, readOnly: false,
                                bookmark: try? FileBookmark.make(for: url, securityScoped: true, readOnly: false))
        }
        return spec
    }
}
