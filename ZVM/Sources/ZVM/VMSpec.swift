import Foundation
import ZCore

/// The guest operating system family of a VM.
public enum GuestOS: String, Codable, Sendable, Hashable, CaseIterable {
    case linux
    case macOS
}

/// CPU architecture of a guest (or of the host).
public enum GuestArchitecture: String, Codable, Sendable, Hashable, CaseIterable {
    case arm64
    case x86_64

    /// The architecture of the Mac we are running on. Virtualization.framework only runs guests of this architecture.
    public static var host: GuestArchitecture {
        #if arch(arm64)
        return .arm64
        #else
        return .x86_64
        #endif
    }

    /// Debian/Ubuntu spelling (`arm64` / `amd64`).
    public var debianName: String { self == .arm64 ? "arm64" : "amd64" }
    /// `uname -m` spelling (`aarch64` / `x86_64`).
    public var unameName: String { self == .arm64 ? "aarch64" : "x86_64" }
}

/// Guest display geometry. `ppi` only matters for macOS guests (VZMacGraphicsDisplayConfiguration).
public struct DisplaySpec: Codable, Sendable, Hashable {
    public var width: Int
    public var height: Int
    public var ppi: Int

    public init(width: Int = 1280, height: Int = 800, ppi: Int = 110) {
        self.width = width; self.height = height; self.ppi = ppi
    }

    public var pixelSize: PixelSize { PixelSize(width: width, height: height) }
}

/// Where the guest operating system comes from.
public enum InstallSource: Sendable, Hashable {
    /// A UEFI-bootable installer ISO, attached read-only as a USB stick while `VMSpec.attachInstallMedia` is true.
    case iso(URL)
    /// A ready-to-run disk image (e.g. a cloud image from `ImageCatalog`) that was copied/converted into `disk.img`.
    case diskImage(URL)
    /// A macOS restore image (`.ipsw`); `nil` = download the latest supported image from Apple.
    case macOSRestoreImage(URL?)
    /// Nothing to install: `disk.img` already holds a bootable system.
    case none

    /// The local file behind the source, if any.
    public var url: URL? {
        switch self {
        case .iso(let u), .diskImage(let u): return u
        case .macOSRestoreImage(let u): return u
        case .none: return nil
        }
    }

    public var kind: String {
        switch self {
        case .iso: return "iso"
        case .diskImage: return "diskImage"
        case .macOSRestoreImage: return "macOSRestoreImage"
        case .none: return "none"
        }
    }
}

extension InstallSource: Codable {
    private enum CodingKeys: String, CodingKey { case kind, url }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        let url = try c.decodeIfPresent(URL.self, forKey: .url)
        switch kind {
        case "iso":
            guard let url else { throw DecodingError.dataCorruptedError(forKey: .url, in: c, debugDescription: "iso needs a url") }
            self = .iso(url)
        case "diskImage":
            guard let url else { throw DecodingError.dataCorruptedError(forKey: .url, in: c, debugDescription: "diskImage needs a url") }
            self = .diskImage(url)
        case "macOSRestoreImage":
            self = .macOSRestoreImage(url)
        case "none":
            self = .none
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown install source \(kind)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(url, forKey: .url)
    }
}

/// Persistent access to a user-selected file or folder (sandbox): the bookmark data plus how it was made.
public struct FileBookmark: Codable, Sendable, Hashable {
    public var data: Data
    /// True for a security-scoped (app-scope) bookmark; resolve with `.withSecurityScope` and call
    /// `startAccessingSecurityScopedResource()` on the resolved URL.
    public var securityScoped: Bool

    public init(data: Data, securityScoped: Bool) {
        self.data = data; self.securityScoped = securityScoped
    }

    /// Creates a bookmark for a URL the user picked (NSOpenPanel / drag and drop).
    /// Inside the App Sandbox use `securityScoped: true` (needs `com.apple.security.files.bookmarks.app-scope`).
    public static func make(for url: URL, securityScoped: Bool = true, readOnly: Bool = false) throws -> FileBookmark {
        var options: URL.BookmarkCreationOptions = []
        if securityScoped {
            options.insert(.withSecurityScope)
            if readOnly { options.insert(.securityScopeAllowOnlyReadAccess) }
        }
        let data = try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
        return FileBookmark(data: data, securityScoped: securityScoped)
    }

