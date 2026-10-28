import Foundation
import ZCore

/// The desktop an image ships or can be given (`images.json` `desktop`: `xfce-x11`, `gnome-wayland`, ...).
public struct DesktopKind: RawRepresentable, Codable, Sendable, Hashable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let xfceX11 = DesktopKind(rawValue: "xfce-x11")
    public static let gnomeWayland = DesktopKind(rawValue: "gnome-wayland")
    public static let cosmicWayland = DesktopKind(rawValue: "cosmic-wayland")
    public static let cinnamonX11 = DesktopKind(rawValue: "cinnamon-x11")

    /// X11 desktops are the only ones the agent can drive with xdotool (research A.7).
    public var isX11: Bool { rawValue.hasSuffix("-x11") }
    public var isWayland: Bool { rawValue.hasSuffix("-wayland") }

    /// "Xfce (X11)", "GNOME (Wayland)", ...
    public var displayName: String {
        let base = rawValue.split(separator: "-").first.map(String.init) ?? rawValue
        let name: String
        switch base {
        case "xfce": name = "Xfce"
        case "gnome": name = "GNOME"
        case "cosmic": name = "COSMIC"
        case "cinnamon": name = "Cinnamon"
        default: name = base.capitalized
        }
        if isX11 { return name + " (X11)" }
        if isWayland { return name + " (Wayland)" }
        return name
    }
}

/// Package manager / init-system family of a distribution, for the cloud-init presets.
public enum DistroFamily: String, Codable, Sendable, Hashable, CaseIterable {
    case debian, ubuntu, fedora
    /// Rocky / AlmaLinux 9 (XFCE from EPEL 9).
    case enterprise9
    /// Rocky / AlmaLinux 10 (no Xorg: terminal only).
    case enterprise10
    case opensuse, arch, alpine, other

    public init(distro: String, version: String) {
        switch distro {
        case "debian", "kali": self = .debian
        case "ubuntu", "linuxmint", "zorin", "popos": self = .ubuntu
        case "fedora": self = .fedora
        case "rocky", "almalinux": self = version.hasPrefix("9") ? .enterprise9 : .enterprise10
        case "opensuse-leap", "opensuse-tumbleweed": self = .opensuse
        case "arch": self = .arch
        case "alpine": self = .alpine
        default: self = .other
        }
    }

    public var packageManager: String {
        switch self {
        case .debian, .ubuntu: return "apt"
        case .fedora, .enterprise9, .enterprise10: return "dnf"
        case .opensuse: return "zypper"
        case .arch: return "pacman"
        case .alpine: return "apk"
        case .other: return "unknown"
        }
    }

    /// Alpine: OpenRC instead of systemd, no bash by default (research A.4.6). Offered as "advanced".
    public var isAdvanced: Bool { self == .alpine || self == .other }
}

/// One entry of the curated image catalogue (`Resources/images.json`, from docs/research/images.md): a ready-to-run
/// cloud image (cloud-init configures it on first boot) or an installer ISO.
public struct CatalogImage: Codable, Sendable, Hashable, Identifiable {
    public enum Group: String, Codable, Sendable, Hashable {
        case cloud, iso
    }

    public enum Format: String, Codable, Sendable, Hashable {
        /// Already a RAW disk: copied (APFS clone) into `disk.img`.
        case raw
        /// qcow2: converted to a sparse RAW `disk.img` by `QCOW2.convertToRaw`.
        case qcow2
        /// An installer ISO, attached as a USB stick.
        case iso
    }

    /// The research's "Recommended" roles.
    public enum Recommendation: String, Codable, Sendable, Hashable, CaseIterable {
        case desktop, terminal, small
    }

    public struct Checksum: Codable, Sendable, Hashable {
        public var algo: Checksums.Algorithm
        /// The value read from the distribution's sums file when the catalogue was built (fallback only: "latest"
        /// aliases are rebuilt in place, so the sums file at `url` wins when it can be read).
        public var value: String
        public var url: URL?
        public var style: Checksums.Style
        /// The name the sums file uses when it differs from the URL's file name (openSUSE `-Current` aliases).
        public var lookupName: String?

