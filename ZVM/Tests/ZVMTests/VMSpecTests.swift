import Foundation
import XCTest
import ZCore
@testable import ZVM

func makeTemporaryDirectory(_ name: String = "zvm-tests") throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

final class VMSpecTests: XCTestCase {
    func testSpecCodableRoundTrip() throws {
        let spec = VMSpec(
            name: "Dev box",
            guest: .linux,
            cpuCount: 6,
            memoryBytes: 8 << 30,
            diskBytes: 128 << 30,
            display: DisplaySpec(width: 1920, height: 1080, ppi: 144),
            install: .iso(URL(fileURLWithPath: "/tmp/debian-13-arm64.iso")),
            installBookmark: FileBookmark(data: Data([1, 2, 3]), securityScoped: true),
            attachInstallMedia: false,
            sharedFolders: [SharedFolder(hostURL: URL(fileURLWithPath: "/tmp/share"), tag: "work", readOnly: true,
                                         bookmark: FileBookmark(data: Data([9]), securityScoped: false))],
            rosetta: true,
            headless: true,
            nestedVirtualization: true,
            audio: false,
            clipboardSharing: false,
            createdAt: Date(timeIntervalSinceReferenceDate: 812_345_678.25),
            notes: "unit test")
        let data = try VMStore.encoder.encode(spec)
        let decoded = try VMStore.decoder.decode(VMSpec.self, from: data)
        XCTAssertEqual(decoded, spec)

        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"iso\""), text)
        XCTAssertTrue(text.contains("file:///tmp/debian-13-arm64.iso"), text)
    }

    func testInstallSourceVariantsRoundTrip() throws {
        let sources: [InstallSource] = [
            .iso(URL(fileURLWithPath: "/a.iso")),
            .diskImage(URL(fileURLWithPath: "/b.raw")),
            .macOSRestoreImage(nil),
            .macOSRestoreImage(URL(fileURLWithPath: "/c.ipsw")),
            .none,
        ]
        for s in sources {
            let data = try JSONEncoder().encode(s)
            XCTAssertEqual(try JSONDecoder().decode(InstallSource.self, from: data), s)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(InstallSource.self, from: Data(#"{"kind":"floppy"}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(InstallSource.self, from: Data(#"{"kind":"iso"}"#.utf8)))
    }

    func testLenientDecodingFillsDefaults() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","name":"Old"}"#
        let spec = try JSONDecoder().decode(VMSpec.self, from: Data(json.utf8))
        XCTAssertEqual(spec.id, id)
        XCTAssertEqual(spec.name, "Old")
        XCTAssertEqual(spec.guest, .linux)
        XCTAssertEqual(spec.cpuCount, 4)
        XCTAssertEqual(spec.memoryBytes, 4 << 30)
        XCTAssertEqual(spec.display, DisplaySpec())
        XCTAssertEqual(spec.install, .none)
        XCTAssertTrue(spec.attachInstallMedia)
        XCTAssertTrue(spec.sharedFolders.isEmpty)
    }

    func testPlainBookmarkRoundTripAndResolution() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let iso = dir.appendingPathComponent("installer.iso")
        try Data("iso".utf8).write(to: iso)
        let folder = dir.appendingPathComponent("share", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let isoBookmark = try FileBookmark.make(for: iso, securityScoped: false)
        let folderBookmark = try FileBookmark.make(for: folder, securityScoped: false)
        let (resolved, stale) = try isoBookmark.resolve()
        XCTAssertFalse(stale)
        XCTAssertEqual(resolved.standardizedFileURL.resolvingSymlinksInPath().path,
                       iso.standardizedFileURL.resolvingSymlinksInPath().path)

        // A spec whose stored URLs are outdated gets them back from the bookmarks.
        let spec = VMSpec(name: "b", install: .iso(URL(fileURLWithPath: "/nonexistent/old.iso")),
                          installBookmark: isoBookmark,
                          sharedFolders: [SharedFolder(hostURL: URL(fileURLWithPath: "/nonexistent/old"), tag: "s",
                                                       bookmark: folderBookmark)])
        let resolution = spec.resolvingBookmarks()
        XCTAssertTrue(resolution.problems.isEmpty, "\(resolution.problems)")
        XCTAssertEqual(resolution.spec.install.url?.lastPathComponent, "installer.iso")
        XCTAssertEqual(resolution.spec.sharedFolders.first?.hostURL.lastPathComponent, "share")
        // Plain bookmarks are not security scoped, so nothing needs access.
        XCTAssertTrue(resolution.spec.securityScopedURLs.isEmpty)
    }

    func testSecurityScopedBookmarkWhenAvailable() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("disk.iso")
        try Data("x".utf8).write(to: file)
        let bookmark: FileBookmark
        do {
            bookmark = try FileBookmark.make(for: file, securityScoped: true, readOnly: true)
        } catch {
            throw XCTSkip("security-scoped bookmarks are unavailable in this process: \(error)")
        }
        XCTAssertTrue(bookmark.securityScoped)
        let (url, _) = try bookmark.resolve()
        XCTAssertEqual(url.lastPathComponent, "disk.iso")
        let spec = VMSpec(name: "s", install: .iso(url), installBookmark: bookmark)
        XCTAssertEqual(spec.securityScopedURLs.map(\.lastPathComponent), ["disk.iso"])
    }

    func testBrokenBookmarkIsReportedNotFatal() {
        let spec = VMSpec(name: "x", install: .iso(URL(fileURLWithPath: "/keep.iso")),
                          installBookmark: FileBookmark(data: Data([0, 1, 2, 3]), securityScoped: false))
        let resolution = spec.resolvingBookmarks()
        XCTAssertEqual(resolution.problems.count, 1)
        XCTAssertEqual(resolution.spec.install.url?.path, "/keep.iso")
    }
}

