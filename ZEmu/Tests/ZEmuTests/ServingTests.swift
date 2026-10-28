import Foundation
import WebKit
import XCTest
import ZCore
@testable import ZEmu

final class RangeTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(EmuByteRange.parse(nil, size: 100), .full)
        XCTAssertEqual(EmuByteRange.parse("bytes=0-9", size: 100), .partial(start: 0, end: 9))
        XCTAssertEqual(EmuByteRange.parse("bytes=90-", size: 100), .partial(start: 90, end: 99))
        XCTAssertEqual(EmuByteRange.parse("bytes=-10", size: 100), .partial(start: 90, end: 99))
        XCTAssertEqual(EmuByteRange.parse("bytes=-500", size: 100), .partial(start: 0, end: 99))
        XCTAssertEqual(EmuByteRange.parse("bytes=95-200", size: 100), .partial(start: 95, end: 99))
        XCTAssertEqual(EmuByteRange.parse("Bytes = 3-4", size: 100), .full, "malformed: ignored")
        XCTAssertEqual(EmuByteRange.parse("bytes=100-", size: 100), .unsatisfiable)
        XCTAssertEqual(EmuByteRange.parse("bytes=5-2", size: 100), .full)
        XCTAssertEqual(EmuByteRange.parse("items=0-1", size: 100), .full)
        XCTAssertEqual(EmuByteRange.parse("bytes=0-1,5-6", size: 100), .partial(start: 0, end: 1))
        XCTAssertEqual(EmuByteRange.parse("bytes=0-", size: 0), .unsatisfiable)
        XCTAssertEqual(EmuByteRange.parse("bytes=-5", size: 0), .unsatisfiable)
        // Multi-GB images: offsets beyond 32 bits.
        let big: UInt64 = 6 << 30
        XCTAssertEqual(EmuByteRange.parse("bytes=5368709120-5368713215", size: big), .partial(start: 5_368_709_120, end: 5_368_713_215))
    }

    func testResponseHeads() {
        let partial = EmuFileResponse.make(method: "GET", rangeHeader: "bytes=10-19", fileSize: 100, contentType: "application/octet-stream")
        XCTAssertEqual(partial.status, 206)
        XCTAssertEqual(partial.headers["Content-Range"], "bytes 10-19/100")
        XCTAssertEqual(partial.headers["Content-Length"], "10")
        XCTAssertEqual(partial.headers["Accept-Ranges"], "bytes")
        XCTAssertEqual(partial.offset, 10)
        XCTAssertEqual(partial.length, 10)

        let whole = EmuFileResponse.make(method: "GET", rangeHeader: nil, fileSize: 100, contentType: "x")
        XCTAssertEqual(whole.status, 200)
        XCTAssertEqual(whole.length, 100)

        let head = EmuFileResponse.make(method: "HEAD", rangeHeader: nil, fileSize: 100, contentType: "x")
        XCTAssertEqual(head.status, 200)
        XCTAssertEqual(head.headers["Content-Length"], "100")
        XCTAssertEqual(head.length, 0)

        let bad = EmuFileResponse.make(method: "GET", rangeHeader: "bytes=200-300", fileSize: 100, contentType: "x")
        XCTAssertEqual(bad.status, 416)
        XCTAssertEqual(bad.headers["Content-Range"], "bytes */100")
        XCTAssertEqual(bad.length, 0)

        XCTAssertEqual(EmuFileResponse.contentType(forExtension: "wasm"), "application/wasm")
        XCTAssertEqual(EmuFileResponse.contentType(forExtension: "JS"), "text/javascript; charset=utf-8")
        XCTAssertEqual(EmuFileResponse.contentType(forExtension: "iso"), "application/octet-stream")
    }

    func testReadingRangesOfAFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zemu-range-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = (0..<1024).map { UInt8($0 & 0xFF) }
        try Data(bytes).write(to: url)
        XCTAssertEqual(try EmuFileReader.read(url, offset: 300, count: 4), Data([44, 45, 46, 47]))
        XCTAssertEqual(try EmuFileReader.read(url, offset: 1020, count: 100), Data([252, 253, 254, 255]), "short at the end")
        XCTAssertEqual(try EmuFileReader.read(url, offset: 0, count: 0), Data())
        let chunks = EmuFileReader.chunks(offset: 10, length: 25, chunkSize: 10)
        XCTAssertEqual(chunks.map(\.offset), [10, 20, 30])
        XCTAssertEqual(chunks.map(\.length), [10, 10, 5])
        XCTAssertTrue(EmuFileReader.chunks(offset: 0, length: 0, chunkSize: 10).isEmpty)
    }

    func testRoutes() throws {
        XCTAssertEqual(EmuSchemeHandler.route(for: URL(string: "zemu://app/v86/libv86.js")), .bundle("v86/libv86.js"))
        XCTAssertEqual(EmuSchemeHandler.route(for: URL(string: "zemu://app/host/emu.html")), .bundle("host/emu.html"))
        XCTAssertEqual(EmuSchemeHandler.route(for: URL(string: "zemu://app/files/abc123/disk%20one.img")), .file(token: "abc123"))
        let proxied = try XCTUnwrap(URL(string: "zemu://app/proxy?url=http%3A%2F%2Fdl-cdn.alpinelinux.org%2Falpine%2FAPKINDEX"))
        XCTAssertEqual(EmuSchemeHandler.route(for: proxied), .proxy(try XCTUnwrap(URL(string: "http://dl-cdn.alpinelinux.org/alpine/APKINDEX"))))
        XCTAssertEqual(EmuSchemeHandler.route(for: URL(string: "zemu://app/proxy?url=file%3A%2F%2F%2Fetc%2Fpasswd")), .notFound)
        XCTAssertEqual(EmuSchemeHandler.route(for: URL(string: "zemu://app/v86/../../secret")), .notFound)
        XCTAssertEqual(EmuSchemeHandler.route(for: URL(string: "zemu://other/v86/libv86.js")), .notFound)
        XCTAssertEqual(EmuSchemeHandler.route(for: URL(string: "https://app/v86/libv86.js")), .notFound)
        XCTAssertEqual(EmuSchemeHandler.route(for: nil), .notFound)
    }

    func testBundledResourcesArePresent() throws {
        let root = try XCTUnwrap(EmuResources.root)
        for path in ["host/emu.html", "host/emu.js", "v86/libv86.js", "v86/v86.wasm", "v86/seabios.bin", "v86/vgabios.bin",
                     "images-x86.json"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path), path)
        }
        XCTAssertEqual(EmuResources.v86Commit, "cc37f35c43bf14865d74ad76879ecf9410f69eb1")
    }
}

