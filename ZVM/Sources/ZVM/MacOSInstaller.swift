import Foundation
@preconcurrency import Virtualization
import ZCore

#if arch(arm64)

/// What a macOS restore image (IPSW) needs, extracted as plain values.
public struct RestoreImageInfo: Sendable, Hashable {
    public var url: URL
    public var buildVersion: String
    public var operatingSystemVersion: String
    public var hardwareModelData: Data
    public var minimumCPUCount: Int
    public var minimumMemoryBytes: UInt64
    /// The image and its most featureful configuration can run on this Mac.
    public var isSupported: Bool
}

/// macOS guests on Apple silicon (docs/research/virtualization.md §3 and brief (c)):
/// 1. `latestRestoreImageURL()` (or a user-picked `.ipsw`) → `downloadRestoreImage` (resumable),
/// 2. `inspect(restoreImage:)` → `prepareBundle` (sparse disk, hardware model, machine id, auxiliary storage),
/// 3. `install(controller:restoreImage:progress:)` runs `VZMacOSInstaller`.
/// At most two macOS VMs can run at once (licence limit, VZError code 6). Setup Assistant is not automated here;
/// `VZMacGuestProvisioningOptions` needs the macOS 27 SDK (not available on the CI image).
@MainActor
public enum MacOSInstaller {
    /// URL of the newest restore image this Mac supports (asks Apple's catalogue; network).
    public static func latestRestoreImageURL() async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, any Error>) in
            VZMacOSRestoreImage.fetchLatestSupported { @Sendable (result: Result<VZMacOSRestoreImage, any Error>) in
                switch result {
                case .success(let image): cont.resume(returning: image.url)
                case .failure(let error): cont.resume(throwing: error)
                }
            }
        }
    }

    /// Downloads a restore image (several GB) into the bundle with resume support.
    public static func downloadRestoreImage(from url: URL, to destination: URL,
                                            progress: (@Sendable (DownloadProgress) -> Void)? = nil) async throws {
        try await Downloader.download(from: url, to: destination, sparse: false, timeout: 120, progress: progress)
    }

    /// Reads a local `.ipsw`.
    public static func inspect(restoreImage url: URL) async throws -> RestoreImageInfo {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RestoreImageInfo, any Error>) in
            VZMacOSRestoreImage.load(from: url) { @Sendable (result: Result<VZMacOSRestoreImage, any Error>) in
                switch result {
                case .failure(let error):
                    cont.resume(throwing: error)
                case .success(let image):
                    guard let requirements = image.mostFeaturefulSupportedConfiguration else {
                        cont.resume(throwing: ZError.unsupported("this macOS restore image cannot run on this Mac"))
                        return
                    }
                    let v = image.operatingSystemVersion
                    let info = RestoreImageInfo(
                        url: url,
                        buildVersion: image.buildVersion,
                        operatingSystemVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
                        hardwareModelData: requirements.hardwareModel.dataRepresentation,
                        minimumCPUCount: requirements.minimumSupportedCPUCount,
                        minimumMemoryBytes: requirements.minimumSupportedMemorySize,
                        isSupported: image.isSupported && requirements.hardwareModel.isSupported)
                    cont.resume(returning: info)
                }
            }
        }
    }

    /// Raises CPU / memory to the image's minimums (and at least 4 CPUs / 8 GiB when the host allows).
    public static func adjustedSpec(_ spec: VMSpec, for info: RestoreImageInfo) -> VMSpec {
        var s = spec
        s.guest = .macOS
        s.cpuCount = max(s.cpuCount, info.minimumCPUCount, min(4, ProcessInfo.processInfo.activeProcessorCount))
        s.memoryBytes = max(s.memoryBytes, info.minimumMemoryBytes)
        return s
    }

    /// Creates the per-VM identity for a fresh install: sparse disk, `hardware-model`, `machine-id`, `aux`.
    /// Every clone needs its own machine id and auxiliary storage.
    public static func prepareBundle(_ bundle: VMBundle, spec: VMSpec, restoreImage info: RestoreImageInfo) throws {
        guard info.isSupported, let model = VZMacHardwareModel(dataRepresentation: info.hardwareModelData), model.isSupported else {
            throw ZError.unsupported("macOS \(info.operatingSystemVersion) (\(info.buildVersion)) is not supported on this Mac")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: bundle.root, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: bundle.diskURL.path) {
            try VMStore.createSparseDisk(at: bundle.diskURL, bytes: spec.diskBytes)
        }
        try info.hardwareModelData.write(to: bundle.hardwareModelURL, options: .atomic)
        try VZMacMachineIdentifier().dataRepresentation.write(to: bundle.machineIdentifierURL, options: .atomic)
        _ = try VZMacAuxiliaryStorage(creatingStorageAt: bundle.auxiliaryStorageURL, hardwareModel: model, options: [.allowOverwrite])
    }

    /// Installs macOS from `restoreImage` into the controller's (stopped, prepared) VM. `progress` gets 0…1.
    public static func install(controller: VMController, restoreImage: URL,
                               progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let vm = try controller.virtualMachineForInstallation()
        let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: restoreImage)
        let outcome = Locked<Result<Void, any Error>?>(nil)
        controller.noteInstallation(running: true)
        installer.install(completionHandler: VZCompletion.recorder(outcome))
        while true {
            if let result = outcome.get() {
                controller.noteInstallation(running: false)
                switch result {
                case .success:
                    progress?(1)
                    return
                case .failure(let error):
                    throw ZError.vm("macOS installation failed: \(VMController.describe(error))")
                }
            }
            progress?(installer.progress.fractionCompleted)
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }
}

#endif
