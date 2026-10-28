#if canImport(ZEmu)
import Foundation
import UIKit
import ZCore
import ZEmu

/// The machine layer on ZEmu: 32-bit x86 PCs emulated by v86 in a WKWebView (docs/EMU.md).
///
/// * Machines live in `EmuStore.standard()` (Application Support/ZComputer/Emu, excluded from backup).
/// * The catalogue is ZEmu's `images-x86.json`. Z Alpine Desktop's files come from the `manifest.json` of the
///   images-v1 release; the image library fetches it when it opens (`refreshCatalogue`), and a download fetches it
///   first when needed. Until then the image shows "checking", and "unavailable" when the fetch fails.
/// * Downloads, sha256 checks and `.xz` unpacking are `EmuImagePreparer`'s (resumable).
/// * Guest networking (ZEmu `.fetch`) follows the experimental Settings switch, off by default.
@MainActor
final class ZEmuMachineEngine: MachineEngine {
    let engineName: String
    let unavailableReason: String?
    let memoryLimits = MachineMemoryLimits(recommendedOnPhoneMB: EmuSpec.recommendedMaxMemoryMBOnPhone,
                                           maxOnPhoneMB: EmuSpec.maxMemoryMBOnPhone, maxMB: EmuSpec.maxMemoryMB)
    private let store: EmuStore?
    private let preparer: EmuImagePreparer?
    private let notificationCenter: NotificationCenter
    /// The bundled catalogue; a manifest image is replaced by its resolved form once its manifest is fetched.
    private var images: [EmuImage]
    private var resolution: [String: MachineImageAvailability] = [:]
    private var refreshing = false

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        let commit = EmuResources.v86Commit.map { " " + String($0.prefix(7)) } ?? ""
        engineName = "x86 emulator (v86\(commit) in WebKit)"
        images = (try? EmuImageCatalog.bundled().images) ?? []
        do {
            let store = try EmuStore.standard()
            self.store = store
            preparer = EmuImagePreparer(store: store)
            unavailableReason = nil
        } catch {
            store = nil
            preparer = nil
            unavailableReason = "The machine library could not be created: \(Format.describe(error))"
        }
    }

    // MARK: Machines

    func listMachines() throws -> [MachineSummary] {
        guard let store else { return [] }
        return try store.list().map { summary($0, store: store) }
    }

    func validate(memoryMB: Int, isPhone: Bool) -> [String] {
        EmuSpec(name: "check", memoryMB: memoryMB, boot: .iso(URL(fileURLWithPath: "/dev/null"))).validate(isPhone: isPhone)
    }

    func createMachine(name: String, image: MachineImage, memoryMB: Int) throws -> MachineSummary {
        let (store, preparer) = try requireStore()
        guard let emu = emuImage(image.id) else { throw ZError.notFound(image.name) }
        guard let prepared = preparer.preparedImage(for: emu) else {
            throw ZError.notFound("\(emu.name) is not downloaded yet")
        }
        // Instant start: makeSpec uses the memory size the saved state was taken with (512 MB), whatever was asked.
        var spec = try EmuImageCatalog.makeSpec(for: emu, prepared: prepared, name: name, memoryMB: memoryMB)
        spec.network = Self.network()
        try check(spec)
        let created = try store.create(spec)
        return summary(created, store: store)
    }

    func createMachine(name: String, iso: URL, memoryMB: Int) throws -> MachineSummary {
        let (store, _) = try requireStore()
        // Known ISOs (by file name) get the catalogue's boot keystrokes (console=ttyS0) and serial login.
        let known = knownImage(forISO: iso.lastPathComponent)
        var spec = EmuSpec(name: name, memoryMB: memoryMB, boot: .iso(iso), enable9p: known?.enable9p ?? true,
                           serial: true, network: Self.network(), nic: known?.nic ?? .virtio, acpi: known?.acpi ?? false,
                           serialLogin: known?.serialLogin, bootAssist: known?.bootAssist)
        try check(spec)
        let local = try importISO(iso, into: store)
        spec.boot = .iso(local)
        let created = try store.create(spec)
        return summary(created, store: store)
    }

    func deleteMachine(_ id: UUID) throws {
        guard let store else { return }
        let spec = try? store.load(id: id)
        try store.delete(id: id)
        // An ISO imported for this machine goes too, unless another machine boots it.
        guard let iso = spec?.cdromImage, Self.isInside(iso, store.isoDirectory) else { return }
        let others = (try? store.list()) ?? []
        let used = others.contains { other in other.cdromImage.map { Self.samePath($0, iso) } ?? false }
        if !used { try? FileManager.default.removeItem(at: iso) }
    }

    func makeRuntime(for id: UUID) throws -> any MachineRuntime {
        let (store, _) = try requireStore()
        var spec = try store.load(id: id)
        let network = MachineSettings.guestNetworkEnabled
        spec.network = network ? .fetch : .none
        return ZEmuMachineRuntime(spec: spec, store: store, guestNetwork: network, notificationCenter: notificationCenter)
    }

    // MARK: Catalogue

    func catalogue() -> [MachineImage] { images.map { machineImage($0) } }

    func refreshCatalogue() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        for image in images where !image.isResolved && image.manifestURL != nil {
            resolution[image.id] = .resolving
            do {
                let resolved = try await EmuImageCatalog.resolve(image)
                replace(resolved)
                resolution[image.id] = nil
            } catch {
                resolution[image.id] = .unavailable(Self.unavailableMessage(error))
            }
        }
    }

    func isImageReady(_ image: MachineImage) -> Bool {
        guard let preparer, let emu = emuImage(image.id) else { return false }
        return preparer.isReady(emu)
    }

    func prepareImage(_ image: MachineImage, progress: @escaping @Sendable (ImageProgress) -> Void) async throws {
        let (_, preparer) = try requireStore()
        guard var emu = emuImage(image.id) else { throw ZError.notFound(image.name) }
        if !emu.isResolved, emu.manifestURL != nil {
            progress(ImageProgress(fraction: nil, detail: "Reading the image manifest", phase: .manifest))
            do {
                emu = try await EmuImageCatalog.resolve(emu)
            } catch {
                resolution[emu.id] = .unavailable(Self.unavailableMessage(error))
                throw error
            }
            replace(emu)
            resolution[emu.id] = nil
        }
        try await preparer.prepare(emu) { update in progress(Self.progress(update)) }
    }

    func deleteImage(_ image: MachineImage) throws {
        guard let preparer, let emu = emuImage(image.id) else { return }
        try preparer.delete(emu)
    }

    // MARK: Mapping

    private func machineImage(_ image: EmuImage) -> MachineImage {
        MachineImage(id: image.id, name: image.name, summary: image.summary, kind: Self.kind(image.kind),
                     downloadBytes: image.downloadBytes, recommended: image.recommended,
                     defaultMemoryMB: image.defaultMemoryMB,
                     fixedMemoryMB: image.kind == .instantStart ? image.defaultMemoryMB : nil,
                     version: image.version, availability: availability(of: image))
    }

    private func availability(of image: EmuImage) -> MachineImageAvailability {
        guard !image.isResolved, image.manifestURL != nil else { return .available }
        return resolution[image.id] ?? .resolving
    }

    private func summary(_ spec: EmuSpec, store: EmuStore) -> MachineSummary {
        MachineSummary(id: spec.id, name: spec.name, memoryMB: spec.memoryMB, screenWidth: spec.screen.width,
                       screenHeight: spec.screen.height, bootDescription: bootDescription(spec),
                       hasSavedState: FileManager.default.fileExists(atPath: store.autosaveStateURL(spec.id).path))
    }

    private func bootDescription(_ spec: EmuSpec) -> String {
        let imageName = spec.imageID.flatMap { id in images.first { $0.id == id }?.name }
        switch spec.boot {
        case .state: return (imageName ?? "Saved state") + ", instant start"
        case .iso(let url): return imageName ?? url.lastPathComponent
        case .disk(let url): return imageName ?? url.lastPathComponent
        }
    }

    nonisolated static func kind(_ kind: EmuImage.Kind) -> MachineImageKind {
        switch kind {
        case .instantStart: return .instantStart
        case .iso: return .iso
        case .disk: return .disk
        }
    }

    /// ZEmu's preparation phases as the image library shows them: download → verify → unpack → ready.
    nonisolated static func progress(_ p: EmuPrepareProgress) -> ImageProgress {
        let phase: ImagePhase
        switch p.phase {
        case .manifest: phase = .manifest
        case .download: phase = .download
        case .verify: phase = .verify
        case .decompress: phase = .unpack
        case .done: phase = .ready
        }
        return ImageProgress(fraction: p.fraction, detail: p.detail, phase: phase)
    }

    nonisolated static func unavailableMessage(_ error: any Error) -> String {
        if let zError = error as? ZError, case .http(let status, _) = zError, status == 404 {
            return "Not available yet: the image release is not published."
        }
        if error is URLError {
            return "Could not reach GitHub to check the image (offline?). \(error.localizedDescription)"
        }
        return "Could not read the image manifest: \(Format.describe(error))"
    }

    // MARK: Helpers

    private func requireStore() throws -> (EmuStore, EmuImagePreparer) {
        guard let store, let preparer else { throw ZError.unsupported(unavailableReason ?? "No machine library") }
        return (store, preparer)
    }

    private func emuImage(_ id: String) -> EmuImage? { images.first { $0.id == id } }

    private func replace(_ image: EmuImage) {
        if let index = images.firstIndex(where: { $0.id == image.id }) { images[index] = image }
    }

    private func check(_ spec: EmuSpec) throws {
        let problems = spec.validate(isPhone: UIDevice.current.userInterfaceIdiom == .phone)
        guard problems.isEmpty else { throw ZError.invalidArgument(problems.joined(separator: " ")) }
    }

    private static func network() -> EmuNetwork { MachineSettings.guestNetworkEnabled ? .fetch : .none }

    /// The catalogue image a user's ISO is a copy of (its file name), or the family it belongs to.
    private func knownImage(forISO fileName: String) -> EmuImage? {
        let name = fileName.lowercased()
        if let exact = images.first(where: { image in image.files.contains { $0.name.lowercased() == name } }) {
            return exact
        }
        let families: [(prefix: String, imageID: String)] = [
            ("alpine-virt-", "alpine-virt-x86"), ("alpine-standard-", "alpine-standard-x86"),
            ("alpine-extended-", "alpine-standard-x86"), ("tinycore-", "tinycore-x86"), ("core-", "tinycore-core-x86"),
            ("debian-", "debian-12-i386-netinst"),
        ]
        guard let family = families.first(where: { name.hasPrefix($0.prefix) }) else { return nil }
        return emuImage(family.imageID)
    }

    /// Puts an ISO into the store's ISOs folder: a hard link when possible (no extra space on the phone, and the
    /// machine keeps working when the copy in Files is deleted), else a copy (`EmuStore.importISO`).
    private func importISO(_ source: URL, into store: EmuStore) throws -> URL {
        if Self.isInside(source, store.isoDirectory) { return source }
        let fm = FileManager.default
        try fm.createDirectory(at: store.isoDirectory, withIntermediateDirectories: true)
        let target = Self.unusedURL(in: store.isoDirectory, name: source.lastPathComponent)
        do {
            try fm.linkItem(at: source, to: target)
            return target
        } catch {
            return try store.importISO(from: source)
        }
    }

    nonisolated static func unusedURL(in directory: URL, name: String) -> URL {
        let fm = FileManager.default
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var candidate = directory.appendingPathComponent(name)
        var n = 1
        while fm.fileExists(atPath: candidate.path) {
            n += 1
            candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)")
        }
        return candidate
    }

    nonisolated static func isInside(_ url: URL, _ directory: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/")
    }

    nonisolated static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path == b.standardizedFileURL.path
    }
}
#endif