    /// Resolves the bookmark. `isStale` means the bookmark should be re-created (see `refreshed(for:)`).
    public func resolve() throws -> (url: URL, isStale: Bool) {
        var stale = false
        let options: URL.BookmarkResolutionOptions = securityScoped ? [.withSecurityScope] : []
        let url = try URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale)
    }

    /// A fresh bookmark for the resolved URL (used when `resolve()` reported a stale bookmark).
    public func refreshed(for url: URL) throws -> FileBookmark {
        let accessing = securityScoped ? url.startAccessingSecurityScopedResource() : false
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return try FileBookmark.make(for: url, securityScoped: securityScoped)
    }
}

/// A host folder shared into the guest over virtio-fs.
/// Linux guest: `mount -t virtiofs <tag> /mnt/<tag>`. macOS guest: all shares appear under `/Volumes/My Shared Files/<tag>`.
public struct SharedFolder: Codable, Sendable, Hashable {
    public var hostURL: URL
    public var tag: String
    public var readOnly: Bool
    public var bookmark: FileBookmark?

    public init(hostURL: URL, tag: String, readOnly: Bool = false, bookmark: FileBookmark? = nil) {
        self.hostURL = hostURL; self.tag = tag; self.readOnly = readOnly; self.bookmark = bookmark
    }
}

