import Foundation
import Observation
import ZCore
import ZVM

/// One image download, shared by every machine that needs the image.
struct ImageDownloadState: Hashable {
    enum Phase: Hashable {
        case downloading
        case paused
        case verifying
        case verified
        case failed(String)
    }

    var phase: Phase
    var receivedBytes: Int64
    var expectedBytes: Int64?
    var bytesPerSecond: Double?
    /// How the checksum was checked ("SHA-512 from SHA512SUMS", ...).
    var checksumNote: String?

    var fraction: Double? {
        guard let expectedBytes, expectedBytes > 0 else { return nil }
        return min(1, Double(receivedBytes) / Double(expectedBytes))
    }

    var isActive: Bool { phase == .downloading || phase == .verifying }
}

/// Where a machine made from the library is on its way to "ready for agents".
enum ProvisionStage: Hashable {
    case waitingForImage
    case preparingDisk(String)
    case booting
    case agentOnline
    case installing(step: Int, total: Int, label: String)
    case ready
    /// Installer ISO / macOS: the rest is done by hand in the VM window.
    case manual(String)
    case failed(String)

    /// Position in the cloud-image pipeline (for the step list).
    var order: Int {
        switch self {
        case .waitingForImage: return 0
        case .preparingDisk: return 1
        case .booting: return 2
        case .agentOnline: return 3
        case .installing: return 4
        case .ready: return 5
        case .manual, .failed: return -1
        }
    }
}

struct ProvisionProgress: Hashable {
    var stage: ProvisionStage
    var templateName: String
    var imageID: String?
    var startedAt: Date
    /// The seed installs a desktop (the panel shows the desktop step).
    var hasDesktop: Bool
    var hint: String?
}

/// The Image Library: curated catalogue (`ZVM.ImageCatalog`), one-click templates (`MachineTemplate`), shared and
/// pausable image downloads into `Application Support/ZComputer/Images`, and the "Get & Boot" pipeline that creates
/// the VM, prepares its disk, boots it and follows first-boot provisioning through the guest agent.
@Observable
@MainActor
final class ImageLibraryModel {
    let machines: MachinesModel
    let catalog: [CatalogImage]
    let catalogError: String?
    let cacheDirectory: URL?
    let cacheError: String?

    private(set) var host: HostProfile
    private(set) var downloads: [String: ImageDownloadState] = [:]
    private(set) var cachedFiles: [CachedImageFile] = []
    private(set) var provisioning: [UUID: ProvisionProgress] = [:]
    var lastError: String? = nil

    @ObservationIgnored private var downloadTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingResume: Set<String> = []
    @ObservationIgnored private var generations: [String: Int] = [:]
    @ObservationIgnored private var speedSamples: [String: SpeedSample] = [:]
    @ObservationIgnored private var watchers: [UUID: Task<Void, Never>] = [:]

    private struct SpeedSample {
        var time: Date
        var bytes: Int64
    }

    init(machines: MachinesModel) {
        self.machines = machines
        self.catalog = ImageCatalog.all
        self.catalogError = ImageCatalog.loadError
        let directory: URL?
        let problem: String?
        do {
            directory = try ImageCache.defaultDirectory()
            problem = nil
        } catch {
            directory = nil
            problem = "The image cache could not be created: \(Format.describe(error))"
        }
        self.cacheDirectory = directory
        self.cacheError = problem
        self.host = HostProfile.current(storage: directory)
    }

    // MARK: Catalogue

    var templates: [MachineTemplate] { MachineTemplate.all }
    var cloudTemplates: [MachineTemplate] { templates.filter { $0.kind == .cloudImage } }
    var otherTemplates: [MachineTemplate] { templates.filter { $0.kind != .cloudImage } }

    /// Catalogue entries this Mac can run.
    func hostImages(_ group: CatalogImage.Group) -> [CatalogImage] {
        ImageCatalog.images(for: host.architecture, group: group, in: catalog)
    }