        public init(algo: Checksums.Algorithm, value: String, url: URL?, style: Checksums.Style, lookupName: String? = nil) {
            self.algo = algo; self.value = value; self.url = url; self.style = style; self.lookupName = lookupName
        }
    }

    public var id: String
    public var name: String
    public var group: Group
    public var distro: String
    public var version: String
    public var arch: GuestArchitecture
    public var url: URL
    /// Download size in bytes (the server's Content-Length when the catalogue was built).
    public var sizeBytes: Int64
    public var checksum: Checksum
    public var format: Format
    /// The desktop the image ships (ISO) or that our cloud-init recipe can install (cloud).
    public var desktop: DesktopKind?
    public var recommended: Recommendation?
    /// The distribution's default user (our seed creates `z` instead).
    public var cloudUser: String?
    public var notes: [String]
    public var verifiedOn: String?
    /// The research could not show that this image boots under Virtualization.framework (no partition table).
    public var experimental: Bool
    /// On Intel Macs the image's kernel (6.12+, x86 pkeys) needs this macOS version, or `nopku` (lima#3334).
    public var intelMinMacOS: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, group, distro, version, arch, url, sizeBytes, checksum, format, desktop, recommended
        case cloudUser, notes, verifiedOn, experimental, intelMinMacOS
    }

    public init(id: String, name: String, group: Group, distro: String, version: String, arch: GuestArchitecture,
                url: URL, sizeBytes: Int64, checksum: Checksum, format: Format, desktop: DesktopKind? = nil,
                recommended: Recommendation? = nil, cloudUser: String? = nil, notes: [String] = [],
                verifiedOn: String? = nil, experimental: Bool = false, intelMinMacOS: String? = nil) {
        self.id = id; self.name = name; self.group = group; self.distro = distro; self.version = version
        self.arch = arch; self.url = url; self.sizeBytes = sizeBytes; self.checksum = checksum; self.format = format
        self.desktop = desktop; self.recommended = recommended; self.cloudUser = cloudUser; self.notes = notes
        self.verifiedOn = verifiedOn; self.experimental = experimental; self.intelMinMacOS = intelMinMacOS
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        group = try c.decode(Group.self, forKey: .group)
        distro = try c.decode(String.self, forKey: .distro)
        version = try c.decode(String.self, forKey: .version)
        arch = try c.decode(GuestArchitecture.self, forKey: .arch)
        url = try c.decode(URL.self, forKey: .url)
        sizeBytes = try c.decode(Int64.self, forKey: .sizeBytes)
        checksum = try c.decode(Checksum.self, forKey: .checksum)
        format = try c.decode(Format.self, forKey: .format)
        desktop = try c.decodeIfPresent(DesktopKind.self, forKey: .desktop)
        recommended = try c.decodeIfPresent(Recommendation.self, forKey: .recommended)
        cloudUser = try c.decodeIfPresent(String.self, forKey: .cloudUser)
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
        verifiedOn = try c.decodeIfPresent(String.self, forKey: .verifiedOn)
        experimental = try c.decodeIfPresent(Bool.self, forKey: .experimental) ?? false
        intelMinMacOS = try c.decodeIfPresent(String.self, forKey: .intelMinMacOS)
    }

    /// The file name in the download cache (the URL's last component).
    public var fileName: String { url.lastPathComponent }
    public var architecture: GuestArchitecture { arch }
    public var downloadBytes: Int64 { sizeBytes }
    public var isCloudImage: Bool { group == .cloud }
    public var isISO: Bool { group == .iso }
    public var family: DistroFamily { DistroFamily(distro: distro, version: version) }
    /// Alpine (OpenRC, no bash) and unknown families: shown as "advanced".
    public var isAdvanced: Bool { isCloudImage && family.isAdvanced }

    /// True when, on `host`, this image's kernel will not boot under Virtualization.framework without the `nopku`
    /// kernel argument: an Intel Mac on a macOS older than `intelMinMacOS` (research finding 5, lima#3334).
    public func needsNopku(on host: HostProfile) -> Bool {
        guard host.architecture == .x86_64, arch == .x86_64,
              let minimum = intelMinMacOS, let required = HostProfile.Version(string: minimum) else { return false }
        return host.osVersion < required
    }
}

