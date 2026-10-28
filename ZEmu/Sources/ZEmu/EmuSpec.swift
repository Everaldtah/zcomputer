import Foundation
import ZCore

/// What a machine boots from.
public enum EmuBootMedia: Codable, Sendable, Hashable {
    /// A CD-ROM image (installer / live system); boots from the CD first.
    case iso(URL)
    /// A raw hard-disk image (v86 `hda`); boots from the disk first.
    case disk(URL)
    /// A v86 saved state, plus the pristine disk image it was taken with (if any). The machine resumes where the
    /// state was saved. A state only restores with the same v86 build and the same machine options (memory, VGA
    /// memory, devices, disk images) it was saved with.
    case state(URL, disk: URL?)

    private enum CodingKeys: String, CodingKey { case kind, url, disk }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        let url = try c.decode(URL.self, forKey: .url)
        switch kind {
        case "iso": self = .iso(url)
        case "disk": self = .disk(url)
        case "state": self = .state(url, disk: try c.decodeIfPresent(URL.self, forKey: .disk))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown boot media \(kind)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .iso(let url):
            try c.encode("iso", forKey: .kind); try c.encode(url, forKey: .url)
        case .disk(let url):
            try c.encode("disk", forKey: .kind); try c.encode(url, forKey: .url)
        case .state(let url, let disk):
            try c.encode("state", forKey: .kind); try c.encode(url, forKey: .url)
            try c.encodeIfPresent(disk, forKey: .disk)
        }
    }

    /// Short human description ("Alpine.iso", "disk.img", "saved state").
    public var summary: String {
        switch self {
        case .iso(let url): return url.lastPathComponent
        case .disk(let url): return url.lastPathComponent
        case .state(_, let disk): return "saved state" + (disk.map { " of \($0.lastPathComponent)" } ?? "")
        }
    }
}

/// The guest's network.
public enum EmuNetwork: String, Codable, Sendable, Hashable {
    /// A network card without a backend (the guest sees a NIC with no link partner).
    case none
    /// v86's `fetch` backend: DHCP/DNS are emulated and plain HTTP (TCP port 80) requests are forwarded through the
    /// host page's `fetch()`, proxied by ZEmu's URL scheme handler (no CORS restrictions). No raw TCP/UDP, no TLS
    /// on port 443; the guest uses `http://` URLs (e.g. Alpine's package mirrors).
    case fetch
}

/// The emulated network card.
public enum EmuNIC: String, Codable, Sendable, Hashable {
    /// virtio-net (Linux `virtio_net`); the default, and what the Z Alpine Desktop state was taken with.
    case virtio
    /// NE2000 (`ne2k-pci`), for older guests.
    case ne2k
}

/// A login on the guest's serial console (for the serial shell fallback).
public struct EmuCredentials: Codable, Sendable, Hashable {
    public var user: String
    public var password: String?
    public init(user: String, password: String?) { self.user = user; self.password = password }
}

/// Keystrokes the host sends while a machine cold-boots, e.g. to add `console=ttyS0` at an ISO's `boot:` prompt.
/// Not used when a machine resumes from a saved state.
public struct EmuBootAssist: Codable, Sendable, Hashable {
    /// Wait until this text appears anywhere on the VGA text screen.
    public var waitForScreenText: String?
    /// Or wait until this text appears on the serial console.
    public var waitForSerialText: String?
    /// Seconds to wait (after the wait above, or after start when nothing is awaited).
    public var delaySeconds: Double?
    /// Text typed on the PS/2 keyboard (US layout; "\n" is Return).
    public var typeText: String?
    /// xdotool-style key combinations pressed after `typeText` ("Return", "ctrl+alt+F2").
    public var keys: [String]?
    /// Text sent to the serial port after the keys.
    public var serialText: String?
    /// Give up waiting after this many seconds.
    public var timeoutSeconds: Double

    public init(waitForScreenText: String? = nil, waitForSerialText: String? = nil, delaySeconds: Double? = nil,
                typeText: String? = nil, keys: [String]? = nil, serialText: String? = nil, timeoutSeconds: Double = 90) {
        self.waitForScreenText = waitForScreenText; self.waitForSerialText = waitForSerialText
        self.delaySeconds = delaySeconds; self.typeText = typeText; self.keys = keys; self.serialText = serialText
        self.timeoutSeconds = timeoutSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case waitForScreenText, waitForSerialText, delaySeconds, typeText, keys, serialText, timeoutSeconds
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        waitForScreenText = try c.decodeIfPresent(String.self, forKey: .waitForScreenText)
        waitForSerialText = try c.decodeIfPresent(String.self, forKey: .waitForSerialText)
        delaySeconds = try c.decodeIfPresent(Double.self, forKey: .delaySeconds)
        typeText = try c.decodeIfPresent(String.self, forKey: .typeText)
        keys = try c.decodeIfPresent([String].self, forKey: .keys)
        serialText = try c.decodeIfPresent(String.self, forKey: .serialText)
        timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 90
    }
}

