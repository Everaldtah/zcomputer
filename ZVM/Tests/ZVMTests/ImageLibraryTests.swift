import Foundation
import XCTest
import ZCore
@testable import ZVM

final class ImageCatalogTests: XCTestCase {
    func testBundledCatalogLoads() {
        XCTAssertNil(ImageCatalog.loadError)
        let all = ImageCatalog.all
        XCTAssertEqual(all.count, 71)
        XCTAssertEqual(all.filter { $0.group == .cloud }.count, 33)
        XCTAssertEqual(all.filter { $0.group == .iso }.count, 38)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        XCTAssertEqual(Set(all.map(\.fileName)).count, all.count, "cache file names must be unique")
        for image in all {
            XCTAssertEqual(image.url.scheme, "https", image.id)
            XCTAssertGreaterThan(image.sizeBytes, 50_000_000, image.id)
            XCTAssertEqual(image.checksum.value.count, image.checksum.algo.hexLength, image.id)
            XCTAssertTrue(Checksums.isHex(image.checksum.value), image.id)
            XCTAssertEqual(image.checksum.url?.scheme, "https", image.id)
            XCTAssertFalse(image.name.isEmpty, image.id)
            XCTAssertEqual(image.format == .iso, image.group == .iso, image.id)
        }
    }

    func testRecommendedSet() {
        for arch in GuestArchitecture.allCases {
            XCTAssertEqual(ImageCatalog.recommended(.desktop, arch: arch)?.id, "debian-13-generic-\(arch.rawValue)")
            XCTAssertEqual(ImageCatalog.recommended(.terminal, arch: arch)?.id, "ubuntu-24.04-server-\(arch.rawValue)")
            XCTAssertEqual(ImageCatalog.recommended(.small, arch: arch)?.id, "ubuntu-24.04-minimal-\(arch.rawValue)")
        }
        XCTAssertEqual(ImageCatalog.all.filter { $0.recommended != nil }.count, 6)
    }

    func testArchitectureFilter() {
        let arm = ImageCatalog.images(for: .arm64)
        let intel = ImageCatalog.images(for: .x86_64)
        XCTAssertEqual(arm.count, 35)
        XCTAssertEqual(intel.count, 36)
        XCTAssertTrue(arm.allSatisfy { $0.arch == .arm64 })
        XCTAssertTrue(intel.allSatisfy { $0.arch == .x86_64 })
        XCTAssertTrue(ImageCatalog.forHost.allSatisfy { $0.arch == .host })
        XCTAssertEqual(ImageCatalog.images(for: .arm64, group: .cloud).count, 16)
        XCTAssertEqual(ImageCatalog.images(for: .arm64, group: .iso).count, 19)
        XCTAssertEqual(ImageCatalog.images(for: .arm64, group: .iso, includeExperimental: false).count, 15)
        // Arch Linux, Mint and Zorin have no arm64 builds.
        XCTAssertFalse(arm.contains { ["arch", "linuxmint", "zorin"].contains($0.distro) })
    }