final class VMStoreTests: XCTestCase {
    func testCreateListRenameDelete() throws {
        let root = try makeTemporaryDirectory("zvm-store")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VMStore(root: root)
        XCTAssertEqual(try store.list(), [])

        let first = VMSpec(name: "First", diskBytes: 1 << 30, createdAt: Date(timeIntervalSinceReferenceDate: 1))
        let second = VMSpec(name: "Second", diskBytes: 2 << 30, createdAt: Date(timeIntervalSinceReferenceDate: 2))
        let bundle = try store.create(first)
        try store.create(second, createDisk: false)

        XCTAssertEqual(try store.list().map(\.name), ["First", "Second"])
        XCTAssertEqual(try VMStore.fileSize(bundle.diskURL), 1 << 30)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.bundle(for: second.id).diskURL.path))
        if let allocated = VMStore.allocatedSize(bundle.diskURL) {
            XCTAssertLessThan(allocated, 1 << 20, "a fresh disk must be sparse")
        }
        XCTAssertThrowsError(try store.create(first))

        let renamed = try store.rename(id: first.id, to: "  Renamed ")
        XCTAssertEqual(renamed.name, "Renamed")
        XCTAssertEqual(try store.load(id: first.id).name, "Renamed")
        XCTAssertThrowsError(try store.rename(id: first.id, to: "   "))

        try store.delete(id: first.id)
        XCTAssertEqual(try store.list().map(\.name), ["Second"])
        XCTAssertThrowsError(try store.load(id: first.id))
        XCTAssertThrowsError(try store.delete(id: first.id))
    }

    func testGrowDiskNeverShrinks() throws {
        let root = try makeTemporaryDirectory("zvm-disk")
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = root.appendingPathComponent("disk.img")
        try VMStore.createSparseDisk(at: disk, bytes: 4096)
        XCTAssertTrue(try VMStore.growDisk(at: disk, to: 1 << 20))
        XCTAssertEqual(try VMStore.fileSize(disk), 1 << 20)
        XCTAssertFalse(try VMStore.growDisk(at: disk, to: 4096))
        XCTAssertEqual(try VMStore.fileSize(disk), 1 << 20)
        XCTAssertThrowsError(try VMStore.createSparseDisk(at: disk, bytes: 1))
    }
}