    func image(for template: MachineTemplate) -> CatalogImage? {
        template.image(for: host.architecture, in: catalog)
    }

    func image(id: String) -> CatalogImage? { ImageCatalog.image(id: id, in: catalog) }

    func fit(_ template: MachineTemplate) -> TemplateFit {
        let cached = image(for: template).map { isVerified($0) } ?? false
        var fit = template.fits(host: host, catalog: catalog, imageCached: cached)
        if machines.store == nil {
            fit.blockers.insert(machines.storeError ?? "The VM folder could not be opened.", at: 0)
        }
        if !machines.isSupported {
            fit.blockers.insert("This Mac cannot run virtual machines (Virtualization.framework is not available).", at: 0)
        }
        return fit
    }

    func refreshHost() { host = HostProfile.current(storage: cacheDirectory) }

    // MARK: Cache

    func isVerified(_ image: CatalogImage) -> Bool {
        guard let cacheDirectory else { return false }
        return ImageCache.isVerified(image, in: cacheDirectory)
    }

    func partialBytes(_ image: CatalogImage) -> Int64? {
        guard let cacheDirectory else { return nil }
        return ImageCache.partialBytes(image, in: cacheDirectory)
    }

    func refreshCache() {
        guard let cacheDirectory else { cachedFiles = []; return }
        cachedFiles = ImageCache.list(in: cacheDirectory, catalog: catalog)
    }

    var cachedBytes: Int64 { cachedFiles.reduce(0) { $0 + $1.bytes } }

    func deleteCachedFile(_ file: CachedImageFile) {
        guard let cacheDirectory else { return }
        if let id = file.imageID, downloadTasks[id] != nil {
            lastError = "Pause the download and wait for it to stop before deleting it."
            return
        }
        do {
            try ImageCache.delete(fileName: file.fileName, in: cacheDirectory)
            if let id = file.imageID { downloads[id] = nil }
        } catch {
            lastError = Format.describe(error)
        }
        refreshCache()
        refreshHost()
    }

    // MARK: Downloads

    /// Starts (or resumes) the download of `image` into the cache, then verifies its checksum.
    func startDownload(_ image: CatalogImage) {
        guard let cacheDirectory else {
            downloads[image.id] = ImageDownloadState(phase: .failed(cacheError ?? "No image cache."), receivedBytes: 0)
            return
        }
        let id = image.id
        if downloadTasks[id] != nil {
            // The paused task is still winding down: resume as soon as it has.
            if downloads[id]?.phase == .paused {
                pendingResume.insert(id)
                downloads[id]?.phase = .downloading
            }
            return
        }
        let generation = (generations[id] ?? 0) + 1
        generations[id] = generation
        let resumed = ImageCache.partialBytes(image, in: cacheDirectory) ?? 0
        let previousNote = downloads[id]?.checksumNote
        downloads[id] = ImageDownloadState(phase: .downloading, receivedBytes: resumed, expectedBytes: image.sizeBytes,
                                           bytesPerSecond: nil, checksumNote: previousNote)
        speedSamples[id] = nil
        let model = self   // the model lives as long as the app
        downloadTasks[id] = Task {
            do {
                let fetched = try await ImagePreparer.download(image, cacheDirectory: cacheDirectory, progress: { phase in
                    Task { @MainActor in model.report(phase, imageID: id, generation: generation) }
                })
                model.finishDownload(id, generation: generation, result: .success(fetched))
            } catch {
                model.finishDownload(id, generation: generation, result: .failure(error))
            }
        }
    }

    func pauseDownload(_ id: String) {
        guard let task = downloadTasks[id], downloads[id]?.phase == .downloading else { return }
        pendingResume.remove(id)
        downloads[id]?.phase = .paused
        downloads[id]?.bytesPerSecond = nil
        task.cancel()   // the partial file stays; Downloader resumes it with Range + If-Range
    }

    func resumeDownload(_ id: String) {
        guard let image = self.image(id: id) else { return }
        startDownload(image)
    }

