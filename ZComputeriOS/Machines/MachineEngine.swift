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
}

/// Download / preparation progress of a catalogue image.
struct ImageProgress: Hashable, Sendable {
    var fraction: Double?
    var detail: String
}

/// Where a catalogue image is on this device.
enum ImageDownloadState: Hashable {
    case notDownloaded
    case downloading(ImageProgress)
    case ready
    case failed(String)
}

/// The machine layer: machines, the image catalogue and per-machine runtimes.
@MainActor
protocol MachineEngine: AnyObject, Sendable {
    /// Shown in Settings ▸ About and on the Machines screen.
    var engineName: String { get }
    /// Nil when machines can run in this build; otherwise why not.
    var unavailableReason: String? { get }

    func listMachines() throws -> [MachineSummary]
    func catalogue() -> [MachineImage]
    func isImageReady(_ image: MachineImage) -> Bool
    /// Downloads, verifies and unpacks an image (resumable). `progress` may be called on any thread.
    func prepareImage(_ image: MachineImage, progress: @escaping @Sendable (ImageProgress) -> Void) async throws
    func deleteImage(_ image: MachineImage) throws
    func createMachine(name: String, image: MachineImage, memoryMB: Int) throws -> MachineSummary
    /// A machine that boots an ISO the user provided (copied into the app's Documents/ISOs).
    func createMachine(name: String, iso: URL, memoryMB: Int) throws -> MachineSummary
    func deleteMachine(_ id: UUID) throws
    /// The machine's runtime (made on first use and kept for the session).
    func makeRuntime(for id: UUID) throws -> any MachineRuntime
}

/// One machine's emulator: lifecycle, the live screen view, the serial console and the agent's surface.
@MainActor
protocol MachineRuntime: AnyObject, Sendable {
    var state: MachineRunState { get }
    /// State changes from now on (one stream per call).
    func stateStream() -> AsyncStream<MachineRunState>
    /// The live screen (ZEmu's WKWebView). It must stay in a window while the machine runs: the app parks it
    /// behind the tab view when no screen shows it.
    var screenView: UIView { get }
    /// The guest display size in pixels.
    var screenSize: PixelSize { get }

    func start() async throws
    func stop() async throws
    func pause() async throws
    func resume() async throws
    func saveState() async throws

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

    func listMachines() throws -> [MachineSummary] { [] }

    func catalogue() -> [MachineImage] { MachineImageCatalog.fallback }

    func isImageReady(_ image: MachineImage) -> Bool { false }

    func prepareImage(_ image: MachineImage, progress: @escaping @Sendable (ImageProgress) -> Void) async throws {
        throw ZError.unsupported(unavailableReason ?? "No emulator")
    }

    func deleteImage(_ image: MachineImage) throws {}

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

/// The catalogue entries the app shows when the engine has none of its own.
enum MachineImageCatalog {
    static let fallback: [MachineImage] = [
        MachineImage(id: "z-alpine-desktop", name: "Z Alpine Desktop (x86)",
                     summary: "Alpine Linux with a light desktop, prepared for agents. Starts in seconds from a "
                        + "saved state.",
                     kind: .instantStart, downloadBytes: nil, recommended: true, defaultMemoryMB: 512),
        MachineImage(id: "alpine-virt", name: "Alpine Linux (virt ISO)",
                     summary: "Small text-mode Alpine installer / live system.",
                     kind: .iso, downloadBytes: nil, recommended: false, defaultMemoryMB: 256),
        MachineImage(id: "debian-12-i386-netinst", name: "Debian 12 (i386 netinst)",
                     summary: "Debian's network installer for 32-bit PCs. Installing takes a long time in an "
                        + "emulator.",
                     kind: .iso, downloadBytes: nil, recommended: false, defaultMemoryMB: 512),
        MachineImage(id: "tinycore", name: "Tiny Core Linux",
                     summary: "A tiny graphical live system (about 25 MB).",
                     kind: .iso, downloadBytes: nil, recommended: false, defaultMemoryMB: 256),
    ]
}