    func testResearchFindingsAreInTheData() throws {
        let debian = try XCTUnwrap(ImageCatalog.image(id: "debian-13-generic-arm64"))
        XCTAssertEqual(debian.format, .qcow2)                // 432 MB instead of the 3.22 GB raw
        XCTAssertEqual(debian.fileName, "debian-13-generic-arm64.qcow2")
        XCTAssertEqual(debian.checksum.algo, .sha512)
        XCTAssertEqual(debian.desktop, DesktopKind.xfceX11)
        XCTAssertEqual(debian.family, .debian)
        // Debian genericcloud kernels have no DRM, HID or USB: never a desktop.
        for image in ImageCatalog.all where image.id.hasPrefix("debian-13-genericcloud") {
            XCTAssertNil(image.desktop, image.id)
        }
        XCTAssertEqual(Set(ImageCatalog.all.filter(\.experimental).map(\.id)),
                       ["nixos-26.05-minimal-arm64-iso", "rocky-10-minimal-arm64-iso", "rocky-10-dvd-arm64-iso",
                        "popos-24.04-generic-arm64-iso"])
        XCTAssertEqual(ImageCatalog.image(id: "opensuse-tumbleweed-dvd-arm64-iso")?.checksum.lookupName,
                       "openSUSE-Tumbleweed-DVD-aarch64-Snapshot20261020-Media.iso")
        XCTAssertEqual(ImageCatalog.image(id: "popos-24.04-generic-x86_64-iso")?.checksum.style, .apiJSON)
        XCTAssertEqual(ImageCatalog.image(id: "fedora-44-cloud-arm64")?.checksum.style, .bsd)
        XCTAssertEqual(ImageCatalog.image(id: "alpine-3.24.3-cloudinit-arm64")?.checksum.style, .bare)
        XCTAssertEqual(ImageCatalog.image(id: "alpine-3.24.3-cloudinit-arm64")?.isAdvanced, true)
        XCTAssertEqual(ImageCatalog.image(id: "debian-13-generic-x86_64")?.intelMinMacOS, "15.5")
        XCTAssertNil(ImageCatalog.image(id: "ubuntu-24.04-server-x86_64")?.intelMinMacOS)
        XCTAssertEqual(ImageCatalog.image(id: "rocky-10-genericcloud-arm64")?.family, .enterprise10)
        XCTAssertEqual(ImageCatalog.image(id: "rocky-9-genericcloud-arm64")?.family, .enterprise9)
        XCTAssertEqual(DesktopKind.gnomeWayland.displayName, "GNOME (Wayland)")
        XCTAssertTrue(DesktopKind.xfceX11.isX11)
    }

    func testDecodingDefaults() throws {
        let json = """
            [{"id": "x", "name": "X", "group": "cloud", "distro": "debian", "version": "13", "arch": "arm64",
              "url": "https://example.com/x.qcow2", "sizeBytes": 1, "format": "qcow2",
              "checksum": {"algo": "sha256", "value": "00", "url": "https://example.com/SUMS", "style": "gnu"}}]
            """
        let images = try ImageCatalog.decode(Data(json.utf8))
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.experimental, false)
        XCTAssertNil(images.first?.desktop)
        XCTAssertEqual(images.first?.notes, [])
    }
}

final class ChecksumStyleTests: XCTestCase {
    let hash256 = String(repeating: "ab", count: 32)
    let other256 = String(repeating: "cd", count: 32)
    let hash512 = String(repeating: "0f", count: 64)

    func testGNUStyle() {
        let text = Data("\(other256)  noble-server-cloudimg-amd64.img\n\(hash256) *noble-server-cloudimg-arm64.img\n".utf8)
        XCTAssertEqual(Checksums.expectedHash(in: text, style: .gnu, fileName: "noble-server-cloudimg-arm64.img",
                                              algorithm: .sha256), hash256)
        XCTAssertNil(Checksums.expectedHash(in: text, style: .gnu, fileName: "missing.img", algorithm: .sha256))
        // A digest of the wrong length for the algorithm never matches.
        XCTAssertNil(Checksums.expectedHash(in: text, style: .gnu, fileName: "noble-server-cloudimg-arm64.img",
                                            algorithm: .sha512))
    }

