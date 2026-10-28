import Foundation
import UIKit
import ZCore

// The app's view of the machine layer. ZEmu (x86 Linux emulated by v86 inside a WKWebView) implements it through
// `ZEmuMachineEngine`; `UnavailableMachineEngine` stands in when a build has no emulator. Keeping the views on this
// small protocol means the Machines, Agent and Terminal screens never touch WebKit or ZEmu types directly.

/// Run state of an emulated machine.
enum MachineRunState: Hashable, Sendable {
    case stopped
    case starting
    case running
    case paused
    case saving
    case error(String)

    /// True while the machine has a live screen (running, paused or saving).
    var isActive: Bool {
        switch self {
        case .running, .paused, .saving, .starting: return true
        case .stopped, .error: return false
        }
    }

    var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting"
        case .running: return "Running"
        case .paused: return "Paused"
        case .saving: return "Saving state"
        case .error(let message): return "Error: \(message)"
        }
    }
}

/// A machine the user created.
struct MachineSummary: Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var memoryMB: Int
    var screenWidth: Int
    var screenHeight: Int
    /// "Alpine Linux virt ISO", "Z Alpine Desktop (instant start)", …
    var bootDescription: String
    /// True when a saved state exists (the machine resumes where it was).
    var hasSavedState: Bool
}

/// What a catalogue image boots as.
enum MachineImageKind: String, Hashable, Sendable {
    /// A ready-made disk with a saved state: boots straight to the desktop.
    case instantStart
    /// An installer / live CD image.
    case iso
    /// A disk image.
    case disk
}

/// Whether a catalogue image can be downloaded right now.
enum MachineImageAvailability: Hashable, Sendable {
    case available
    /// Its files are described by a manifest that is being fetched (Z Alpine Desktop's `manifest.json`).
    case resolving
    /// The manifest could not be fetched (offline, or the release is not published).
    case unavailable(String)
}

/// One entry of the image catalogue (ZEmu's `EmuImageCatalog`).
struct MachineImage: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var summary: String
    var kind: MachineImageKind
    /// Download size, when the catalogue knows it.
    var downloadBytes: Int64?
    var recommended: Bool
    var defaultMemoryMB: Int
    /// Instant-start images restore a saved state, which only works with the memory size it was taken with.
    var fixedMemoryMB: Int? = nil
    /// The image build (from its manifest), when known.
    var version: String? = nil
    var availability: MachineImageAvailability = .available
}

/// The steps of preparing a catalogue image.
enum ImagePhase: String, Hashable, Sendable {
    case manifest, download, verify, unpack, ready

    var title: String {
        switch self {
        case .manifest: return "Reading the manifest"
        case .download: return "Downloading"
        case .verify: return "Checking"
        case .unpack: return "Unpacking"
        case .ready: return "Ready"
        }
    }
}

/// Download / preparation progress of a catalogue image.
struct ImageProgress: Hashable, Sendable {
    var fraction: Double?
    var detail: String
    var phase: ImagePhase = .download
}

/// Where a catalogue image is on this device.
enum ImageDownloadState: Hashable {
    case notDownloaded
    case downloading(ImageProgress)
    case ready
    case failed(String)
}

/// Guest RAM limits of the engine (ZEmu: `EmuSpec.recommendedMaxMemoryMBOnPhone` / `maxMemoryMBOnPhone` /
/// `maxMemoryMB`).
struct MachineMemoryLimits: Hashable, Sendable {
    /// Above this, iOS may end the emulator on an iPhone.
    var recommendedOnPhoneMB: Int
    /// The hard ceiling on an iPhone.
    var maxOnPhoneMB: Int
    /// The ceiling elsewhere (iPad).
    var maxMB: Int

    static let standard = MachineMemoryLimits(recommendedOnPhoneMB: 512, maxOnPhoneMB: 1024, maxMB: 3072)
}

/// App settings of the machine layer.
enum MachineSettings {
    /// Guest networking through the app (ZEmu's `.fetch`: emulated DHCP/DNS, plain HTTP on port 80). Off by default.
    static let guestNetworkKey = "machines.guestNetwork"

    static var guestNetworkEnabled: Bool { UserDefaults.standard.bool(forKey: guestNetworkKey) }
}

/// The machine layer: machines, the image catalogue and per-machine runtimes.
@MainActor
protocol MachineEngine: AnyObject, Sendable {
    /// Shown in Settings ▸ About and on the Machines screen.
    var engineName: String { get }
    /// Nil when machines can run in this build; otherwise why not.
    var unavailableReason: String? { get }
    var memoryLimits: MachineMemoryLimits { get }