/// A WKURLSchemeTask stand-in that records what the handler sends.
final class FakeSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    var response: URLResponse?
    var body = Data()
    var finished = false
    var failure: (any Error)?

    init(_ request: URLRequest) { self.request = request }

    func didReceive(_ response: URLResponse) { self.response = response }
    func didReceive(_ data: Data) { body.append(data) }
    func didFinish() { finished = true }
    func didFailWithError(_ error: any Error) { failure = error }
}

@MainActor
final class SchemeHandlerTests: XCTestCase {
    private func serve(_ handler: EmuSchemeHandler, _ webView: WKWebView, _ request: URLRequest) async throws -> FakeSchemeTask {
        let task = FakeSchemeTask(request)
        handler.webView(webView, start: task)
        let deadline = Date().addingTimeInterval(10)
        while !task.finished && task.failure == nil {
            if Date() > deadline { XCTFail("no response for \(request)"); break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return task
    }

    func testServesRegisteredFilesWithRanges() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zemu-serve-\(UUID().uuidString).img")
        defer { try? FileManager.default.removeItem(at: url) }
        // 3 MiB so a full response spans several 1 MiB chunks.
        var bytes = Data(count: 3 << 20)
        bytes.withUnsafeMutableBytes { raw in
            for i in stride(from: 0, to: raw.count, by: 4096) { raw[i] = UInt8((i / 4096) & 0xFF) }
        }
        try bytes.write(to: url)
        let handler = EmuSchemeHandler()
        let webView = WKWebView(frame: .zero)
        let pageURL = handler.register(url)
        XCTAssertTrue(pageURL.hasPrefix("zemu://app/files/"))
        let target = try XCTUnwrap(URL(string: pageURL))

        var ranged = URLRequest(url: target)
        ranged.setValue("bytes=8192-12287", forHTTPHeaderField: "Range")
        let partial = try await serve(handler, webView, ranged)
        let http = try XCTUnwrap(partial.response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 206)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Range"), "bytes 8192-12287/\(3 << 20)")
        XCTAssertEqual(partial.body.count, 4096)
        XCTAssertEqual(partial.body.first, 2)

        let whole = try await serve(handler, webView, URLRequest(url: target))
        XCTAssertEqual((whole.response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(whole.body, bytes)

        var beyond = URLRequest(url: target)
        beyond.setValue("bytes=\(4 << 20)-", forHTTPHeaderField: "Range")
        let unsatisfiable = try await serve(handler, webView, beyond)
        XCTAssertEqual((unsatisfiable.response as? HTTPURLResponse)?.statusCode, 416)

        let missing = try await serve(handler, webView, URLRequest(url: try XCTUnwrap(URL(string: "zemu://app/files/nope/x"))))
        XCTAssertEqual((missing.response as? HTTPURLResponse)?.statusCode, 404)

        let bundle = try await serve(handler, webView, URLRequest(url: try XCTUnwrap(URL(string: "zemu://app/host/emu.js"))))
        XCTAssertEqual((bundle.response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: bundle.body, as: UTF8.self).contains("window.zemu"))
    }
}

final class CatalogTests: XCTestCase {
    func testBundledCatalogueIsValid() throws {
        let catalog = try EmuImageCatalog.bundled()
        XCTAssertEqual(catalog.validate(), [])
        XCTAssertEqual(catalog.images.map(\.id), ["z-alpine-desktop-x86", "alpine-virt-x86", "alpine-standard-x86",
                                                  "debian-12-i386-netinst", "tinycore-x86", "tinycore-core-x86"])
        XCTAssertEqual(catalog.images.filter(\.recommended).map(\.id), ["z-alpine-desktop-x86"])
        let z = try XCTUnwrap(catalog.image(id: "z-alpine-desktop-x86"))
        XCTAssertEqual(z.kind, .instantStart)
        XCTAssertFalse(z.isResolved)
        XCTAssertEqual(z.manifestURL?.absoluteString,
                       "https://github.com/Everaldtah/zcomputer/releases/download/images-v1/manifest.json")
        XCTAssertEqual(z.emulatorCommit, EmuResources.v86Commit)
        let virt = try XCTUnwrap(catalog.image(id: "alpine-virt-x86"))
        XCTAssertEqual(virt.downloadBytes, 52_428_800)
        XCTAssertEqual(virt.file(.cdrom)?.sha256, "569ad8cef1d6d3a3a6024f28ee94ea156974b32437240f2b217c56a99fbb6296")
        XCTAssertEqual(virt.bootAssist?.waitForScreenText, "boot:")
        // Every boot assist types something the US keyboard table can produce.
        for image in catalog.images {
            if let assist = image.bootAssist {
                XCTAssertNoThrow(try ScanCodes.typing(assist.typeText ?? ""), image.id)
                for k in assist.keys ?? [] { XCTAssertNoThrow(try ScanCodes.scancodes(forKeys: k), image.id) }
            }
        }
    }

    static let manifest = """
    {
      "version": "2026.10.28-ff7c4e5",
      "builtAt": "2026-10-28T08:00:00Z",
      "baseUrl": "https://github.com/Everaldtah/zcomputer/releases/download/images-v1/",
      "images": [{
        "id": "z-alpine-desktop-x86", "name": "Z Alpine Desktop (x86)", "arch": "x86", "format": "raw",
        "diskBytes": 1610612736,
        "files": {
          "img": {"name": "z-alpine-desktop-x86.img.xz", "url": "https://github.com/Everaldtah/zcomputer/releases/download/images-v1/z-alpine-desktop-x86.img.xz",
                  "compression": "xz", "sizeBytes": 94971696, "sha256": "50F18CFDD23C95B4CD71E4B7FD7CF4872DE412BC1BF5903E8FBABA68B728215B",
                  "decompressedBytes": 1610612736, "decompressedSha256": "d814f9946018674cce6448d3481b685eeb1b4ee7cf8cad8089d74f2d2cb98e47"},
          "state": {"name": "z-alpine-desktop-x86.state.xz", "compression": "xz", "sizeBytes": 27667904,
                    "sha256": "9d63f33c1bd868e438e3dc67a32cae85b6e79de64ab8e611bacdf2582062bdbf",
                    "decompressedBytes": 139774556, "decompressedSha256": "c36691c59644777fb2eafe13a124622fc04d8e043bd7df254a6e4204582b1b27"}
        },
        "memoryMB": 512, "vgaMemoryMB": 8, "screen": {"w": 1024, "h": 768},
        "user": "z", "password": "z", "desktop": "xfce-x11", "agentPort": 5555,
        "serial": {"port": "ttyS0", "baud": 115200, "loggedIn": true},
        "hostShare": {"type": "9p", "mountTag": "host9p", "mountPoint": "/mnt/host"},
        "emulator": {"name": "v86", "npm": "v86@0.5.472", "commit": "cc37f35c43bf14865d74ad76879ecf9410f69eb1",
                     "options": {"memory_size": 536870912, "acpi": false}},
        "bootToDesktopSec": 169.6, "restoreToShellSec": 0.9, "notes": ["x"]
      }]
    }
    """

    func testManifestFillsTheInstantStartImage() throws {
        let z = try XCTUnwrap(try EmuImageCatalog.bundled().image(id: "z-alpine-desktop-x86"))
        let resolved = try EmuImageCatalog.apply(manifest: Data(Self.manifest.utf8), to: z,
                                                 v86Commit: "cc37f35c43bf14865d74ad76879ecf9410f69eb1")
        XCTAssertEqual(resolved.kind, .instantStart)
        XCTAssertEqual(resolved.version, "2026.10.28-ff7c4e5")
        XCTAssertEqual(resolved.files.map(\.role), [.hda, .state])
        let img = try XCTUnwrap(resolved.file(.hda))
        XCTAssertEqual(img.compression, .xz)
        XCTAssertEqual(img.localName, "z-alpine-desktop-x86.img")
        XCTAssertEqual(img.sha256, "50f18cfdd23c95b4cd71e4b7fd7cf4872de412bc1bf5903e8fbaba68b728215b", "lowercased")
        XCTAssertEqual(img.decompressedBytes, 1_610_612_736)
        let state = try XCTUnwrap(resolved.file(.state))
        XCTAssertEqual(state.url.absoluteString,
                       "https://github.com/Everaldtah/zcomputer/releases/download/images-v1/z-alpine-desktop-x86.state.xz",
                       "a file without url resolves against baseUrl")
        XCTAssertEqual(resolved.downloadBytes, 94_971_696 + 27_667_904)
        XCTAssertEqual(resolved.serialLogin, EmuCredentials(user: "z", password: "z"))
        XCTAssertEqual(resolved.screen, PixelSize(width: 1024, height: 768))
        XCTAssertEqual(EmuImageCatalog(images: [resolved]).validate(), [])

        // A state from another v86 build cannot restore: the disk cold-boots instead.
        let other = try EmuImageCatalog.apply(manifest: Data(Self.manifest.utf8), to: z, v86Commit: "0000000")
        XCTAssertEqual(other.kind, .disk)
        XCTAssertEqual(other.files.map(\.role), [.hda])

        var wrong = z
        wrong.manifestImageID = "nope"
        XCTAssertThrowsError(try EmuImageCatalog.apply(manifest: Data(Self.manifest.utf8), to: wrong))
    }

    func testMakeSpec() throws {
        let catalog = try EmuImageCatalog.bundled()
        let z = try EmuImageCatalog.apply(manifest: Data(Self.manifest.utf8), to: try XCTUnwrap(catalog.image(id: "z-alpine-desktop-x86")),
                                          v86Commit: "cc37f35c43bf14865d74ad76879ecf9410f69eb1")
        let disk = URL(fileURLWithPath: "/store/Images/z/z.img"), state = URL(fileURLWithPath: "/store/Images/z/z.state")
        let prepared = EmuPreparedImage(imageID: z.id, version: z.version, cdrom: nil, hda: disk, state: state, preparedAt: Date())
        let spec = try EmuImageCatalog.makeSpec(for: z, prepared: prepared, name: "Desk", memoryMB: 1024)
        XCTAssertEqual(spec.boot, .state(state, disk: disk))
        XCTAssertEqual(spec.memoryMB, 512, "a state needs the memory size it was saved with")
        XCTAssertEqual(spec.nic, .virtio)
        XCTAssertTrue(spec.enable9p)
        XCTAssertFalse(spec.acpi)
        XCTAssertEqual(spec.imageID, "z-alpine-desktop-x86")
        XCTAssertEqual(spec.serialLogin?.user, "z")

        let virt = try XCTUnwrap(catalog.image(id: "alpine-virt-x86"))
        let iso = URL(fileURLWithPath: "/store/Images/v/a.iso")
        let isoSpec = try EmuImageCatalog.makeSpec(
            for: virt, prepared: EmuPreparedImage(imageID: virt.id, version: nil, cdrom: iso, hda: nil, state: nil, preparedAt: Date()),
            name: "Alpine", memoryMB: 192)
        XCTAssertEqual(isoSpec.boot, .iso(iso))
        XCTAssertEqual(isoSpec.memoryMB, 192)
        XCTAssertEqual(isoSpec.serialLogin, EmuCredentials(user: "root", password: ""))
        XCTAssertNotNil(isoSpec.bootAssist)
        XCTAssertThrowsError(try EmuImageCatalog.makeSpec(
            for: virt, prepared: EmuPreparedImage(imageID: virt.id, version: nil, cdrom: nil, hda: nil, state: nil, preparedAt: Date()),
            name: "x"))
    }

    func testPreparerReadyMarker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zemu-prep-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EmuStore(root: root)
        try store.prepare()
        // A local "download" server is not available in unit tests; a file:// URL goes through URLSession too.
        let source = root.appendingPathComponent("src.iso")
        let content = Data(repeating: 0x41, count: 70_000)
        try content.write(to: source)
        let image = EmuImage(id: "local-test", name: "Local", kind: .iso, files: [
            EmuImageFile(role: .cdrom, name: "local.iso", url: source, sizeBytes: Int64(content.count),
                         sha256: EmuSHA256.hex(of: content)),
        ])
        let preparer = EmuImagePreparer(store: store)
        XCTAssertFalse(preparer.isReady(image))
        let prepared = try await preparer.prepare(image)
        XCTAssertEqual(prepared.cdrom?.lastPathComponent, "local.iso")
        XCTAssertTrue(preparer.isReady(image))
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(prepared.cdrom)), content)

        var changed = image
        changed.files[0].sha256 = String(repeating: "0", count: 64)
        XCTAssertFalse(preparer.isReady(changed), "another sha256 in the catalogue means not ready")
        do {
            _ = try await preparer.prepare(changed)
            XCTFail("expected a checksum failure")
        } catch {
            XCTAssertTrue("\(error)".contains("sha256"), "\(error)")
        }
        try preparer.delete(image)
        XCTAssertFalse(preparer.isReady(image))
    }
}