/// Kept for source compatibility: every catalogue entry used to be a cloud image.
public typealias CloudImage = CatalogImage

/// The curated image catalogue, loaded from `Resources/images.json` (71 entries: 33 cloud images, 38 installer
/// ISOs; URLs, sizes and checksums verified 2026-10-27, see docs/research/images.md). Booting them under
/// Virtualization.framework is UNVERIFIED on real hardware unless the research cites lima/UTM evidence.
public enum ImageCatalog {
    private static let loaded: (images: [CatalogImage], error: String?) = loadBundled()

    /// Every entry, in file order.
    public static var all: [CatalogImage] { loaded.images }
    /// Why the bundled catalogue could not be read (nil when it loaded).
    public static var loadError: String? { loaded.error }

    /// What the app says instead of offering a Windows image.
    public static let windowsNote = "Windows can't run here. Apple's Virtualization framework only runs macOS and Linux guests."

    /// Decodes a catalogue file (`images.json` format).
    public static func decode(_ data: Data) throws -> [CatalogImage] {
        try JSONDecoder().decode([CatalogImage].self, from: data)
    }

    private static func loadBundled() -> (images: [CatalogImage], error: String?) {
        guard let url = Bundle.module.url(forResource: "images", withExtension: "json") else {
            return ([], "images.json is missing from the ZVM resource bundle")
        }
        do {
            return (try decode(Data(contentsOf: url)), nil)
        } catch {
            return ([], "images.json could not be read: \(error)")
        }
    }

    /// Images that run on this Mac (same architecture as the host).
    public static var forHost: [CatalogImage] { images(for: .host) }

    /// Entries for one architecture, optionally one group, optionally without the experimental ones.
    public static func images(for arch: GuestArchitecture, group: CatalogImage.Group? = nil,
                              includeExperimental: Bool = true, in catalog: [CatalogImage] = all) -> [CatalogImage] {
        catalog.filter { image in
            image.arch == arch && (group == nil || image.group == group) && (includeExperimental || !image.experimental)
        }
    }

    public static func image(id: String, in catalog: [CatalogImage] = all) -> CatalogImage? {
        catalog.first { $0.id == id }
    }

    /// The research's recommended image for a role (Debian 13 generic desktop, Ubuntu 24.04 server, Ubuntu 24.04 minimal).
    public static func recommended(_ role: CatalogImage.Recommendation, arch: GuestArchitecture = .host,
                                   in catalog: [CatalogImage] = all) -> CatalogImage? {
        catalog.first { $0.recommended == role && $0.arch == arch }
    }
}

/// Phases reported while preparing a VM disk from a `CatalogImage`.
public enum ImagePreparationPhase: Sendable, Hashable {
    case downloading(DownloadProgress)
    case verifying
    /// The download matched the expected checksum.
    case verified(ChecksumExpectation)
    case converting(Double)
    case resizing
    case writingSeed
    case finished
}

/// A downloaded (and normally verified) catalogue image in the cache.
public struct FetchedImage: Sendable, Hashable {
    public var url: URL
    /// How the download was verified (nil when it was already in the cache, or `verify` was false).
    public var checksum: ChecksumExpectation?
    public var wasCached: Bool
}

/// Downloads a catalogue image (cached, resumable), verifies it, turns it into the VM's `disk.img` (clone or
/// qcow2 conversion), grows it to the spec's size (cloud-init's growpart expands the root partition on first
/// boot) and writes the cloud-init seed.
public enum ImagePreparer {
    /// The image cache: `~/Library/Application Support/ZComputer/Images` (inside the container when sandboxed).
    public static func defaultCacheDirectory() throws -> URL {
        try ImageCache.defaultDirectory()
    }