    func listMachines() throws -> [MachineSummary]
    func catalogue() -> [MachineImage]
    /// Fetches the manifests of images whose files a manifest describes (no-op when all are known).
    func refreshCatalogue() async
    func isImageReady(_ image: MachineImage) -> Bool
    /// Downloads, verifies and unpacks an image (resumable). `progress` may be called on any thread.
    func prepareImage(_ image: MachineImage, progress: @escaping @Sendable (ImageProgress) -> Void) async throws
    func deleteImage(_ image: MachineImage) throws
    /// Problems with a machine of `memoryMB` (empty when fine).
    func validate(memoryMB: Int, isPhone: Bool) -> [String]
    func createMachine(name: String, image: MachineImage, memoryMB: Int) throws -> MachineSummary
    /// A machine that boots an ISO the user provided (in the app's Documents/ISOs).
    func createMachine(name: String, iso: URL, memoryMB: Int) throws -> MachineSummary
    func deleteMachine(_ id: UUID) throws
    /// The machine's runtime (made on first use and kept for the session).
    func makeRuntime(for id: UUID) throws -> any MachineRuntime
}

/// One machine's emulator: lifecycle, the live screen view, the serial console and the agent's surface.
@MainActor
protocol MachineRuntime: AnyObject, Sendable {
    var state: MachineRunState { get }
    /// State changes (the current state first; one stream per call).
    func stateStream() -> AsyncStream<MachineRunState>
    /// The live screen (ZEmu's WKWebView). It must stay in a window while the machine runs: the app parks it
    /// behind the tab view when no screen shows it.
    var screenView: UIView { get }
    /// The guest display size in pixels.
    var screenSize: PixelSize { get }
    /// Guest display size changes (mode switches; one stream per call).
    func screenSizeStream() -> AsyncStream<PixelSize>
    /// Whether the guest network was on when this runtime was made.
    var guestNetworkEnabled: Bool { get }

    /// Starts the machine, resuming where it was last saved (or its image's starting point).
    func start() async throws
    /// Powers off. With `saveState`, the next start resumes exactly here; without, it starts afresh.
    func stop(saveState: Bool) async throws
    func pause() async throws
    func resume() async throws
    /// Saves now; the next start resumes from here.
    func saveState() async throws

    /// The app goes to the background: pause and save, so the machine survives iOS ending the app.
    func enterBackground() async
    /// Back in the foreground: resume what `enterBackground` paused.
    func enterForeground() async

    /// Serial console output (replaying recent output first).
    func consoleOutput() -> AsyncStream<Data>
    func writeConsole(_ data: Data)

    /// The `ComputerSurface` agents (and the touch layer) drive.
    func makeSurface() -> any ComputerSurface
}

/// Stand-in engine for builds without the emulator: the catalogue is listed, nothing runs.
@MainActor
final class UnavailableMachineEngine: MachineEngine {
    let engineName = "No emulator in this build"
    let unavailableReason: String? = "This build of Z Computer has no emulator (ZEmu). Use the Demo machine, "
        + "or install a build that includes it."
    let memoryLimits = MachineMemoryLimits.standard

    func listMachines() throws -> [MachineSummary] { [] }

    func catalogue() -> [MachineImage] { MachineImageCatalog.fallback }

    func refreshCatalogue() async {}

    func isImageReady(_ image: MachineImage) -> Bool { false }

    func prepareImage(_ image: MachineImage, progress: @escaping @Sendable (ImageProgress) -> Void) async throws {
        throw ZError.unsupported(unavailableReason ?? "No emulator")
    }

    func deleteImage(_ image: MachineImage) throws {}

    func validate(memoryMB: Int, isPhone: Bool) -> [String] { [] }

    func createMachine(name: String, image: MachineImage, memoryMB: Int) throws -> MachineSummary {
        throw ZError.unsupported(unavailableReason ?? "No emulator")
    }

    func createMachine(name: String, iso: URL, memoryMB: Int) throws -> MachineSummary {
        throw ZError.unsupported(unavailableReason ?? "No emulator")
    }

    func deleteMachine(_ id: UUID) throws {}

    func makeRuntime(for id: UUID) throws -> any MachineRuntime {
        throw ZError.unsupported(unavailableReason ?? "No emulator")
    }
}

/// The catalogue entries the app shows when the engine has none of its own (ids as in ZEmu's images-x86.json).
enum MachineImageCatalog {
    static let fallback: [MachineImage] = [
        MachineImage(id: "z-alpine-desktop-x86", name: "Z Alpine Desktop (x86)",
                     summary: "Alpine Linux with an XFCE desktop, prepared for agents. Starts in seconds from a "
                        + "saved state.",
                     kind: .instantStart, downloadBytes: nil, recommended: true, defaultMemoryMB: 512,
                     fixedMemoryMB: 512),
        MachineImage(id: "alpine-virt-x86", name: "Alpine Linux 3.22 virt (x86 ISO)",
                     summary: "Small text-mode Alpine installer / live system.",
                     kind: .iso, downloadBytes: nil, recommended: false, defaultMemoryMB: 256),
        MachineImage(id: "debian-12-i386-netinst", name: "Debian 12.15 (i386 netinst ISO)",
                     summary: "Debian's network installer for 32-bit PCs. Installing takes a long time in an "
                        + "emulator.",
                     kind: .iso, downloadBytes: nil, recommended: false, defaultMemoryMB: 512),
        MachineImage(id: "tinycore-x86", name: "Tiny Core Linux 17.1 (x86 ISO)",
                     summary: "A tiny graphical live system (about 25 MB).",
                     kind: .iso, downloadBytes: nil, recommended: false, defaultMemoryMB: 256),
    ]
}
