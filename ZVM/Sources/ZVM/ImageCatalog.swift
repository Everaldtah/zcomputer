import Foundation
import ZCore

/// A downloadable, ready-to-run Linux disk image (no installer: cloud-init configures it on first boot).
public struct CloudImage: Codable, Sendable, Hashable, Identifiable {
    public enum Format: String, Codable, Sendable, Hashable {
        /// Already a RAW disk: copied (APFS clone) into `disk.img`.
        case raw
        /// qcow2: converted to a sparse RAW `disk.img` by `QCOW2.convertToRaw`.
        case qcow2
    }

    public var id: String
    public var name: String
    public var distribution: String
    public var version: String
    public var architecture: GuestArchitecture
    public var format: Format
    public var url: URL
    /// The distribution's checksum file and the algorithm it uses; the downloaded file name is looked up in it.
    public var checksumsURL: URL?
    public var checksumAlgorithm: Checksums.Algorithm?
    /// Approximate download size (bytes), for the UI.
    public var downloadBytes: Int64
    /// Size of the image's own disk (the VM disk is grown to `VMSpec.diskBytes`).
    public var imageDiskBytes: UInt64
    /// Default user name created by our cloud-init seed.
    public var defaultUser: String
    /// What has and has not been checked (shown to the user / in the report).
    public var notes: String

    public var fileName: String { url.lastPathComponent }
}

/// The built-in image catalogue: Debian 13 and Ubuntu 24.04 LTS cloud images for arm64 and amd64.
///
/// URLs were checked on 2026-10-27 (HTTP 200, sizes below); they are "latest/current" aliases that the projects
/// update in place. Booting them under Virtualization.framework (EFI from the image's ESP, virtio drivers,
/// cloud-init NoCloud from our `cidata` seed) is UNVERIFIED on real hardware.
public enum ImageCatalog {
    public static let all: [CloudImage] = [
        debian(.arm64),
        debian(.x86_64),
        ubuntu(.arm64),
        ubuntu(.x86_64),
    ]

    /// Images that run on this Mac (same architecture as the host).
    public static var forHost: [CloudImage] { all.filter { $0.architecture == .host } }

    public static func image(id: String) -> CloudImage? { all.first { $0.id == id } }

    private static func debian(_ arch: GuestArchitecture) -> CloudImage {
        let file = "debian-13-generic-\(arch.debianName).raw"
        let base = "https://cloud.debian.org/images/cloud/trixie/latest/"
        return CloudImage(
            id: "debian-13-\(arch.debianName)",
            name: "Debian 13 \"trixie\" (\(arch.debianName))",
            distribution: "debian", version: "13", architecture: arch, format: .raw,
            url: url(base + file), checksumsURL: url(base + "SHA512SUMS"), checksumAlgorithm: .sha512,
            downloadBytes: 3_221_225_472, imageDiskBytes: 3_221_225_472, defaultUser: "z",
            notes: "\"generic\" cloud image (full kernel incl. virtio-gpu), RAW, 3 GiB, served via a mirror redirect. "
                + "URL verified 2026-10-27; boot under Virtualization.framework UNVERIFIED.")
    }

    private static func ubuntu(_ arch: GuestArchitecture) -> CloudImage {
        let file = "noble-server-cloudimg-\(arch.debianName).img"
        let base = "https://cloud-images.ubuntu.com/noble/current/"
        return CloudImage(
            id: "ubuntu-24.04-\(arch.debianName)",
            name: "Ubuntu 24.04 LTS (\(arch.debianName))",
            distribution: "ubuntu", version: "24.04", architecture: arch, format: .qcow2,
            url: url(base + file), checksumsURL: url(base + "SHA256SUMS"), checksumAlgorithm: .sha256,
            downloadBytes: arch == .arm64 ? 616_522_752 : 621_284_352, imageDiskBytes: 3_758_096_384, defaultUser: "z",
            notes: "Server cloud image; the .img is compressed qcow2 and is converted to RAW after download. "
                + "URL and size verified 2026-10-27; header (v3, 64 KiB clusters, zlib) and raw-deflate cluster layout "
                + "checked against the real arm64 file; boot under Virtualization.framework UNVERIFIED.")
    }

    private static func url(_ s: String) -> URL {
        // The literals above are valid URLs; fall back to a harmless file URL rather than force-unwrapping.
        URL(string: s) ?? URL(fileURLWithPath: "/dev/null")
    }
}

/// Phases reported while preparing a VM disk from a `CloudImage`.
public enum ImagePreparationPhase: Sendable, Hashable {
    case downloading(DownloadProgress)
    case verifying
    case converting(Double)
    case resizing
    case writingSeed
    case finished
}

/// Downloads a catalogue image (cached, resumable), verifies it, turns it into the VM's `disk.img` (clone or
/// qcow2 conversion), grows it to the spec's size (cloud-init's growpart expands the root partition on first
/// boot) and writes the cloud-init seed.
public enum ImagePreparer {
    /// The download cache: `~/Library/Caches/ZComputer/Images` (inside the container when sandboxed).
    public static func defaultCacheDirectory() throws -> URL {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = caches.appendingPathComponent("ZComputer", isDirectory: true).appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Downloads `image` into `cacheDirectory` (no-op when a verified copy is already there) and returns its path.
    public static func fetch(_ image: CloudImage, cacheDirectory: URL, verify: Bool = true,
                             progress: (@Sendable (ImagePreparationPhase) -> Void)? = nil) async throws -> URL {
        let target = cacheDirectory.appendingPathComponent(image.fileName)
        let verifiedMarker = target.appendingPathExtension("verified")
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path), fm.fileExists(atPath: verifiedMarker.path) || !verify {
            return target
        }
        try await Downloader.download(from: image.url, to: target, sparse: image.format == .raw) { p in
            progress?(.downloading(p))
        }
        if verify, let sumsURL = image.checksumsURL, let algorithm = image.checksumAlgorithm {
            progress?(.verifying)
            let (data, response) = try await URLSession.shared.data(from: sumsURL)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ZError.http(status: http.statusCode, body: "checksum file \(sumsURL.absoluteString)")
            }
            let sums = Checksums.parse(String(decoding: data, as: UTF8.self))
            guard let expected = sums[image.fileName] else {
                throw ZError.vm("\(image.fileName) is not listed in \(sumsURL.lastPathComponent); the image may have been updated, retry")
            }
            let actual = try Checksums.hexDigest(of: target, algorithm: algorithm)
            guard actual == expected else {
                try? fm.removeItem(at: target)
                throw ZError.vm("checksum mismatch for \(image.fileName) (expected \(expected.prefix(16))…, got \(actual.prefix(16))…); the download was deleted")
            }
            _ = fm.createFile(atPath: verifiedMarker.path, contents: Data(expected.utf8))
        }
        return target
    }

    /// Full preparation of `bundle` for `spec` from `image`.
    public static func prepare(_ image: CloudImage, spec: VMSpec, bundle: VMBundle, cacheDirectory: URL,
                               cloudInit: CloudInitConfig?, verify: Bool = true,
                               progress: (@Sendable (ImagePreparationPhase) -> Void)? = nil) async throws {
        guard image.architecture == .host else {
            throw ZError.unsupported("\(image.name) is built for \(image.architecture.rawValue); this Mac runs \(GuestArchitecture.host.rawValue) guests only")
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
