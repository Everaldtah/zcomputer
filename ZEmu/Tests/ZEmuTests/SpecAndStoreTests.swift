import Foundation
import XCTest
import ZCore
@testable import ZEmu

final class EmuSpecTests: XCTestCase {
    func testRoundTripKeepsEveryField() throws {
        let spec = EmuSpec(name: "Alpine", memoryMB: 384, vgaMemoryMB: 16, screen: PixelSize(width: 800, height: 600),
                           boot: .state(URL(fileURLWithPath: "/tmp/s.v86state"), disk: URL(fileURLWithPath: "/tmp/d.img")),
                           cdrom: URL(fileURLWithPath: "/tmp/x.iso"), shareDirectory: URL(fileURLWithPath: "/tmp/share"),
                           enable9p: false, serial: true, network: .fetch, nic: .ne2k, acpi: true, fastBoot: false,
                           preserveMACFromState: false, serialLogin: EmuCredentials(user: "root", password: ""),
                           bootAssist: EmuBootAssist(waitForScreenText: "boot:", typeText: "virt\n", keys: ["Return"]),
                           mouseSensitivity: 1.5, imageID: "alpine-virt-x86")
        let data = try JSONEncoder().encode(spec)
        let back = try JSONDecoder().decode(EmuSpec.self, from: data)
        XCTAssertEqual(back, spec)
    }

