import Foundation
import ZCore

/// The Mac a template is checked against.
public struct HostProfile: Sendable, Hashable {
    public struct Version: Sendable, Hashable, Comparable, CustomStringConvertible {
        public var major: Int
        public var minor: Int
        public var patch: Int

        public init(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) {
            self.major = major; self.minor = minor; self.patch = patch
        }

        /// "15", "15.5", "15.5.1".
        public init?(string: String) {
            let parts = string.split(separator: ".").map { Int($0) }
            guard let first = parts.first, let major = first, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
            self.init(major, parts.count > 1 ? (parts[1] ?? 0) : 0, parts.count > 2 ? (parts[2] ?? 0) : 0)
        }

        public static func < (a: Version, b: Version) -> Bool {
            (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
        }

        public var description: String { patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)" }
    }

    public var architecture: GuestArchitecture
    public var physicalMemoryBytes: UInt64
    public var cpuCount: Int
    public var osVersion: Version
    /// Free space for important usage on the volume that holds the VMs and the image cache (nil = unknown).
    public var availableDiskBytes: Int64?

    public init(architecture: GuestArchitecture, physicalMemoryBytes: UInt64, cpuCount: Int, osVersion: Version,
                availableDiskBytes: Int64?) {
        self.architecture = architecture; self.physicalMemoryBytes = physicalMemoryBytes; self.cpuCount = cpuCount
        self.osVersion = osVersion; self.availableDiskBytes = availableDiskBytes
    }

    /// This Mac. `storage` is a folder on the volume the VMs live on (default: Application Support).
    public static func current(storage: URL? = nil) -> HostProfile {
        let info = ProcessInfo.processInfo
        let os = info.operatingSystemVersion
        let folder = storage ?? (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                              appropriateFor: nil, create: true))
        var available: Int64?
        if let folder, let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) {
            available = values.volumeAvailableCapacityForImportantUsage
        }
        return HostProfile(architecture: .host, physicalMemoryBytes: info.physicalMemory,
                           cpuCount: info.activeProcessorCount,
                           osVersion: Version(os.majorVersion, os.minorVersion, os.patchVersion),
                           availableDiskBytes: available)
    }
}

/// Whether a template can be created on a host, and what the user should know first.
public struct TemplateFit: Sendable, Hashable {
    /// Reasons it cannot work here (the UI disables "Get & Boot").
    public var blockers: [String]
    /// Things to know (lower memory, Wayland desktop, experimental ISO, the Intel `nopku` issue, ...).
    public var warnings: [String]
    /// An Intel Mac before macOS 15.5 with a kernel 6.12+ image: the guest needs the `nopku` kernel argument.
    public var needsNopku: Bool

    public init(blockers: [String] = [], warnings: [String] = [], needsNopku: Bool = false) {
        self.blockers = blockers; self.warnings = warnings; self.needsNopku = needsNopku
    }

    public var canCreate: Bool { blockers.isEmpty }
}