    private func report(_ phase: ImagePreparationPhase, imageID: String, generation: Int) {
        guard generations[imageID] == generation, downloadTasks[imageID] != nil, var state = downloads[imageID],
              state.isActive else { return }
        switch phase {
        case .downloading(let progress):
            state.receivedBytes = progress.receivedBytes
            if let expected = progress.expectedBytes { state.expectedBytes = expected }
            state.bytesPerSecond = speed(for: imageID, bytes: progress.receivedBytes, previous: state.bytesPerSecond)
        case .verifying:
            state.phase = .verifying
            state.bytesPerSecond = nil
        case .verified(let expectation):
            state.checksumNote = expectation.summary
        case .converting, .resizing, .writingSeed, .finished:
            break
        }
        downloads[imageID] = state
    }

    /// Smoothed download speed (bytes/s) from samples at least half a second apart.
    private func speed(for id: String, bytes: Int64, previous: Double?) -> Double? {
        let now = Date()
        guard let last = speedSamples[id] else {
            speedSamples[id] = SpeedSample(time: now, bytes: bytes)
            return previous
        }
        let elapsed = now.timeIntervalSince(last.time)
        guard elapsed >= 0.5 else { return previous }
        speedSamples[id] = SpeedSample(time: now, bytes: bytes)
        let instant = max(0, Double(bytes - last.bytes) / elapsed)
        return previous.map { $0 * 0.7 + instant * 0.3 } ?? instant
    }

    private func finishDownload(_ id: String, generation: Int, result: Result<FetchedImage, any Error>) {
        guard generations[id] == generation else { return }
        downloadTasks[id] = nil
        speedSamples[id] = nil
        switch result {
        case .success(let fetched):
            pendingResume.remove(id)
            var state = downloads[id] ?? ImageDownloadState(phase: .verified, receivedBytes: 0)
            state.phase = .verified
            state.bytesPerSecond = nil
            if let size = try? VMStore.fileSize(fetched.url) {
                state.receivedBytes = Int64(size)
                state.expectedBytes = Int64(size)
            }
            if let checksum = fetched.checksum { state.checksumNote = checksum.summary }
            if state.checksumNote == nil { state.checksumNote = "Verified when it was downloaded" }
            downloads[id] = state
        case .failure(let error):
            if pendingResume.remove(id) != nil, let image = self.image(id: id) {
                startDownload(image)
            } else if Self.isCancellation(error) || downloads[id]?.phase == .paused {
                downloads[id]?.phase = .paused
                downloads[id]?.bytesPerSecond = nil
            } else {
                downloads[id]?.phase = .failed(Format.describe(error))
                downloads[id]?.bytesPerSecond = nil
            }
        }
        refreshCache()
        refreshHost()
    }