final class XZTests: XCTestCase {
    static let sampleSHA256 = "954618054abc7575efe777f40e9d7cc2ab979ff6edae1667716a7fa2e0a730a3"

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "xz", subdirectory: "Fixtures"), name)
    }

    func testDecodesMultiBlockCRC64AndCRC32Streams() throws {
        for name in ["sample-multiblock-crc64", "sample-crc32"] {
            let data = try EmuXZ.decompress(Data(contentsOf: fixture(name)))
            XCTAssertEqual(data.count, 204_800, name)
            XCTAssertEqual(EmuSHA256.hex(of: data), Self.sampleSHA256, name)
        }
    }

    func testSparseFileOutput() throws {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("zemu-xz-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: out) }
        var reports = 0
        let n = try EmuXZ.decompress(try fixture("sample-multiblock-crc64"), to: out, sparse: true) { _, _ in reports += 1 }
        XCTAssertEqual(n, 204_800)
        XCTAssertGreaterThan(reports, 0)
        XCTAssertEqual(try emuFileSize(out), 204_800)
        XCTAssertEqual(try EmuSHA256.hex(of: out), Self.sampleSHA256)
    }

    func testTruncatedInputFails() throws {
        let full = try Data(contentsOf: fixture("sample-crc32"))
        XCTAssertThrowsError(try EmuXZ.decompress(full.prefix(full.count - 40)))
        XCTAssertThrowsError(try EmuXZ.decompress(Data("not xz at all".utf8)))
    }
}

final class ImageToolsTests: XCTestCase {
    func testTextRenderingAndBlankDetection() throws {
        var lines = Array(repeating: String(repeating: " ", count: 80), count: 25)
        XCTAssertTrue(EmuImageTools.isBlank(png: try EmuImageTools.renderText(lines).data))
        lines[0] = "Welcome to Alpine Linux 3.22" + String(repeating: " ", count: 52)
        lines[1] = "localhost login:"
        let image = try EmuImageTools.renderText(lines)
        XCTAssertEqual(image.width, 720)
        XCTAssertEqual(image.height, 400)
        XCTAssertEqual(image.mime, "image/png")
        XCTAssertFalse(EmuImageTools.isBlank(png: image.data))
        XCTAssertTrue(EmuImageTools.isBlank(png: Data("garbage".utf8)))
    }
}