/// A one-click machine: an image from the catalogue plus VM defaults and first-boot presets.
public struct MachineTemplate: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        /// Cloud image + cloud-init seed: no installer, provisioned on first boot.
        case cloudImage
        /// Installer ISO: the user installs by hand in the VM window.
        case installerISO
        /// macOS from Apple's restore image (Apple silicon).
        case macOS
    }

    /// What the machine is for (icons and grouping in the app).
    public enum Role: String, Sendable, Hashable {
        case desktop, terminal, small, installer, macOS
    }

    public var id: String
    public var name: String
    public var summary: String
    public var kind: Kind
    public var role: Role
    /// Catalogue image per architecture (empty for macOS).
    public var imageIDs: [GuestArchitecture: String]
    public var desktop: DesktopPreset
    public var dev: DevPreset
    public var recommended: Bool
    public var cpuCount: Int
    public var memoryBytes: UInt64
    /// The least memory the guest is useful with (the spec is lowered towards it on small Macs).
    public var minimumMemoryBytes: UInt64
    public var diskBytes: UInt64
    public var display: DisplaySpec
    /// First-boot estimate from the research (A.5); no Mac was available to measure.
    public var firstBoot: String
    /// What the guest downloads on first boot (desktop packages), per architecture, when known.
    public var firstBootDownloadBytes: [GuestArchitecture: Int64]
    public var notes: [String]

    public init(id: String, name: String, summary: String, kind: Kind, role: Role, imageIDs: [GuestArchitecture: String],
                desktop: DesktopPreset = .none, dev: DevPreset = .none, recommended: Bool = false, cpuCount: Int = 4,
                memoryBytes: UInt64 = 4 << 30, minimumMemoryBytes: UInt64 = 2 << 30, diskBytes: UInt64 = 32 << 30,
                display: DisplaySpec = DisplaySpec(), firstBoot: String, firstBootDownloadBytes: [GuestArchitecture: Int64] = [:],
                notes: [String] = []) {
        self.id = id; self.name = name; self.summary = summary; self.kind = kind; self.role = role
        self.imageIDs = imageIDs; self.desktop = desktop; self.dev = dev; self.recommended = recommended
        self.cpuCount = cpuCount; self.memoryBytes = memoryBytes; self.minimumMemoryBytes = minimumMemoryBytes
        self.diskBytes = diskBytes; self.display = display; self.firstBoot = firstBoot
        self.firstBootDownloadBytes = firstBootDownloadBytes; self.notes = notes
    }

    /// Virtualization.framework's `VZEFIBootLoader` boots the guest's own loader and takes no kernel command line,
    /// and the seed only runs after the kernel is up, so `nopku` cannot be applied for the guest: Z Computer shows
    /// the warning instead (`TemplateFit.needsNopku`).
    public static let canSetKernelArguments = false

    /// The catalogue image for `arch` (nil for macOS, or when there is no build for that architecture).
    public func image(for arch: GuestArchitecture = .host, in catalog: [CatalogImage] = ImageCatalog.all) -> CatalogImage? {
        guard let id = imageIDs[arch] else { return nil }
        return ImageCatalog.image(id: id, in: catalog)
    }

    /// Memory for this host: the template's value, lowered (not below `minimumMemoryBytes`) to leave macOS 4 GB.
    public func memory(for host: HostProfile) -> UInt64 {
        let gib: UInt64 = 1 << 30
        let room = host.physicalMemoryBytes > 4 * gib ? host.physicalMemoryBytes - 4 * gib : 0
        let lowered = (min(memoryBytes, max(minimumMemoryBytes, room)) / gib) * gib
        return max(minimumMemoryBytes, lowered)
    }

    /// The VM spec for `host` (CPUs and memory capped to what the Mac has).
    public func makeSpec(name: String? = nil, host: HostProfile) -> VMSpec {
        var spec = VMSpec(name: name ?? self.name, guest: kind == .macOS ? .macOS : .linux,
                          cpuCount: max(1, min(cpuCount, host.cpuCount)), memoryBytes: memory(for: host),
                          diskBytes: diskBytes, display: display)
        spec.notes = "Template: \(self.name)."
        return spec
    }

    /// The cloud-init seed with this template's presets (cloud-image templates only).
    public func cloudInit(for image: CatalogImage, hostname: String, user: String = "z", password: String,
                          agentBinaryName: String? = "zguest-linux-\(GuestArchitecture.host.debianName)") throws -> CloudInitConfig {
        guard kind == .cloudImage else { throw ZError.invalidArgument("\(name) is not a cloud-image template") }
        return try CloudInitConfig.forImage(image, hostname: hostname, user: user, password: password, desktop: desktop,
                                            dev: dev, agentBinaryName: agentBinaryName, display: display)
    }

    /// Architecture, memory and disk checks for `host`. `imageCached`: the image is already downloaded.
    public func fits(host: HostProfile, catalog: [CatalogImage] = ImageCatalog.all, imageCached: Bool = false) -> TemplateFit {
        var fit = TemplateFit()
        let gib: UInt64 = 1 << 30
        var image: CatalogImage?
        switch kind {
        case .macOS:
            if host.architecture != .arm64 { fit.blockers.append("macOS guests need a Mac with Apple silicon.") }
        case .cloudImage, .installerISO:
            image = self.image(for: host.architecture, in: catalog)
            if image == nil {
                fit.blockers.append(host.architecture == .arm64
                    ? "There is no arm64 build of this image, and Macs with Apple silicon run arm64 guests only."
                    : "There is no x86_64 build of this image for this Intel Mac.")
            }
        }

        if host.physicalMemoryBytes < minimumMemoryBytes + 2 * gib {
            fit.blockers.append("Needs at least \(minimumMemoryBytes / gib) GB for the VM plus 2 GB for macOS; "
                                + "this Mac has \(host.physicalMemoryBytes / gib) GB.")
        } else if memory(for: host) < memoryBytes {
            fit.warnings.append("Memory lowered to \(memory(for: host) / gib) GB (from \(memoryBytes / gib) GB) to leave room for macOS.")
        }

        if let available = host.availableDiskBytes {
            let download = imageCached ? 0 : (image?.sizeBytes ?? 0)
            let needed = download + Int64(4 * gib)
            if available < needed {
                fit.blockers.append("Needs about \(Self.bytes(needed)) free for the download and first boot; \(Self.bytes(available)) is free.")
            } else if available < download + Int64(diskBytes) {
                fit.warnings.append("The VM's disk can grow to \(diskBytes / gib) GB, but only \(Self.bytes(available)) is free.")
            }
        }

        if let image {
            if image.needsNopku(on: host) {
                fit.needsNopku = true
                let minimum = image.intelMinMacOS ?? "15.5"
                let message: String
                if kind == .cloudImage {
                    message = "On Intel Macs this image's kernel (6.12 or later) needs macOS \(minimum) or later under "
                        + "Virtualization.framework (lima#3334). The workaround, the `nopku` kernel argument, cannot be set "
                        + "for cloud images yet: update macOS, or use “Agent Desktop (Ubuntu 24.04 + XFCE)” (kernel 6.8)."
                } else {
                    message = "On Intel Macs before macOS \(minimum) this installer's kernel (6.12 or later) may hang at boot "
                        + "(lima#3334): add `nopku` to the kernel command line in the boot menu (press e in GRUB), or update macOS."
                }
                fit.warnings.append(message)
            }
            if image.experimental {
                fit.warnings.append("Experimental: this ISO has no partition table and boots only through El Torito, "
                                    + "which is unverified under Virtualization.framework.")
            }
            if kind == .installerISO, let shipped = image.desktop, shipped.isWayland {
                fit.warnings.append("\(shipped.displayName) by default: the agent's xdotool and screenshots need an X11 session.")
            }
            if image.isAdvanced {
                fit.warnings.append("Advanced: \(image.distro) uses OpenRC instead of systemd; the agent setup is unverified.")
            }
        }
        if host.cpuCount < 2 { fit.warnings.append("This Mac reports \(host.cpuCount) CPU core; the VM will be slow.") }
        return fit
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

extension MachineTemplate {
    /// The Image Library's one-click machines, recommended first. Sizes and estimates: docs/research/images.md.
    public static let all: [MachineTemplate] = [
        MachineTemplate(
            id: "agent-desktop-debian", name: "Agent Desktop (Debian 13 + XFCE)",
            summary: "Debian 13 “trixie” with Xfce on X11, LightDM auto-login, Firefox ESR, xdotool and scrot: "
                + "the desktop the agent drives best.",
            kind: .cloudImage, role: .desktop,
            imageIDs: [.arm64: "debian-13-generic-arm64", .x86_64: "debian-13-generic-x86_64"],
            desktop: .xfceX11, recommended: true, cpuCount: 4, memoryBytes: 4 << 30, minimumMemoryBytes: 2 << 30,
            diskBytes: 16 << 30,
            firstBoot: "About 3–5 minutes to the desktop: the guest installs about 200 MB of Xfce packages (estimate).",
            firstBootDownloadBytes: [.arm64: 199_000_000, .x86_64: 217_000_000],
            notes: ["Full Debian kernel: virtio-gpu, USB keyboard and mouse, vsock.",
                    "Firefox ESR is a regular Debian package (no snaps)."]),
        MachineTemplate(
            id: "agent-desktop-ubuntu", name: "Agent Desktop (Ubuntu 24.04 + XFCE)",
            summary: "Ubuntu 24.04 LTS server image turned into an Xfce/X11 desktop with auto-login, Firefox from "
                + "Mozilla's APT repository, xdotool and scrot.",
            kind: .cloudImage, role: .desktop,
            imageIDs: [.arm64: "ubuntu-24.04-server-arm64", .x86_64: "ubuntu-24.04-server-x86_64"],
            desktop: .xfceX11, cpuCount: 4, memoryBytes: 4 << 30, minimumMemoryBytes: 2 << 30, diskBytes: 16 << 30,
            firstBoot: "About 3–5 minutes to the desktop: the guest installs about 170 MB of packages (estimate).",
            firstBootDownloadBytes: [.arm64: 171_000_000, .x86_64: 171_000_000],
            notes: ["Kernel 6.8: also boots on Intel Macs before macOS 15.5.",
                    "Ubuntu's own firefox package is a snap, so Firefox comes from packages.mozilla.org (pinned key)."]),
        MachineTemplate(
            id: "terminal-dev-ubuntu", name: "Terminal / Dev (Ubuntu 24.04 server)",
            summary: "Ubuntu 24.04 LTS server for terminal work, with git, build tools, Python 3, Node.js, tmux and "
                + "ripgrep from Ubuntu's repositories.",
            kind: .cloudImage, role: .terminal,
            imageIDs: [.arm64: "ubuntu-24.04-server-arm64", .x86_64: "ubuntu-24.04-server-x86_64"],
            dev: .standard, cpuCount: 4, memoryBytes: 4 << 30, minimumMemoryBytes: 2 << 30, diskBytes: 32 << 30,
            firstBoot: "The agent answers about 30–60 seconds after power-on; the developer tools then install in the "
                + "background (estimate).",
            notes: ["lima's default image; supported until 2029."]),
        MachineTemplate(
            id: "smallest-ubuntu-minimal", name: "Smallest (Ubuntu 24.04 minimal)",
            summary: "The smallest download: Ubuntu 24.04 minimal (systemd + apt, no snapd). Terminal only.",
            kind: .cloudImage, role: .small,
            imageIDs: [.arm64: "ubuntu-24.04-minimal-arm64", .x86_64: "ubuntu-24.04-minimal-x86_64"],
            cpuCount: 2, memoryBytes: 2 << 30, minimumMemoryBytes: 1 << 30, diskBytes: 8 << 30,
            firstBoot: "Ready about 30–60 seconds after power-on (estimate).",
            notes: ["Minimised: no man pages (`unminimize` restores them)."]),
        MachineTemplate(
            id: "kali-iso", name: "Kali Linux (installer ISO)",
            summary: "Kali Linux 2026.3 installer. Xfce on X11 after installation, so the agent can drive it once "
                + "xdotool is installed.",
            kind: .installerISO, role: .installer,
            imageIDs: [.arm64: "kali-2026.3-installer-arm64-iso", .x86_64: "kali-2026.3-installer-x86_64-iso"],
            cpuCount: 4, memoryBytes: 4 << 30, minimumMemoryBytes: 2 << 30, diskBytes: 32 << 30,
            firstBoot: "Manual install in the VM window (Debian installer).",
            notes: ["If the graphical installer stays black, use the text “Install” entry (unverified under Virtualization.framework).",
                    "After installing: sudo apt install xdotool scrot, then detach the ISO."]),
        MachineTemplate(
            id: "fedora-xfce-iso", name: "Fedora Xfce spin (ISO)",
            summary: "Fedora 44 Xfce live image with installer: Xfce on X11 with LightDM, the agent-friendly Fedora.",
            kind: .installerISO, role: .installer,
            imageIDs: [.arm64: "fedora-44-xfce-arm64-iso", .x86_64: "fedora-44-xfce-x86_64-iso"],
            cpuCount: 4, memoryBytes: 4 << 30, minimumMemoryBytes: 2 << 30, diskBytes: 32 << 30,
            firstBoot: "Boots into the live desktop; install to disk from there.",
            notes: ["After installing: sudo dnf install xdotool scrot, then detach the ISO."]),
        MachineTemplate(
            id: "ubuntu-desktop-iso", name: "Ubuntu Desktop 24.04 (installer ISO)",
            summary: "The official Ubuntu Desktop 24.04.5 installer (GNOME).",
            kind: .installerISO, role: .installer,
            imageIDs: [.arm64: "ubuntu-24.04.5-desktop-arm64-iso", .x86_64: "ubuntu-24.04.5.1-desktop-x86_64-iso"],
            cpuCount: 4, memoryBytes: 4 << 30, minimumMemoryBytes: 3 << 30, diskBytes: 32 << 30,
            firstBoot: "Manual install in the VM window.",
            notes: ["GNOME uses Wayland by default: pick “Ubuntu on Xorg” at the login screen (or set WaylandEnable=false "
                    + "in /etc/gdm3/custom.conf) so the agent can use xdotool."]),
        MachineTemplate(
            id: "macos", name: "macOS (Apple silicon)",
            summary: "A macOS virtual machine from Apple's latest compatible restore image. At most two macOS VMs can "
                + "run at the same time.",
            kind: .macOS, role: .macOS, imageIDs: [:],
            cpuCount: 4, memoryBytes: 8 << 30, minimumMemoryBytes: 4 << 30, diskBytes: 80 << 30,
            firstBoot: "Downloads the restore image from Apple (several GB) and installs it; then finish Setup Assistant "
                + "in the window.",
            notes: ["The guest agent is Linux-only: the agent drives macOS through the screen only."]),
    ]

    public static func template(id: String) -> MachineTemplate? { all.first { $0.id == id } }
}
