import Foundation
import ZCore

/// One downloadable file of a catalogue image.
public struct EmuImageFile: Codable, Sendable, Hashable {
    public enum Role: String, Codable, Sendable, Hashable {
        /// Attached as the CD-ROM (v86 `cdrom`).
        case cdrom
        /// Attached as the first hard disk (v86 `hda`).
        case hda
        /// A v86 saved state taken with the image's hda (instant start).
        case state
    }

    public enum Compression: String, Codable, Sendable, Hashable {
        case none
        /// `.xz` (LZMA2), decompressed with Apple's Compression framework (`COMPRESSION_LZMA`).
        case xz
    }

    public var role: Role
    /// File name of the download.
    public var name: String
    public var url: URL
    public var sizeBytes: Int64?
    /// sha256 (lowercase hex) of the downloaded file.
    public var sha256: String?
    public var compression: Compression
    public var decompressedBytes: Int64?
    public var decompressedSha256: String?

    public init(role: Role, name: String, url: URL, sizeBytes: Int64? = nil, sha256: String? = nil,
                compression: Compression = .none, decompressedBytes: Int64? = nil, decompressedSha256: String? = nil) {
        self.role = role; self.name = name; self.url = url; self.sizeBytes = sizeBytes; self.sha256 = sha256
        self.compression = compression; self.decompressedBytes = decompressedBytes; self.decompressedSha256 = decompressedSha256
    }

    /// Name of the file on disk after decompression.
    public var localName: String {
        if compression == .xz, name.lowercased().hasSuffix(".xz") { return String(name.dropLast(3)) }
        return name
    }

    private enum CodingKeys: String, CodingKey {
        case role, name, url, sizeBytes, sha256, compression, decompressedBytes, decompressedSha256
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(Role.self, forKey: .role)
        url = try c.decode(URL.self, forKey: .url)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? url.lastPathComponent
        sizeBytes = try c.decodeIfPresent(Int64.self, forKey: .sizeBytes)
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256)?.lowercased()
        compression = try c.decodeIfPresent(Compression.self, forKey: .compression) ?? .none
        decompressedBytes = try c.decodeIfPresent(Int64.self, forKey: .decompressedBytes)
        decompressedSha256 = try c.decodeIfPresent(String.self, forKey: .decompressedSha256)?.lowercased()
    }
}

/// A machine image the app offers: an ISO, a disk, or a disk plus a saved state ("instant start").
public struct EmuImage: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable {
        /// A ready-made disk with a saved state: resumes straight at the desktop.
        case instantStart
        /// An installer / live CD image.
        case iso
        /// A disk image that cold-boots.
        case disk
    }

    public var id: String
    public var name: String
    public var summary: String
    public var kind: Kind
    public var arch: String
    public var recommended: Bool
    public var defaultMemoryMB: Int
    public var vgaMemoryMB: Int
    public var screen: PixelSize?
    /// The files; empty for a manifest-described image until `EmuImageCatalog.resolve` fills them.
    public var files: [EmuImageFile]
    /// A `manifest.json` (tools/images/x86/manifest.mjs schema) that describes the files.
    public var manifestURL: URL?
    public var manifestImageID: String?
    /// The manifest's build version, once resolved.
    public var version: String?
    public var serialLogin: EmuCredentials?
    public var bootAssist: EmuBootAssist?
    public var network: EmuNetwork
    public var nic: EmuNIC
    public var acpi: Bool
    public var enable9p: Bool
    /// The v86 commit a saved state needs (must equal `EmuResources.v86Commit`).
    public var emulatorCommit: String?
    public var homepage: URL?
    public var license: String?
    public var notes: [String]

    public init(id: String, name: String, summary: String = "", kind: Kind, arch: String = "x86", recommended: Bool = false,
                defaultMemoryMB: Int = 512, vgaMemoryMB: Int = 8, screen: PixelSize? = nil, files: [EmuImageFile] = [],
                manifestURL: URL? = nil, manifestImageID: String? = nil, version: String? = nil,
                serialLogin: EmuCredentials? = nil, bootAssist: EmuBootAssist? = nil, network: EmuNetwork = .fetch,
                nic: EmuNIC = .virtio, acpi: Bool = false, enable9p: Bool = true, emulatorCommit: String? = nil,
                homepage: URL? = nil, license: String? = nil, notes: [String] = []) {
        self.id = id; self.name = name; self.summary = summary; self.kind = kind; self.arch = arch
        self.recommended = recommended; self.defaultMemoryMB = defaultMemoryMB; self.vgaMemoryMB = vgaMemoryMB
        self.screen = screen; self.files = files; self.manifestURL = manifestURL; self.manifestImageID = manifestImageID
        self.version = version; self.serialLogin = serialLogin; self.bootAssist = bootAssist; self.network = network
        self.nic = nic; self.acpi = acpi; self.enable9p = enable9p; self.emulatorCommit = emulatorCommit
        self.homepage = homepage; self.license = license; self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, summary, kind, arch, recommended, defaultMemoryMB, vgaMemoryMB, screen, files, manifestURL
        case manifestImageID, version, serialLogin, bootAssist, network, nic, acpi, enable9p, emulatorCommit, homepage
        case license, notes
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        kind = try c.decode(Kind.self, forKey: .kind)
        arch = try c.decodeIfPresent(String.self, forKey: .arch) ?? "x86"
        recommended = try c.decodeIfPresent(Bool.self, forKey: .recommended) ?? false
        defaultMemoryMB = try c.decodeIfPresent(Int.self, forKey: .defaultMemoryMB) ?? 512
        vgaMemoryMB = try c.decodeIfPresent(Int.self, forKey: .vgaMemoryMB) ?? 8
        screen = try c.decodeIfPresent(PixelSize.self, forKey: .screen)
        files = try c.decodeIfPresent([EmuImageFile].self, forKey: .files) ?? []
        manifestURL = try c.decodeIfPresent(URL.self, forKey: .manifestURL)
        manifestImageID = try c.decodeIfPresent(String.self, forKey: .manifestImageID)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        serialLogin = try c.decodeIfPresent(EmuCredentials.self, forKey: .serialLogin)
        bootAssist = try c.decodeIfPresent(EmuBootAssist.self, forKey: .bootAssist)
        network = try c.decodeIfPresent(EmuNetwork.self, forKey: .network) ?? .fetch
        nic = try c.decodeIfPresent(EmuNIC.self, forKey: .nic) ?? .virtio
        acpi = try c.decodeIfPresent(Bool.self, forKey: .acpi) ?? false
        enable9p = try c.decodeIfPresent(Bool.self, forKey: .enable9p) ?? true
        emulatorCommit = try c.decodeIfPresent(String.self, forKey: .emulatorCommit)
        homepage = try c.decodeIfPresent(URL.self, forKey: .homepage)
        license = try c.decodeIfPresent(String.self, forKey: .license)
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
    }

    /// Total download size, when every file's size is known.
    public var downloadBytes: Int64? {
        guard !files.isEmpty else { return nil }
        var total: Int64 = 0
        for f in files {
            guard let s = f.sizeBytes else { return nil }
            total += s
        }
        return total
    }

    /// True when the files are known (a manifest image needs `EmuImageCatalog.resolve` first).
    public var isResolved: Bool { !files.isEmpty }

    public func file(_ role: EmuImageFile.Role) -> EmuImageFile? { files.first { $0.role == role } }
}

