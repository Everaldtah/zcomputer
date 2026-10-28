import Foundation
import ZCore

/// Run state of an emulated machine.
public enum EmuRunState: Sendable, Hashable {
    case stopped
    case starting
    case running
    case paused
    case saving
    case error(String)

    /// True while the emulator exists (its screen is live).
    public var isActive: Bool {
        switch self {
        case .starting, .running, .paused, .saving: return true
        case .stopped, .error: return false
        }
    }

    public var label: String {
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

/// What the guest's display is doing.
public enum EmuScreenMode: Sendable, Hashable {
    /// VGA text mode, `cols` x `rows` characters (screenshots are 9x16 pixels per character).
    case text(cols: Int, rows: Int)
    /// A graphics mode.
    case graphical(width: Int, height: Int, bpp: Int)

    /// Pixel size of a screenshot in this mode (and the coordinate space of the mouse).
    public var pixelSize: PixelSize {
        switch self {
        case .text(let cols, let rows): return PixelSize(width: cols * 9, height: rows * 16)
        case .graphical(let w, let h, _): return PixelSize(width: w, height: h)
        }
    }

    public var isGraphical: Bool {
        if case .graphical = self { return true }
        return false
    }
}

/// The options the host page turns into `new V86({...})` (see emu.js `cmd_start`). Built from an `EmuSpec` by
/// `EmuLaunchConfig.make` (pure; tested).
struct EmuLaunchConfig: Codable, Sendable, Equatable {
    struct Disk: Codable, Sendable, Equatable {
        var url: String
        var size: UInt64
    }

    struct BootAssist: Codable, Sendable, Equatable {
        var screenText: String?
        var serialText: String?
        var delayMs: Int?
        var strokes: [[UInt8]]
        var strokeDelayMs: Int
        var serialSend: String?
        var timeoutMs: Int
    }

    var wasmPath: String
    var biosURL: String
    var vgaBiosURL: String
    var memorySize: Int
    var vgaMemorySize: Int
    var bootOrder: Int
    var acpi: Bool
    var fastboot: Bool
    var nic: String
    var relayURL: String?
    var corsProxy: String?
    var cdrom: Disk?
    var hda: Disk?
    var initialState: String?
    var filesystem: Bool
    var preserveMAC: Bool
    var serial: Bool
    var hostKeyboard: Bool
    var bootAssist: BootAssist?

    /// - Parameters:
    ///   - cdrom/hda: page URLs and sizes of the images (already registered with the scheme handler).
    ///   - initialState: page URL of the state to start from, if any (boot assists only run on cold boots).
    static func make(spec: EmuSpec, cdrom: Disk?, hda: Disk?, initialState: String?, hostKeyboard: Bool = true) throws -> EmuLaunchConfig {
        var assist: BootAssist?
        if let a = spec.bootAssist, initialState == nil {
            var strokes = try ScanCodes.typing(a.typeText ?? "")
            for combo in a.keys ?? [] { strokes += try ScanCodes.scancodes(forKeys: combo) }
            assist = BootAssist(screenText: a.waitForScreenText, serialText: a.waitForSerialText,
                                delayMs: a.delaySeconds.map { Int($0 * 1000) }, strokes: strokes, strokeDelayMs: 40,
                                serialSend: a.serialText, timeoutMs: Int(a.timeoutSeconds * 1000))
        }
        let fetch = spec.network == .fetch
        return EmuLaunchConfig(
            wasmPath: EmuHost.wasmURL, biosURL: EmuHost.biosURL, vgaBiosURL: EmuHost.vgaBiosURL,
            memorySize: spec.memoryMB << 20, vgaMemorySize: spec.vgaMemoryMB << 20,
            bootOrder: spec.bootOrder, acpi: spec.acpi, fastboot: spec.fastBoot, nic: spec.nic.rawValue,
            relayURL: fetch ? "fetch" : nil, corsProxy: fetch ? EmuHost.corsProxyPrefix : nil,
            cdrom: cdrom, hda: hda, initialState: initialState, filesystem: spec.enable9p,
            preserveMAC: spec.preserveMACFromState, serial: spec.serial, hostKeyboard: hostKeyboard,
            bootAssist: assist)
    }
}

/// A screenshot as the page returned it.
struct EmuPageScreenshot: Sendable {
    var png: Data?
    var graphical: Bool
    var size: PixelSize
}