    func testLenientDecodingFillsDefaults() throws {
        let json = #"{"boot": {"kind": "iso", "url": "file:///tmp/a.iso"}}"#
        let spec = try JSONDecoder().decode(EmuSpec.self, from: Data(json.utf8))
        XCTAssertEqual(spec.memoryMB, 512)
        XCTAssertEqual(spec.vgaMemoryMB, 8)
        XCTAssertEqual(spec.screen, PixelSize(width: 1024, height: 768))
        XCTAssertEqual(spec.network, EmuNetwork.none)
        XCTAssertEqual(spec.nic, .virtio)
        XCTAssertTrue(spec.serial)
        XCTAssertTrue(spec.enable9p)
        XCTAssertTrue(spec.fastBoot)
        XCTAssertFalse(spec.acpi)
        XCTAssertEqual(spec.boot, .iso(URL(fileURLWithPath: "/tmp/a.iso")))
        XCTAssertThrowsError(try JSONDecoder().decode(EmuSpec.self, from: Data(#"{"boot": {"kind": "floppy", "url": "file:///a"}}"#.utf8)))
    }

    func testDerivedMediaAndBootOrder() {
        let iso = URL(fileURLWithPath: "/i.iso"), disk = URL(fileURLWithPath: "/d.img"), state = URL(fileURLWithPath: "/s.st")
        var spec = EmuSpec(name: "x", boot: .iso(iso), hda: disk)
        XCTAssertEqual(spec.cdromImage, iso)
        XCTAssertEqual(spec.diskImage, disk)
        XCTAssertNil(spec.initialState)
        XCTAssertEqual(spec.bootOrder, 0x123)

        spec.boot = .disk(disk)
        spec.cdrom = iso
        XCTAssertEqual(spec.cdromImage, iso)
        XCTAssertEqual(spec.diskImage, disk)
        XCTAssertEqual(spec.bootOrder, 0x312)

        spec = EmuSpec(name: "y", boot: .state(state, disk: disk))
        XCTAssertEqual(spec.initialState, state)
        XCTAssertEqual(spec.diskImage, disk)
        XCTAssertNil(spec.cdromImage)
        XCTAssertEqual(spec.bootOrder, 0x312)
    }

    func testValidateMemoryCeilings() {
        var spec = EmuSpec(name: "x", boot: .iso(URL(fileURLWithPath: "/a.iso")))
        XCTAssertEqual(spec.validate(isPhone: true), [])
        spec.memoryMB = 2048
        XCTAssertEqual(spec.validate(isPhone: false), [])
        XCTAssertEqual(spec.validate(isPhone: true).count, 1)
        spec.memoryMB = 8
        XCTAssertFalse(spec.validate().isEmpty)
        XCTAssertEqual(EmuSpec.recommendedMaxMemoryMBOnPhone, 512)
    }

    func testLaunchConfig() throws {
        var spec = EmuSpec(name: "x", memoryMB: 256, vgaMemoryMB: 8, boot: .iso(URL(fileURLWithPath: "/a.iso")),
                           network: .fetch, bootAssist: EmuBootAssist(waitForScreenText: "boot:", typeText: "virt cOnsole\n",
                                                                       keys: ["ctrl+c"], timeoutSeconds: 30))
        let cd = EmuLaunchConfig.Disk(url: "zemu://app/files/t/a.iso", size: 1000)
        let cold = try EmuLaunchConfig.make(spec: spec, cdrom: cd, hda: nil, initialState: nil)
        XCTAssertEqual(cold.memorySize, 256 * 1024 * 1024)
        XCTAssertEqual(cold.vgaMemorySize, 8 * 1024 * 1024)
        XCTAssertEqual(cold.bootOrder, 0x123)
        XCTAssertEqual(cold.relayURL, "fetch")
        XCTAssertEqual(cold.corsProxy, "zemu://app/proxy?url=")
        XCTAssertEqual(cold.wasmPath, "zemu://app/v86/v86.wasm")
        XCTAssertEqual(cold.cdrom, cd)
        XCTAssertNil(cold.hda)
        XCTAssertTrue(cold.filesystem)
        let assist = try XCTUnwrap(cold.bootAssist)
        XCTAssertEqual(assist.screenText, "boot:")
        XCTAssertEqual(assist.timeoutMs, 30_000)
        XCTAssertEqual(assist.strokes.count, "virt cOnsole\n".count + 1)
        XCTAssertEqual(assist.strokes.first, [0x2F, 0xAF])                      // v
        XCTAssertEqual(assist.strokes[6], [0x2A, 0x18, 0x98, 0xAA])             // O (shifted)
        XCTAssertEqual(assist.strokes.last, [0x1D, 0x2E, 0xAE, 0x9D])           // ctrl+c

        let warm = try EmuLaunchConfig.make(spec: spec, cdrom: cd, hda: nil, initialState: "zemu://app/files/s/x.v86state")
        XCTAssertNil(warm.bootAssist, "boot assists only run on cold boots")
        XCTAssertEqual(warm.initialState, "zemu://app/files/s/x.v86state")

        spec.network = .none
        let offline = try EmuLaunchConfig.make(spec: spec, cdrom: nil, hda: nil, initialState: nil)
        XCTAssertNil(offline.relayURL)
        XCTAssertNil(offline.corsProxy)
        // The page receives it as JSON.
        let json = try JSONValue(encoding: offline)
        XCTAssertEqual(json["nic"]?.stringValue, "virtio")
        XCTAssertEqual(json["bootAssist"]?["strokes"]?[0]?[0]?.intValue, 0x2F)
    }

    func testScreenModePixelSize() {
        XCTAssertEqual(EmuScreenMode.text(cols: 80, rows: 25).pixelSize, PixelSize(width: 720, height: 400))
        XCTAssertEqual(EmuScreenMode.graphical(width: 1024, height: 768, bpp: 32).pixelSize, PixelSize(width: 1024, height: 768))
        XCTAssertTrue(EmuRunState.saving.isActive)
        XCTAssertFalse(EmuRunState.error("x").isActive)
    }
}

final class EmuStoreTests: XCTestCase {
    private var root: URL!
    private var documents: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("zemu-store-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("Emu", isDirectory: true)
        documents = base.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    func testCreateListLoadDelete() throws {
        let store = EmuStore(root: root, documents: documents)
        try store.prepare()
        let iso = documents.appendingPathComponent("ISOs/My Linux.iso")
        try FileManager.default.createDirectory(at: iso.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("iso".utf8).write(to: iso)

        let created = try store.create(EmuSpec(name: "Installer", boot: .iso(iso)), blankDiskBytes: 64 << 20)
        let disk = try XCTUnwrap(created.hda)
        XCTAssertEqual(disk.lastPathComponent, "disk.img")
        XCTAssertEqual(try emuFileSize(disk), 64 << 20)

        // Paths inside the store and Documents are stored portably.
        let text = try String(contentsOf: store.specURL(created.id), encoding: .utf8)
        XCTAssertTrue(text.contains("zemu-store:"), text)
        XCTAssertTrue(text.contains("zemu-documents:"), text)
        XCTAssertFalse(text.contains(root.path), text)

        let listed = try store.list()
        XCTAssertEqual(listed.count, 1)
        let loaded = try store.load(id: created.id)
        XCTAssertEqual(loaded.name, "Installer")
        XCTAssertEqual(loaded.cdromImage?.standardizedFileURL.path, iso.standardizedFileURL.path)
        XCTAssertEqual(loaded.diskImage?.standardizedFileURL.path, disk.standardizedFileURL.path)
        XCTAssertThrowsError(try store.create(created))

        try store.delete(id: created.id)
        XCTAssertEqual(try store.list().count, 0)
        XCTAssertThrowsError(try store.load(id: created.id))
    }

    func testPortablePathsSurviveAContainerMove() throws {
        let store = EmuStore(root: root, documents: documents)
        let inside = root.appendingPathComponent("Images/z/disk image.img")
        let portable = store.portable(inside)
        XCTAssertEqual(portable.scheme, "zemu-store")
        let moved = EmuStore(root: URL(fileURLWithPath: "/new/container/Emu"), documents: nil)
        XCTAssertEqual(moved.resolve(portable).path, "/new/container/Emu/Images/z/disk image.img")
        let outside = URL(fileURLWithPath: "/elsewhere/a.iso")
        XCTAssertEqual(store.portable(outside), outside)
        XCTAssertEqual(store.resolve(outside), outside)
    }

    func testStatesNewestFirst() throws {
        let store = EmuStore(root: root)
        let id = UUID()
        try store.save(EmuSpec(id: id, name: "m", boot: .iso(URL(fileURLWithPath: "/a.iso"))))
        let older = store.newStateURL(id, date: Date(timeIntervalSince1970: 1_000))
        let newer = store.autosaveStateURL(id)
        try Data([1]).write(to: older)
        try Data([2]).write(to: newer)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: older.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: newer.path)
        XCTAssertEqual(store.states(id).map(\.lastPathComponent), [EmuStore.autosaveName, older.lastPathComponent])
        XCTAssertEqual(store.latestState(id)?.lastPathComponent, EmuStore.autosaveName)
        XCTAssertTrue(older.lastPathComponent.hasPrefix("state-19700101-"))
    }

    func testImportISOMakesUniqueNames() throws {
        let store = EmuStore(root: root)
        try store.prepare()
        let source = documents.appendingPathComponent("disc.iso")
        try Data("x".utf8).write(to: source)
        let a = try store.importISO(from: source)
        let b = try store.importISO(from: source)
        XCTAssertEqual(a.lastPathComponent, "disc.iso")
        XCTAssertEqual(b.lastPathComponent, "disc-2.iso")
        XCTAssertEqual(EmuStore.safeName("a/b c:ü.iso"), "a_b_c_ü.iso")
    }
}