/// The data-driven image catalogue (`Resources/images-x86.json`).
public struct EmuImageCatalog: Codable, Sendable, Hashable {
    public var version: Int
    public var images: [EmuImage]

    public init(version: Int = 1, images: [EmuImage]) {
        self.version = version
        self.images = images
    }

    /// The catalogue bundled with ZEmu.
    public static func bundled() throws -> EmuImageCatalog {
        guard let url = EmuResources.root?.appendingPathComponent("images-x86.json") else {
            throw ZError.notFound("images-x86.json")
        }
        return try decode(Data(contentsOf: url))
    }

    public static func decode(_ data: Data) throws -> EmuImageCatalog {
        do { return try JSONDecoder().decode(EmuImageCatalog.self, from: data) } catch {
            throw ZError.decoding("image catalogue: \(error)")
        }
    }

    public func image(id: String) -> EmuImage? { images.first { $0.id == id } }

    /// Checks the catalogue: unique ids, files with https URLs and sha256s, roles that fit the kind. Returns problems.
    public func validate() -> [String] {
        var problems: [String] = []
        var seen = Set<String>()
        for image in images {
            if !seen.insert(image.id).inserted { problems.append("\(image.id): duplicate id") }
            if image.files.isEmpty && image.manifestURL == nil { problems.append("\(image.id): no files and no manifest") }
            for f in image.files {
                if f.url.scheme != "https" { problems.append("\(image.id): \(f.name) is not https") }
                if (f.sha256 ?? "").count != 64 { problems.append("\(image.id): \(f.name) has no sha256") }
                if f.sizeBytes == nil { problems.append("\(image.id): \(f.name) has no size") }
            }
            let roles = Set(image.files.map(\.role))
            switch image.kind {
            case .iso where !image.files.isEmpty && !roles.contains(.cdrom): problems.append("\(image.id): ISO without a cdrom file")
            case .disk where !image.files.isEmpty && !roles.contains(.hda): problems.append("\(image.id): disk without an hda file")
            case .instantStart where !image.files.isEmpty && !(roles.contains(.hda) && roles.contains(.state)):
                problems.append("\(image.id): instant start needs hda and state files")
            default: break
            }
        }
        return problems
    }

    // MARK: Manifests