/// One emulated x86 PC: what it boots, its hardware, and how the host talks to it.
///
/// **Memory on iPhone.** v86 keeps guest RAM inside the WebAssembly memory of the `WKWebView`'s web-content
/// process, next to VGA memory, the JIT's code cache and (with async disks) every disk block the guest wrote. iOS
/// terminates a web-content process at roughly 1–1.5 GB of footprint (lower on 3–4 GB devices, higher on 8 GB
/// iPads), and restoring a saved state briefly needs the state file in memory as well. Keep guest RAM at or below
/// `recommendedMaxMemoryMBOnPhone` (512 MB) on iPhone; `maxMemoryMBOnPhone` (1024 MB) is the hard ceiling ZEmu
/// accepts there. Macs and iPads with more memory can go higher (v86's 32-bit guests address at most ~3.5 GB).
public struct EmuSpec: Codable, Sendable, Hashable, Identifiable {
    public static let recommendedMaxMemoryMBOnPhone = 512
    public static let maxMemoryMBOnPhone = 1024
    /// v86's 32-bit physical address space minus the PCI hole.
    public static let maxMemoryMB = 3072

    public var id: UUID
    public var name: String
    /// Guest RAM (v86 `memory_size`).
    public var memoryMB: Int
    /// VGA memory (v86 `vga_memory_size`); 8 MB covers 1024x768x32 and 1280x1024x32 with page flipping.
    public var vgaMemoryMB: Int
    /// The display size the guest is expected to use. v86 does not force a mode (the guest picks one through the
    /// Bochs VBE / VGA registers); this sizes the host view and the cursor maths until the guest sets a mode.
    public var screen: PixelSize
    public var boot: EmuBootMedia
    /// An extra CD-ROM next to a disk or state boot (installer ISO + target disk, or the ISO a live state was saved on).
    public var cdrom: URL?
    /// An extra hard disk next to an ISO boot (install target).
    public var hda: URL?
    /// A host folder whose files are copied into v86's in-memory virtio-9p filesystem at boot. The guest mounts it
    /// with `mount -t 9p -o trans=virtio,version=9p2000.L host9p /mnt/host` (v86's mount tag is always `host9p`).
    /// With or without it, the 9p device is the fast path for `EmuSurface.readFile` / `writeFile`.
    public var shareDirectory: URL?
    /// Present a virtio-9p device (v86 `filesystem: {}`). Needed by states taken with one (Z Alpine Desktop).
    public var enable9p: Bool
    /// Use COM1 (`ttyS0`) as the console stream and for the serial shell.
    public var serial: Bool
    public var network: EmuNetwork
    public var nic: EmuNIC
    /// ACPI tables (v86 `acpi`). Off by default, like the Z Alpine Desktop state.
    public var acpi: Bool
    /// Skip the BIOS boot-menu delay (v86 `fastboot`).
    public var fastBoot: Bool
    /// Keep the MAC address stored in a restored state (v86 `preserve_mac_from_state_image`).
    public var preserveMACFromState: Bool
    /// Serial-console login for the shell fallback (nil: only an already logged-in console works).
    public var serialLogin: EmuCredentials?
    /// Keystrokes sent during a cold boot (see `EmuBootAssist`).
    public var bootAssist: EmuBootAssist?
    /// Relative-mouse calibration: guest pixels moved per PS/2 count (1.0 for an unaccelerated pointer).
    public var mouseSensitivity: Double
    /// The catalogue image this machine was made from, if any.
    public var imageID: String?
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, memoryMB: Int = 512, vgaMemoryMB: Int = 8,
                screen: PixelSize = PixelSize(width: 1024, height: 768), boot: EmuBootMedia, cdrom: URL? = nil,
                hda: URL? = nil, shareDirectory: URL? = nil, enable9p: Bool = true, serial: Bool = true,
                network: EmuNetwork = .none, nic: EmuNIC = .virtio, acpi: Bool = false, fastBoot: Bool = true,
                preserveMACFromState: Bool = true, serialLogin: EmuCredentials? = nil, bootAssist: EmuBootAssist? = nil,
                mouseSensitivity: Double = 1.0, imageID: String? = nil, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.memoryMB = memoryMB; self.vgaMemoryMB = vgaMemoryMB; self.screen = screen
        self.boot = boot; self.cdrom = cdrom; self.hda = hda; self.shareDirectory = shareDirectory
        self.enable9p = enable9p; self.serial = serial; self.network = network; self.nic = nic; self.acpi = acpi
        self.fastBoot = fastBoot; self.preserveMACFromState = preserveMACFromState; self.serialLogin = serialLogin
        self.bootAssist = bootAssist; self.mouseSensitivity = mouseSensitivity; self.imageID = imageID
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, memoryMB, vgaMemoryMB, screen, boot, cdrom, hda, shareDirectory, enable9p, serial, network, nic
        case acpi, fastBoot, preserveMACFromState, serialLogin, bootAssist, mouseSensitivity, imageID, createdAt
    }

    /// Decodes leniently: every field except `boot` has a default, so older spec files keep loading.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Machine"
        memoryMB = try c.decodeIfPresent(Int.self, forKey: .memoryMB) ?? 512
        vgaMemoryMB = try c.decodeIfPresent(Int.self, forKey: .vgaMemoryMB) ?? 8
        screen = try c.decodeIfPresent(PixelSize.self, forKey: .screen) ?? PixelSize(width: 1024, height: 768)
        boot = try c.decode(EmuBootMedia.self, forKey: .boot)
        cdrom = try c.decodeIfPresent(URL.self, forKey: .cdrom)
        hda = try c.decodeIfPresent(URL.self, forKey: .hda)
        shareDirectory = try c.decodeIfPresent(URL.self, forKey: .shareDirectory)
        enable9p = try c.decodeIfPresent(Bool.self, forKey: .enable9p) ?? true
        serial = try c.decodeIfPresent(Bool.self, forKey: .serial) ?? true
        network = try c.decodeIfPresent(EmuNetwork.self, forKey: .network) ?? .none
        nic = try c.decodeIfPresent(EmuNIC.self, forKey: .nic) ?? .virtio
        acpi = try c.decodeIfPresent(Bool.self, forKey: .acpi) ?? false
        fastBoot = try c.decodeIfPresent(Bool.self, forKey: .fastBoot) ?? true
        preserveMACFromState = try c.decodeIfPresent(Bool.self, forKey: .preserveMACFromState) ?? true
        serialLogin = try c.decodeIfPresent(EmuCredentials.self, forKey: .serialLogin)
        bootAssist = try c.decodeIfPresent(EmuBootAssist.self, forKey: .bootAssist)
        mouseSensitivity = try c.decodeIfPresent(Double.self, forKey: .mouseSensitivity) ?? 1.0
        imageID = try c.decodeIfPresent(String.self, forKey: .imageID)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name)
        try c.encode(memoryMB, forKey: .memoryMB); try c.encode(vgaMemoryMB, forKey: .vgaMemoryMB)
        try c.encode(screen, forKey: .screen); try c.encode(boot, forKey: .boot)
        try c.encodeIfPresent(cdrom, forKey: .cdrom); try c.encodeIfPresent(hda, forKey: .hda)
        try c.encodeIfPresent(shareDirectory, forKey: .shareDirectory); try c.encode(enable9p, forKey: .enable9p)
        try c.encode(serial, forKey: .serial); try c.encode(network, forKey: .network); try c.encode(nic, forKey: .nic)
        try c.encode(acpi, forKey: .acpi); try c.encode(fastBoot, forKey: .fastBoot)
        try c.encode(preserveMACFromState, forKey: .preserveMACFromState)
        try c.encodeIfPresent(serialLogin, forKey: .serialLogin); try c.encodeIfPresent(bootAssist, forKey: .bootAssist)
        try c.encode(mouseSensitivity, forKey: .mouseSensitivity); try c.encodeIfPresent(imageID, forKey: .imageID)
        try c.encode(createdAt, forKey: .createdAt)
    }

    // MARK: Derived media

    /// The CD-ROM image the machine starts with.
    public var cdromImage: URL? {
        if case .iso(let url) = boot { return url }
        return cdrom
    }

    /// The hard-disk image the machine starts with.
    public var diskImage: URL? {
        switch boot {
        case .disk(let url): return url
        case .state(_, let disk): return disk ?? hda
        case .iso: return hda
        }
    }

    /// The saved state the machine starts from, if any.
    public var initialState: URL? {
        if case .state(let url, _) = boot { return url }
        return nil
    }

    /// v86 boot order: CD first for ISO boots (so an installer CD wins over an empty target disk), disk first
    /// otherwise. v86's constants: 0x123 CD/HD/FD, 0x312 HD/CD/FD.
    public var bootOrder: Int {
        if case .iso = boot { return 0x123 }
        return 0x312
    }

    /// Checks the hardware settings; returns human-readable problems (empty when fine).
    public func validate(isPhone: Bool = false) -> [String] {
        var problems: [String] = []
        let ceiling = isPhone ? Self.maxMemoryMBOnPhone : Self.maxMemoryMB
        if memoryMB < 16 { problems.append("At least 16 MB of RAM is needed.") }
        if memoryMB > ceiling { problems.append("At most \(ceiling) MB of RAM is supported here.") }
        if vgaMemoryMB < 1 || vgaMemoryMB > 128 { problems.append("VGA memory must be 1–128 MB.") }
        if screen.width < 320 || screen.height < 200 { problems.append("The screen must be at least 320x200.") }
        if mouseSensitivity <= 0 { problems.append("Mouse sensitivity must be positive.") }
        return problems
    }
}