    /// Downloads `image` into `cacheDirectory` and verifies it (no-op when a verified copy is already there).
    /// The expected checksum comes from the distribution's sums file, or from the catalogue when that file cannot
    /// be read (`ChecksumExpectation.source`). Cancelling keeps the partial download for a later resume.
    public static func download(_ image: CatalogImage, cacheDirectory: URL, verify: Bool = true,
                                fetchSums: Checksums.Fetch? = nil,
                                progress: (@Sendable (ImagePreparationPhase) -> Void)? = nil) async throws -> FetchedImage {
        let target = ImageCache.fileURL(for: image, in: cacheDirectory)
        let marker = ImageCache.markerURL(for: target)
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path), fm.fileExists(atPath: marker.path) || !verify {
            return FetchedImage(url: target, checksum: nil, wasCached: true)
        }
        if !fm.fileExists(atPath: target.path) {
            try await Downloader.download(from: image.url, to: target, sparse: image.format == .raw) { p in
                progress?(.downloading(p))
            }
        }
        guard verify else { return FetchedImage(url: target, checksum: nil, wasCached: false) }
        progress?(.verifying)
        let expected = await Checksums.expectation(for: image, fetch: fetchSums ?? Checksums.urlSessionFetch)
        try Task.checkCancellation()
        let actual = try Checksums.hexDigest(of: target, algorithm: expected.algorithm)
        guard actual == expected.hex else {
            try? fm.removeItem(at: target)
            throw ZError.vm("checksum mismatch for \(image.fileName) (\(expected.summary): expected \(expected.hex.prefix(16))…, "
                            + "got \(actual.prefix(16))…); the download was deleted. The mirror may have changed the file "
                            + "during the download: try again.")
        }
        _ = fm.createFile(atPath: marker.path, contents: Data(expected.hex.utf8))
        progress?(.verified(expected))
        return FetchedImage(url: target, checksum: expected, wasCached: false)
    }

    /// Downloads and verifies `image` into `cacheDirectory` and returns its path.
    public static func fetch(_ image: CatalogImage, cacheDirectory: URL, verify: Bool = true,
                             progress: (@Sendable (ImagePreparationPhase) -> Void)? = nil) async throws -> URL {
        try await download(image, cacheDirectory: cacheDirectory, verify: verify, progress: progress).url
    }

    /// Full preparation of `bundle` for `spec` from a cloud image.
    public static func prepare(_ image: CatalogImage, spec: VMSpec, bundle: VMBundle, cacheDirectory: URL,
                               cloudInit: CloudInitConfig?, verify: Bool = true,
                               progress: (@Sendable (ImagePreparationPhase) -> Void)? = nil) async throws {
        guard image.architecture == .host else {
            throw ZError.unsupported("\(image.name) is built for \(image.architecture.rawValue); this Mac runs \(GuestArchitecture.host.rawValue) guests only")
        }
        guard image.isCloudImage else {
            throw ZError.invalidArgument("\(image.name) is an installer ISO: attach it to a VM instead of converting it")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: bundle.root, withIntermediateDirectories: true)
        let source = try await fetch(image, cacheDirectory: cacheDirectory, verify: verify, progress: progress)
        try Task.checkCancellation()

        switch image.format {
        case .raw:
            if fm.fileExists(atPath: bundle.diskURL.path) { try fm.removeItem(at: bundle.diskURL) }
            try fm.copyItem(at: source, to: bundle.diskURL)          // APFS clone: instant, no extra space
        case .qcow2:
            progress?(.converting(0))
            try await Task.detached(priority: .userInitiated) {
                try QCOW2.convertToRaw(source: source, destination: bundle.diskURL) { fraction in
                    progress?(.converting(fraction))
                }
            }.value
        case .iso:
            throw ZError.invalidArgument("\(image.name) is an ISO")
        }

        progress?(.resizing)
        try VMStore.growDisk(at: bundle.diskURL, to: spec.diskBytes)

        if let cloudInit {
            progress?(.writingSeed)
            try CloudInitSeed.write(cloudInit, to: bundle.seedImageURL)
        }
        progress?(.finished)
    }
}