    /// Fetches the image's `manifest.json` and fills in its files (no-op for images without a manifest).
    public static func resolve(_ image: EmuImage, session: URLSession = .shared) async throws -> EmuImage {
        guard let url = image.manifestURL else { return image }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ZError.http(status: http.statusCode, body: "manifest \(url.absoluteString) is not available")
        }
        return try apply(manifest: data, to: image)
    }

    /// Fills `image` from a manifest (pure; tested). A state built with a different v86 commit than the vendored one
    /// cannot be restored, so the image then falls back to a cold-booting disk.
    public static func apply(manifest data: Data, to image: EmuImage, v86Commit: String? = EmuResources.v86Commit) throws -> EmuImage {
        let manifest: Manifest
        do { manifest = try JSONDecoder().decode(Manifest.self, from: data) } catch {
            throw ZError.decoding("manifest: \(error)")
        }
        let wanted = image.manifestImageID ?? image.id
        guard let entry = manifest.images.first(where: { $0.id == wanted }) else {
            throw ZError.notFound("image \(wanted) in the manifest")
        }
        var out = image
        out.version = manifest.version
        out.defaultMemoryMB = entry.memoryMB ?? out.defaultMemoryMB
        out.vgaMemoryMB = entry.vgaMemoryMB ?? out.vgaMemoryMB
        if let s = entry.screen { out.screen = PixelSize(width: s.w, height: s.h) }
        if let user = entry.user { out.serialLogin = EmuCredentials(user: user, password: entry.password) }
        let commit = entry.emulator?.commit
        out.emulatorCommit = commit ?? out.emulatorCommit
        var files: [EmuImageFile] = []
        if let img = entry.files["img"] { files.append(img.file(role: .hda, base: manifest.baseUrl)) }
        let stateUsable = commit == nil || v86Commit == nil || commit == v86Commit
        if let state = entry.files["state"], stateUsable { files.append(state.file(role: .state, base: manifest.baseUrl)) }
        guard files.contains(where: { $0.role == .hda }) else { throw ZError.decoding("manifest: \(wanted) has no img file") }
        out.files = files
        out.kind = files.contains(where: { $0.role == .state }) ? .instantStart : .disk
        if !stateUsable {
            out.notes.append("The saved state needs v86 \(commit ?? "?"); this build has \(v86Commit ?? "?"), so the disk cold-boots.")
        }
        return out
    }

    /// Makes a machine spec for a prepared image. Instant-start images use the image's memory size (a state only
    /// restores into the same hardware); others use `memoryMB` or the image default.
    public static func makeSpec(for image: EmuImage, prepared: EmuPreparedImage, name: String, memoryMB: Int? = nil,
                                id: UUID = UUID()) throws -> EmuSpec {
        let boot: EmuBootMedia
        var memory = memoryMB ?? image.defaultMemoryMB
        var cdrom: URL?
        switch image.kind {
        case .instantStart:
            guard let state = prepared.state, let disk = prepared.hda else { throw ZError.notFound("\(image.id): state or disk") }
            boot = .state(state, disk: disk)
            memory = image.defaultMemoryMB
            cdrom = prepared.cdrom
        case .iso:
            guard let iso = prepared.cdrom else { throw ZError.notFound("\(image.id): ISO") }
            boot = .iso(iso)
        case .disk:
            guard let disk = prepared.hda else { throw ZError.notFound("\(image.id): disk") }
            boot = .disk(disk)
            cdrom = prepared.cdrom
        }
        return EmuSpec(id: id, name: name, memoryMB: memory, vgaMemoryMB: image.vgaMemoryMB,
                       screen: image.screen ?? PixelSize(width: 1024, height: 768), boot: boot, cdrom: cdrom,
                       hda: image.kind == .iso ? prepared.hda : nil, enable9p: image.enable9p, serial: true,
                       network: image.network, nic: image.nic, acpi: image.acpi, fastBoot: true,
                       preserveMACFromState: true, serialLogin: image.serialLogin, bootAssist: image.bootAssist,
                       imageID: image.id)
    }

    // manifest.json of tools/images/x86/manifest.mjs
    struct Manifest: Decodable {
        var version: String?
        var baseUrl: String?
        var images: [Entry]

        struct Entry: Decodable {
            var id: String
            var files: [String: ManifestFile]
            var memoryMB: Int?
            var vgaMemoryMB: Int?
            var screen: Screen?
            var user: String?
            var password: String?
            var emulator: Emulator?
        }

        struct Screen: Decodable { var w: Int; var h: Int }
        struct Emulator: Decodable { var commit: String? }
    }

    struct ManifestFile: Decodable {
        var name: String
        var url: String?
        var compression: String?
        var sizeBytes: Int64?
        var sha256: String?
        var decompressedBytes: Int64?
        var decompressedSha256: String?

        func file(role: EmuImageFile.Role, base: String?) -> EmuImageFile {
            let resolved = url.flatMap(URL.init(string:)) ?? URL(string: (base ?? "") + name) ?? URL(fileURLWithPath: name)
            return EmuImageFile(role: role, name: name, url: resolved, sizeBytes: sizeBytes, sha256: sha256?.lowercased(),
                                compression: compression == "xz" ? .xz : .none, decompressedBytes: decompressedBytes,
                                decompressedSha256: decompressedSha256?.lowercased())
        }
    }
}