/// Everything needed to (re)build a VM. Stored as `spec.json` in the VM bundle (see `VMStore`).
public struct VMSpec: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var guest: GuestOS
    public var cpuCount: Int
    public var memoryBytes: UInt64
    public var diskBytes: UInt64
    public var display: DisplaySpec
    public var install: InstallSource
    /// Bookmark for the user-selected install media (ISO / IPSW) so it stays reachable across launches.
    public var installBookmark: FileBookmark?
    /// Attach the installer ISO (as a USB stick). Set to false once the guest is installed.
    public var attachInstallMedia: Bool
    public var sharedFolders: [SharedFolder]
    /// Share Rosetta into Linux guests (Apple silicon, when installed) under the tag `rosetta`.
    public var rosetta: Bool
    /// Run without showing a window (the hidden agent view still captures the display).
    public var headless: Bool
    /// Nested virtualization (macOS 15, M3 or later; ignored when unsupported).
    public var nestedVirtualization: Bool
    /// Virtio sound output (host speakers).
    public var audio: Bool
    /// Spice agent clipboard sharing (needs `spice-vdagent` in the guest).
    public var clipboardSharing: Bool
    public var createdAt: Date
    public var notes: String

    public init(id: UUID = UUID(),
                name: String,
                guest: GuestOS = .linux,
                cpuCount: Int = 4,
                memoryBytes: UInt64 = 4 << 30,
                diskBytes: UInt64 = 64 << 30,
                display: DisplaySpec = DisplaySpec(),
                install: InstallSource = .none,
                installBookmark: FileBookmark? = nil,
                attachInstallMedia: Bool = true,
                sharedFolders: [SharedFolder] = [],
                rosetta: Bool = false,
                headless: Bool = false,
                nestedVirtualization: Bool = false,
                audio: Bool = true,
                clipboardSharing: Bool = true,
                createdAt: Date = Date(),
                notes: String = "") {
        self.id = id; self.name = name; self.guest = guest; self.cpuCount = cpuCount; self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes; self.display = display; self.install = install; self.installBookmark = installBookmark
        self.attachInstallMedia = attachInstallMedia; self.sharedFolders = sharedFolders; self.rosetta = rosetta
        self.headless = headless; self.nestedVirtualization = nestedVirtualization; self.audio = audio
        self.clipboardSharing = clipboardSharing; self.createdAt = createdAt; self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, guest, cpuCount, memoryBytes, diskBytes, display, install, installBookmark, attachInstallMedia
        case sharedFolders, rosetta, headless, nestedVirtualization, audio, clipboardSharing, createdAt, notes
    }

    /// Lenient decoding: every field except `id` and `name` has a default, so older spec files keep loading.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        guest = try c.decodeIfPresent(GuestOS.self, forKey: .guest) ?? .linux
        cpuCount = try c.decodeIfPresent(Int.self, forKey: .cpuCount) ?? 4
        memoryBytes = try c.decodeIfPresent(UInt64.self, forKey: .memoryBytes) ?? (4 << 30)
        diskBytes = try c.decodeIfPresent(UInt64.self, forKey: .diskBytes) ?? (64 << 30)
        display = try c.decodeIfPresent(DisplaySpec.self, forKey: .display) ?? DisplaySpec()
        install = try c.decodeIfPresent(InstallSource.self, forKey: .install) ?? .none
        installBookmark = try c.decodeIfPresent(FileBookmark.self, forKey: .installBookmark)
        attachInstallMedia = try c.decodeIfPresent(Bool.self, forKey: .attachInstallMedia) ?? true
        sharedFolders = try c.decodeIfPresent([SharedFolder].self, forKey: .sharedFolders) ?? []
        rosetta = try c.decodeIfPresent(Bool.self, forKey: .rosetta) ?? false
        headless = try c.decodeIfPresent(Bool.self, forKey: .headless) ?? false
        nestedVirtualization = try c.decodeIfPresent(Bool.self, forKey: .nestedVirtualization) ?? false
        audio = try c.decodeIfPresent(Bool.self, forKey: .audio) ?? true
        clipboardSharing = try c.decodeIfPresent(Bool.self, forKey: .clipboardSharing) ?? true
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }

    /// Result of `resolvingBookmarks()`.
    public struct BookmarkResolution: Sendable {
        /// The spec with URLs replaced by the resolved bookmark URLs (and stale bookmarks refreshed).
        public var spec: VMSpec
        /// True when at least one bookmark was refreshed: save the spec again.
        public var changed: Bool
        /// Human-readable problems (bookmark could not be resolved); the old URL is kept in that case.
        public var problems: [String]
    }

    /// Resolves the stored security-scoped bookmarks (install media, shared folders) into usable URLs.
    /// Call it after loading a spec from disk, before building the VM.
    public func resolvingBookmarks() -> BookmarkResolution {
        var out = self
        var changed = false
        var problems: [String] = []

        if let bm = installBookmark {
            do {
                let (url, stale) = try bm.resolve()
                switch install {
                case .iso: out.install = .iso(url)
                case .diskImage: out.install = .diskImage(url)
                case .macOSRestoreImage: out.install = .macOSRestoreImage(url)
                case .none: break
                }
                if stale, let fresh = try? bm.refreshed(for: url) { out.installBookmark = fresh; changed = true }
            } catch {
                problems.append("install media: \(error.localizedDescription)")
            }
        }
        for (i, folder) in sharedFolders.enumerated() {
            guard let bm = folder.bookmark else { continue }
            do {
                let (url, stale) = try bm.resolve()
                out.sharedFolders[i].hostURL = url
                if stale, let fresh = try? bm.refreshed(for: url) { out.sharedFolders[i].bookmark = fresh; changed = true }
            } catch {
                problems.append("shared folder \(folder.tag): \(error.localizedDescription)")
            }
        }
        return BookmarkResolution(spec: out, changed: changed, problems: problems)
    }

    /// The security-scoped URLs this spec needs while the VM runs (keep access open for the VM's lifetime).
    public var securityScopedURLs: [URL] {
        var urls: [URL] = []
        if installBookmark?.securityScoped == true, let u = install.url { urls.append(u) }
        for f in sharedFolders where f.bookmark?.securityScoped == true { urls.append(f.hostURL) }
        return urls
    }
}

/// Keeps `startAccessingSecurityScopedResource()` open for a set of URLs and balances the calls.
public final class SecurityScopedAccess: @unchecked Sendable {
    private let lock = NSLock()
    private var active: [URL] = []

    public init() {}

    /// Starts accessing `url`; returns false when the URL is not security scoped (which is fine outside the sandbox).
    @discardableResult
    public func start(_ url: URL) -> Bool {
        guard url.startAccessingSecurityScopedResource() else { return false }
        lock.lock(); active.append(url); lock.unlock()
        return true
    }

    public func stopAll() {
        lock.lock()
        let urls = active
        active.removeAll()
        lock.unlock()
        for u in urls { u.stopAccessingSecurityScopedResource() }
    }

    deinit { for u in active { u.stopAccessingSecurityScopedResource() } }
}