    func testBSDStyleInsideAPGPClearSignedFile() {
        let text = """
            -----BEGIN PGP SIGNED MESSAGE-----
            Hash: SHA256

            # Fedora-Cloud-Base-Generic-44-1.7.aarch64.qcow2: 528154624 bytes
            SHA256 (Fedora-Cloud-Base-Generic-44-1.7.aarch64.qcow2) = \(hash256.uppercased())
            # Fedora-Cloud-Base-Generic-44-1.7.aarch64.raw.xz: 400000000 bytes
            SHA256 (Fedora-Cloud-Base-Generic-44-1.7.aarch64.raw.xz) = \(other256)
            -----BEGIN PGP SIGNATURE-----

            iQIzBAEBCAAdFiEEabcdefabcdefabcdefabcdefabcdefabcdefabcd
            =abcd
            -----END PGP SIGNATURE-----
            """
        let entries = Checksums.entries(in: text)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Checksums.expectedHash(in: Data(text.utf8), style: .bsd,
                                              fileName: "Fedora-Cloud-Base-Generic-44-1.7.aarch64.qcow2",
                                              algorithm: .sha256), hash256)
        let rocky = Checksums.parse("SHA256 (Rocky-10-GenericCloud-Base.latest.aarch64.qcow2) = \(hash256)")
        XCTAssertEqual(rocky["Rocky-10-GenericCloud-Base.latest.aarch64.qcow2"], hash256)
    }

    func testBareHash() {
        let text = Data("\(hash512)\n".utf8)
        XCTAssertEqual(Checksums.expectedHash(in: text, style: .bare, fileName: "alpine-3.24.3-aarch64-cloudinit-r0.qcow2",
                                              algorithm: .sha512), hash512)
        XCTAssertNil(Checksums.expectedHash(in: Data("not a hash\n".utf8), style: .bare, fileName: "a", algorithm: .sha512))
    }

    func testOpenSUSESnapshotNaming() {
        let dvd = "openSUSE-Tumbleweed-DVD-aarch64-Snapshot20261020-Media.iso"
        let text = Data("\(hash256)  \(dvd)\n\(other256)  openSUSE-Tumbleweed-NET-aarch64-Snapshot20261020-Media.iso\n".utf8)
        // By the catalogue's lookup name...
        XCTAssertEqual(Checksums.expectedHash(in: text, style: .gnu, fileName: "openSUSE-Tumbleweed-DVD-aarch64-Current.iso",
                                              lookupName: dvd, algorithm: .sha256), hash256)
        // ...and by the -Current → -Snapshot…-Media alias when the snapshot has moved on.
        XCTAssertEqual(Checksums.expectedHash(in: text, style: .gnu, fileName: "openSUSE-Tumbleweed-DVD-aarch64-Current.iso",
                                              lookupName: "openSUSE-Tumbleweed-DVD-aarch64-Snapshot20250101-Media.iso",
                                              algorithm: .sha256), hash256)
        // A single-entry file is taken whatever it names.
        let single = Data("\(other256)  openSUSE-Tumbleweed-Minimal-VM.x86_64-Cloud-Snapshot20261025.qcow2\n".utf8)
        XCTAssertEqual(Checksums.expectedHash(in: single, style: .gnu, fileName: "openSUSE-Tumbleweed-Minimal-VM.x86_64-Cloud.qcow2",
                                              algorithm: .sha256), other256)
    }

    func testAPIJSON() {
        let json = Data(#"{"build": "3", "sha_sum": "\#(hash256.uppercased())", "url": "https://iso.pop-os.org/x.iso"}"#.utf8)
        XCTAssertEqual(Checksums.expectedHash(in: json, style: .apiJSON, fileName: "x.iso", algorithm: .sha256), hash256)
        XCTAssertNil(Checksums.expectedHash(in: Data("{}".utf8), style: .apiJSON, fileName: "x.iso", algorithm: .sha256))
    }

    func testExpectationPrefersTheSumsFileAndFallsBackToTheCatalogue() async throws {
        let image = try XCTUnwrap(ImageCatalog.image(id: "fedora-44-cloud-arm64"))
        let offline = await Checksums.expectation(for: image, fetch: { _ in throw URLError(.notConnectedToInternet) })
        XCTAssertEqual(offline.hex, image.checksum.value)
        guard case .catalogue = offline.source else { return XCTFail("expected the catalogue value") }

        let fresh = String(repeating: "12", count: 32)
        let name = image.fileName
        let online = await Checksums.expectation(for: image, fetch: { _ in Data("SHA256 (\(name)) = \(fresh)\n".utf8) })
        XCTAssertEqual(online.hex, fresh)
        guard case .sumsFile = online.source else { return XCTFail("expected the sums file") }
        XCTAssertTrue(online.summary.hasPrefix("SHA-256 from "))

        let unlisted = await Checksums.expectation(for: image, fetch: { _ in
            Data("SHA256 (a.qcow2) = \(fresh)\nSHA256 (b.qcow2) = \(fresh)\n".utf8)
        })
        XCTAssertEqual(unlisted.hex, image.checksum.value)
        guard case .catalogue = unlisted.source else { return XCTFail("expected the catalogue value") }
    }

    func testDownloadVerifiesAnAlreadyPresentFile() async throws {
        let dir = try makeTemporaryDirectory("zvm-verify")
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = Data("disk image bytes".utf8)
        let digest = Checksums.hexDigest(of: content, algorithm: .sha256)
        let url = try XCTUnwrap(URL(string: "https://example.invalid/images/test.qcow2"))
        let sums = try XCTUnwrap(URL(string: "https://example.invalid/images/SHA256SUMS"))
        let image = CatalogImage(id: "test", name: "Test", group: .cloud, distro: "debian", version: "13", arch: .host,
                                 url: url, sizeBytes: Int64(content.count),
                                 checksum: .init(algo: .sha256, value: String(repeating: "0", count: 64), url: sums, style: .gnu),
                                 format: .qcow2)
        try content.write(to: ImageCache.fileURL(for: image, in: dir))

        let fetched = try await ImagePreparer.download(image, cacheDirectory: dir, fetchSums: { _ in
            Data("\(digest)  test.qcow2\n".utf8)
        })
        XCTAssertFalse(fetched.wasCached)
        XCTAssertEqual(fetched.checksum?.hex, digest)
        XCTAssertTrue(ImageCache.isVerified(image, in: dir))
        let again = try await ImagePreparer.download(image, cacheDirectory: dir)
        XCTAssertTrue(again.wasCached)

        // A mismatch deletes the file.
        try ImageCache.delete(fileName: image.fileName, in: dir)
        try content.write(to: ImageCache.fileURL(for: image, in: dir))
        do {
            _ = try await ImagePreparer.download(image, cacheDirectory: dir, fetchSums: { _ in
                Data("\(String(repeating: "9", count: 64))  test.qcow2\n".utf8)
            })
            XCTFail("expected a checksum mismatch")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: ImageCache.fileURL(for: image, in: dir).path))
        }
    }

    func testCacheListing() throws {
        let dir = try makeTemporaryDirectory("zvm-cache")
        defer { try? FileManager.default.removeItem(at: dir) }
        let debian = try XCTUnwrap(ImageCatalog.image(id: "debian-13-generic-arm64"))
        let ubuntu = try XCTUnwrap(ImageCatalog.image(id: "ubuntu-24.04-minimal-arm64"))
        let file = ImageCache.fileURL(for: debian, in: dir)
        try Data(repeating: 1, count: 10).write(to: file)
        try Data("x".utf8).write(to: ImageCache.markerURL(for: file))
        try Data(repeating: 2, count: 4).write(to: Downloader.partialFileURL(for: ImageCache.fileURL(for: ubuntu, in: dir)))
        try Data("junk".utf8).write(to: dir.appendingPathComponent("unknown.img"))

        let listed = ImageCache.list(in: dir)
        XCTAssertEqual(listed.count, 3)
        let complete = try XCTUnwrap(listed.first { $0.imageID == debian.id })
        XCTAssertTrue(complete.verified)
        XCTAssertFalse(complete.partial)
        XCTAssertEqual(complete.bytes, 10)
        let partial = try XCTUnwrap(listed.first { $0.imageID == ubuntu.id })
        XCTAssertTrue(partial.partial)
        XCTAssertEqual(partial.bytes, 4)
        XCTAssertEqual(partial.expectedBytes, ubuntu.sizeBytes)
        XCTAssertEqual(ImageCache.partialBytes(ubuntu, in: dir), 4)
        XCTAssertNil(listed.first { $0.fileName == "unknown.img" }?.imageID)

        try ImageCache.delete(fileName: debian.fileName, in: dir)
        try ImageCache.delete(fileName: ubuntu.fileName, in: dir)
        XCTAssertEqual(ImageCache.list(in: dir).map(\.fileName), ["unknown.img"])
        XCTAssertThrowsError(try ImageCache.delete(fileName: "../x", in: dir))
    }
}