/// A file in the image cache.
public struct CachedImageFile: Sendable, Hashable, Identifiable {
    public var fileName: String
    public var url: URL
    /// Logical size on disk (for a partial download: the bytes received so far).
    public var bytes: Int64
    /// The full size, when known (catalogue size, or the partial download's Content-Length).
    public var expectedBytes: Int64?
    public var verified: Bool
    /// An interrupted or paused download (`<name>.part`).
    public var partial: Bool
    /// The catalogue entry this file belongs to (nil for files the catalogue no longer lists).
    public var imageID: String?

    public var id: String { partial ? fileName + ".part" : fileName }
}

/// The download cache (`Application Support/ZComputer/Images`): `<file>`, `<file>.verified` (expected hex),
/// `<file>.part` + `<file>.part-info` while a download is incomplete.
public enum ImageCache {
    public static func defaultDirectory() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent("ZComputer", isDirectory: true)
            .appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func fileURL(for image: CatalogImage, in directory: URL) -> URL {
        directory.appendingPathComponent(image.fileName)
    }

    public static func markerURL(for file: URL) -> URL { file.appendingPathExtension("verified") }

    /// True when the image is downloaded and its checksum was verified.
    public static func isVerified(_ image: CatalogImage, in directory: URL) -> Bool {
        let file = fileURL(for: image, in: directory)
        let fm = FileManager.default
        return fm.fileExists(atPath: file.path) && fm.fileExists(atPath: markerURL(for: file).path)
    }

    /// Bytes of an interrupted download of `image` (nil when there is none).
    public static func partialBytes(_ image: CatalogImage, in directory: URL) -> Int64? {
        let part = Downloader.partialFileURL(for: fileURL(for: image, in: directory))
        guard let size = try? VMStore.fileSize(part) else { return nil }
        return Int64(size)
    }

    /// Everything in the cache: complete files and partial downloads, matched to the catalogue by file name.
    public static func list(in directory: URL, catalog: [CatalogImage] = ImageCatalog.all) -> [CachedImageFile] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        let byName = Dictionary(catalog.map { ($0.fileName, $0) }, uniquingKeysWith: { first, _ in first })
        var out: [CachedImageFile] = []
        for name in names.sorted() where !name.hasPrefix(".") {
            if name.hasSuffix(".verified") || name.hasSuffix(".part-info") { continue }
            let partial = name.hasSuffix(".part")
            let fileName = partial ? String(name.dropLast(5)) : name
            let url = directory.appendingPathComponent(name)
            let size = (try? VMStore.fileSize(url)).map { Int64($0) } ?? 0
            let image = byName[fileName]
            var expected = image?.sizeBytes
            if partial, let info = Downloader.ResumeInfo.load(Downloader.infoFileURL(for: directory.appendingPathComponent(fileName))),
               let total = info.expectedBytes {
                expected = total
            }
            let verified = !partial && fm.fileExists(atPath: markerURL(for: url).path)
            out.append(CachedImageFile(fileName: fileName, url: url, bytes: size, expectedBytes: expected,
                                       verified: verified, partial: partial, imageID: image?.id))
        }
        return out
    }

    /// Deletes a cached image with its marker and any partial download.
    public static func delete(fileName: String, in directory: URL) throws {
        guard !fileName.isEmpty, !fileName.contains("/"), fileName != ".", fileName != ".." else {
            throw ZError.invalidArgument("bad cache file name \(fileName)")
        }
        let fm = FileManager.default
        let file = directory.appendingPathComponent(fileName)
        for url in [file, markerURL(for: file), Downloader.partialFileURL(for: file), Downloader.infoFileURL(for: file)]
        where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    /// Total bytes of all cached files (complete and partial).
    public static func totalBytes(in directory: URL) -> Int64 {
        list(in: directory, catalog: []).reduce(0) { $0 + $1.bytes }
    }
}