    nonisolated static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }

    /// "1.2 GB of 4.1 GB · 12 MB/s · 4 min left".
    func progressText(_ state: ImageDownloadState) -> String {
        var text = Format.bytes(state.receivedBytes)
        if let expected = state.expectedBytes { text += " of " + Format.bytes(expected) }
        if let speed = state.bytesPerSecond, speed > 0 {
            text += " · " + Format.bytes(Int64(speed)) + "/s"
            if let expected = state.expectedBytes, expected > state.receivedBytes {
                let seconds = Double(expected - state.receivedBytes) / speed
                text += " · " + Self.duration(seconds) + " left"
            }
        }
        return text
    }

    nonisolated static func duration(_ seconds: Double) -> String {
        if seconds < 90 { return "\(max(1, Int(seconds.rounded()))) s" }
        if seconds < 5400 { return "\(Int((seconds / 60).rounded())) min" }
        return String(format: "%.1f h", seconds / 3600)
    }

    // MARK: Get & Boot

    /// One click: download + verify the template's image, create the VM, prepare the disk, boot it and follow
    /// provisioning until the machine is ready for agents (cloud images), or boot the installer (ISOs), or install
    /// macOS.
    func getAndBoot(_ template: MachineTemplate) {
        lastError = nil
        let check = self.fit(template)
        guard check.canCreate else {
            lastError = check.blockers.first
            return
        }
        do {
            let name = machines.uniqueName(template.name)
            switch template.kind {
            case .cloudImage:
                guard let image = self.image(for: template) else { throw ZError.notFound("an image for \(template.name)") }
                try createCloudMachine(spec: template.makeSpec(name: name, host: host), image: image, user: "z",
                                       password: Self.makePassword(), desktop: template.desktop, dev: template.dev,
                                       templateName: template.name)
            case .installerISO:
                guard let image = self.image(for: template) else { throw ZError.notFound("an image for \(template.name)") }
                try createISOMachine(spec: template.makeSpec(name: name, host: host), image: image,
                                     templateName: template.name, boot: true)
            case .macOS:
                try createMacOSMachine(template, name: name)
            }
            machines.tab = .machines
        } catch {
            lastError = Format.describe(error)
        }
    }

    /// A cloud-image VM: seed with the presets, prepare the disk once the image is verified, boot, watch.
    @discardableResult
    func createCloudMachine(spec initial: VMSpec, image: CatalogImage, user: String, password: String,
                            desktop: DesktopPreset, dev: DevPreset, templateName: String) throws -> UUID {
        guard let store = machines.store else { throw ZError.vm(machines.storeError ?? "no VM store") }
        guard image.arch == host.architecture else {
            throw ZError.unsupported("\(image.name) is built for \(image.arch.rawValue); this Mac runs \(host.architecture.rawValue) guests")
        }
        let config = try CloudInitConfig.forImage(image, hostname: MachinesModel.hostname(for: initial.name), user: user,
                                                  password: password, desktop: desktop, dev: dev, display: initial.display)
        var spec = initial
        spec.install = .diskImage(image.url)
        spec.attachInstallMedia = false
        spec.notes = "\(templateName) from \(image.name). Login: \(user) (the password is in the Keychain: Guest login below)."
        let bundle = try store.create(spec, createDisk: false)
        let id = spec.id
        machines.setCredentials(VMSurface.Credentials(user: user, password: password), for: id)
        machines.didCreate(id)
        provisioning[id] = ProvisionProgress(stage: .waitingForImage, templateName: templateName, imageID: image.id,
                                             startedAt: Date(), hasDesktop: desktop != .none, hint: nil)
        machines.setJob(MachineJob(title: "Getting \(image.name)", fraction: nil, detail: "Starting the download"), for: id)
        let finalSpec = spec
        let model = self   // the model lives as long as the app
        let task = Task {
            do {
                try await model.waitForImage(image, machine: id)
                guard let cache = model.cacheDirectory else { throw ZError.vm(model.cacheError ?? "no image cache") }
                model.setStage(.preparingDisk("Converting the image to a disk"), for: id)
                try await ImagePreparer.prepare(image, spec: finalSpec, bundle: bundle, cacheDirectory: cache,
                                                cloudInit: config) { phase in
                    Task { @MainActor in model.reportPreparation(phase, machine: id) }
                }
                model.machines.setJob(nil, for: id)
                model.setStage(.booting, for: id)
                try await model.machines.startNow(id)
                model.watchProvisioning(id)
            } catch {
                model.fail(id, error)
            }
            model.machines.setJobTask(nil, for: id)
        }
        machines.setJobTask(task, for: id)
        return id
    }

    /// An installer-ISO VM: the ISO is downloaded into the cache and attached as a USB stick.
    @discardableResult
    func createISOMachine(spec initial: VMSpec, image: CatalogImage, templateName: String, boot: Bool) throws -> UUID {
        guard let store = machines.store else { throw ZError.vm(machines.storeError ?? "no VM store") }
        guard let cache = cacheDirectory else { throw ZError.vm(cacheError ?? "no image cache") }
        var spec = initial
        spec.install = .iso(ImageCache.fileURL(for: image, in: cache))
        spec.installBookmark = nil
        spec.attachInstallMedia = true
        spec.notes = "\(templateName): \(image.name). Install in the window, then More ▸ Installation finished."
        _ = try store.create(spec, createDisk: true)
        let id = spec.id
        machines.didCreate(id)
        provisioning[id] = ProvisionProgress(stage: .waitingForImage, templateName: templateName, imageID: image.id,
                                             startedAt: Date(), hasDesktop: false, hint: nil)
        machines.setJob(MachineJob(title: "Getting \(image.name)", fraction: nil, detail: "Starting the download"), for: id)
        let model = self   // the model lives as long as the app
        let task = Task {
            do {
                try await model.waitForImage(image, machine: id)
                model.machines.setJob(nil, for: id)
                if boot {
                    model.setStage(.booting, for: id)
                    try await model.machines.startNow(id)
                    model.setStage(.manual(Self.installerInstructions(image)), for: id)
                } else {
                    model.setStage(.manual("The installer is downloaded and verified: press Start to boot it. "
                                           + Self.installerInstructions(image)), for: id)
                }
            } catch {
                model.fail(id, error)
            }
            model.machines.setJobTask(nil, for: id)
        }
        machines.setJobTask(task, for: id)
        return id
    }

    private func createMacOSMachine(_ template: MachineTemplate, name: String) throws {
        #if arch(arm64)
        let spec = template.makeSpec(name: name, host: host)
        var draft = MachineDraft()
        draft.name = name
        draft.cpuCount = spec.cpuCount
        draft.memoryGB = Int(spec.memoryBytes >> 30)
        draft.diskGB = Int(spec.diskBytes >> 30)
        draft.displayWidth = spec.display.width
        draft.displayHeight = spec.display.height
        let id = try machines.createMacOS(draft, restoreImage: nil)
        provisioning[id] = ProvisionProgress(stage: .waitingForImage, templateName: template.name, imageID: nil,
                                             startedAt: Date(), hasDesktop: true, hint: "Downloading macOS from Apple")
        let model = self   // the model lives as long as the app
        watchers[id] = Task {
            // MachinesModel.createMacOS runs the download + install as the machine's job.
            while model.machines.jobs[id] != nil {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            if let error = model.machines.errors[id] {
                model.setStage(.failed(error), for: id)
                return
            }
            do {
                model.setStage(.booting, for: id)
                try await model.machines.startNow(id)
                model.setStage(.manual("Finish macOS Setup Assistant in the window. The guest agent is Linux-only: "
                                       + "the agent drives macOS through the screen."), for: id)
            } catch {
                model.fail(id, error)
            }
        }
        #else
        throw ZError.unsupported("macOS guests need a Mac with Apple silicon.")
        #endif
    }

    /// Waits until `image` is downloaded and verified, mirroring the shared download into the machine's job.
    private func waitForImage(_ image: CatalogImage, machine id: UUID) async throws {
        if isVerified(image) { return }
        switch downloads[image.id]?.phase {
        case .downloading?, .verifying?: break
        default: startDownload(image)
        }
        while true {
            try await Task.sleep(for: .milliseconds(500))
            guard let state = downloads[image.id] else {
                if isVerified(image) { return }
                throw ZError.network("The download of \(image.name) was removed.")
            }
            switch state.phase {
            case .verified:
                return
            case .failed(let message):
                throw ZError.network(message)
            case .downloading:
                machines.setJob(MachineJob(title: "Downloading \(image.name)", fraction: state.fraction,
                                           detail: progressText(state)), for: id)
            case .paused:
                machines.setJob(MachineJob(title: "Download paused: \(image.name)", fraction: state.fraction,
                                           detail: progressText(state) + " · resume it below or in the Library"), for: id)
            case .verifying:
                machines.setJob(MachineJob(title: "Verifying \(image.name)", fraction: nil,
                                           detail: "\(image.checksum.algo.displayName) checksum"), for: id)
            }
        }
    }

    private func reportPreparation(_ phase: ImagePreparationPhase, machine id: UUID) {
        guard machines.jobs[id] != nil else { return }   // late report after the job ended
        let detail: String
        var fraction: Double?
        switch phase {
        case .converting(let f):
            detail = "Converting the image to a raw disk"
            fraction = f
        case .resizing: detail = "Growing the disk"
        case .writingSeed: detail = "Writing the cloud-init seed"
        case .finished:
            detail = "Disk ready"
            fraction = 1
        case .downloading, .verifying, .verified: return
        }
        machines.setJob(MachineJob(title: "Preparing the disk", fraction: fraction, detail: detail), for: id)
        setStage(.preparingDisk(detail), for: id)
    }

    private func fail(_ id: UUID, _ error: any Error) {
        machines.setJob(nil, for: id)
        let message = Self.isCancellation(error) ? "Cancelled." : Format.describe(error)
        machines.setError(message, for: id)
        setStage(.failed(message), for: id)
    }

    // MARK: Provisioning

    private func setStage(_ stage: ProvisionStage, for id: UUID) {
        guard var progress = provisioning[id] else { return }
        if progress.stage != stage { progress.hint = nil }
        progress.stage = stage
        provisioning[id] = progress
    }

    private func setHint(_ hint: String, for id: UUID) {
        provisioning[id]?.hint = hint
    }

    func dismissProvisioning(_ id: UUID) {
        watchers[id]?.cancel()
        watchers[id] = nil
        provisioning[id] = nil
    }

    /// Polls the guest agent (ping, then `ProvisionStatus.path`) every 3 s until the seed reports `done`.
    func watchProvisioning(_ id: UUID) {
        watchers[id]?.cancel()
        let model = self   // the model lives as long as the app
        watchers[id] = Task { await model.followProvisioning(id) }
    }

    private func followProvisioning(_ id: UUID) async {
        let started = Date()
        var agentSeen = false
        while !Task.isCancelled {
            guard machines.spec(id) != nil else {
                provisioning[id] = nil
                return
            }
            guard let controller = machines.existingController(for: id), controller.state.isActive else {
                setStage(.failed("The machine stopped before it was ready. Start it again and choose Check again."), for: id)
                return
            }
            let agent = controller.guestAgent
            if (try? await agent.ping(timeout: 2)) != nil {
                if !agentSeen {
                    agentSeen = true
                    setStage(.agentOnline, for: id)
                }
                if let chunk = try? await agent.readFile(path: ProvisionStatus.path, maxBytes: 4096),
                   let status = ProvisionStatus.parse(String(decoding: chunk.data, as: UTF8.self)) {
                    if status.isDone {
                        markReady(id)
                        return
                    }
                    if status.isFailed {
                        let detail = status.detail.map { ": \($0)" } ?? ""
                        setStage(.failed("\(status.label) failed\(detail). The guest log is \(ProvisionStatus.logPath)."), for: id)
                        return
                    }
                    setStage(.installing(step: status.step, total: status.total, label: status.label), for: id)
                }
            } else if !agentSeen, Date().timeIntervalSince(started) > 600 {
                setHint("The guest agent has not answered for 10 minutes. Look at the screen, or open the Terminal "
                        + "(serial console) to see what the guest is doing.", for: id)
            }
            if Date().timeIntervalSince(started) > 3 * 3600 {
                setStage(.failed("Provisioning did not finish within 3 hours."), for: id)
                return
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func markReady(_ id: UUID) {
        setStage(.ready, for: id)
        machines.setAgentChoice(.vm(id))
    }

    // MARK: Helpers

    nonisolated static func makePassword() -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<20).compactMap { _ in alphabet.randomElement() })
    }

    nonisolated static func installerInstructions(_ image: CatalogImage) -> String {
        var text = "Install \(image.name) in the window. When it is done, shut the VM down and choose More ▸ "
            + "Installation finished: detach the ISO."
        if let desktop = image.desktop, desktop.isWayland {
            text += " \(desktop.displayName) is the default: the agent needs an X11 session."
        }
        return text
    }
}
