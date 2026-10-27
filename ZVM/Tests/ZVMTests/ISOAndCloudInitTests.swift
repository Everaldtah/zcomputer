import Foundation
import XCTest
import ZCore
@testable import ZVM

final class ISO9660Tests: XCTestCase {
    func testBuildAndReadBackBothTrees() throws {
        var builder = ISO9660Builder(volumeIdentifier: "TESTVOL", date: Date(timeIntervalSince1970: 1_700_000_000))
        builder.addFile(path: "readme.txt", contents: Data("hello".utf8))
        builder.addFile(path: "EFI/BOOT/BOOTAA64.EFI", contents: Data(repeating: 0xAB, count: 5000))
        builder.addFile(path: "docs/long-file-name-for-joliet.md", contents: Data("# doc".utf8))
        builder.addFile(path: "empty", contents: Data())
        let image = builder.build()
        XCTAssertEqual(image.count % 2048, 0)

        let reader = try ISO9660Reader(source: DataSource(image))
        XCTAssertEqual(reader.primaryVolumeIdentifier, "TESTVOL")
        XCTAssertEqual(reader.jolietVolumeIdentifier, "TESTVOL")
        XCTAssertTrue(reader.hasJoliet)

        let joliet = try reader.list("/").map(\.name).sorted()
        XCTAssertEqual(joliet, ["EFI", "docs", "empty", "readme.txt"])
        let primary = try reader.list("/", joliet: false).map(\.name).sorted()
        XCTAssertEqual(primary, ["DOCS", "EFI", "EMPTY", "README.TXT"])

        let loader = try XCTUnwrap(reader.entry(at: "efi/boot/bootaa64.efi"))
        XCTAssertFalse(loader.isDirectory)
        XCTAssertEqual(try reader.contents(of: loader), Data(repeating: 0xAB, count: 5000))
        let doc = try XCTUnwrap(reader.entry(at: "docs/long-file-name-for-joliet.md"))
        XCTAssertEqual(try reader.contents(of: doc), Data("# doc".utf8))
        let empty = try XCTUnwrap(reader.entry(at: "empty"))
        XCTAssertEqual(empty.size, 0)
        XCTAssertTrue(try reader.bootEntries().isEmpty)
        XCTAssertNil(reader.entry(at: "missing/file"))
    }

    func testDirectoriesSpanningSeveralSectors() throws {
        var builder = ISO9660Builder(volumeIdentifier: "MANY")
        for i in 0..<120 { builder.addFile(path: "files/file-number-\(i).txt", contents: Data("\(i)".utf8)) }
        let reader = try ISO9660Reader(source: DataSource(builder.build()))
        let names = try reader.list("files").map(\.name)
        XCTAssertEqual(names.count, 120)
        let entry = try XCTUnwrap(reader.entry(at: "files/file-number-119.txt"))
        XCTAssertEqual(try reader.contents(of: entry), Data("119".utf8))
        XCTAssertEqual(try reader.list("files", joliet: false).count, 120)
    }

    func testPrimaryIdentifiers() {
        XCTAssertEqual(String(decoding: ISO9660Builder.primaryIdentifier("user-data", isDirectory: false), as: UTF8.self), "USER_DATA.;1")
        XCTAssertEqual(String(decoding: ISO9660Builder.primaryIdentifier("BOOTX64.EFI", isDirectory: false), as: UTF8.self), "BOOTX64.EFI;1")
        XCTAssertEqual(String(decoding: ISO9660Builder.primaryIdentifier("boot", isDirectory: true), as: UTF8.self), "BOOT")
        XCTAssertEqual(ISO9660Builder.jolietIdentifier("a-b"), [0, 0x61, 0, 0x2D, 0, 0x62])
    }

    func testRejectsNonISOData() {
        XCTAssertThrowsError(try ISO9660Reader(source: DataSource(Data(count: 64 * 1024))))
    }
}

final class ISOInspectorTests: XCTestCase {
    private func iso(volume: String, files: [String]) -> Data {
        var b = ISO9660Builder(volumeIdentifier: volume)
        for f in files { b.addFile(path: f, contents: Data("MZ".utf8)) }
        return b.build()
    }

    func testArm64LoaderIsDetected() throws {
        let result = try ISOInspector.inspect(source: DataSource(iso(volume: "Debian 13 n", files: ["EFI/BOOT/BOOTAA64.EFI", "EFI/BOOT/grubaa64.efi"])))
        XCTAssertEqual(result.efiArchitectures, [.arm64])
        XCTAssertEqual(result.architecture, .arm64)
        XCTAssertTrue(result.isUEFIBootable)
        XCTAssertNil(result.warning(host: .arm64))
        XCTAssertNotNil(result.warning(host: .x86_64))
    }

    func testIntelISOWarnsOnAppleSilicon() throws {
        let result = try ISOInspector.inspect(source: DataSource(iso(volume: "Ubuntu-Server 24.04", files: ["EFI/BOOT/BOOTX64.EFI"])))
        XCTAssertEqual(result.architecture, .x86_64)
        let warning = try XCTUnwrap(result.warning(host: .arm64))
        XCTAssertTrue(warning.contains("arm64"), warning)
        XCTAssertNil(result.warning(host: .x86_64))
    }

    func testMultiArchitectureImagePrefersTheHost() throws {
        let result = try ISOInspector.inspect(source: DataSource(iso(volume: "MULTI", files: ["EFI/BOOT/BOOTX64.EFI", "EFI/BOOT/BOOTAA64.EFI"])))
        XCTAssertEqual(result.efiArchitectures, [.arm64, .x86_64])
        XCTAssertEqual(result.architecture, GuestArchitecture.host)
        XCTAssertNil(result.warning(host: .arm64))
        XCTAssertNil(result.warning(host: .x86_64))
    }

    func testNameHintsAndMissingLoader() throws {
        let hinted = try ISOInspector.inspect(source: DataSource(iso(volume: "CDROM", files: ["README"])),
                                              fileName: "alpine-virt-3.22.0-x86_64.iso")
        XCTAssertEqual(hinted.architecture, .x86_64)
        XCTAssertFalse(hinted.isUEFIBootable)
        XCTAssertNotNil(hinted.warning(host: .arm64))

        let unknown = try ISOInspector.inspect(source: DataSource(iso(volume: "DATA", files: ["README"])), fileName: "data.iso")
        XCTAssertNil(unknown.architecture)
        XCTAssertTrue(unknown.warning(host: .arm64)?.contains("UEFI") ?? false)

        XCTAssertEqual(ISOInspector.nameHint("debian-13.1.0-arm64-netinst.iso"), .arm64)
        XCTAssertEqual(ISOInspector.nameHint("Fedora-Server-aarch64"), .arm64)
        XCTAssertEqual(ISOInspector.nameHint("ubuntu-24.04-live-server-amd64.iso"), .x86_64)
        XCTAssertNil(ISOInspector.nameHint("archlinux.iso"))
    }

    func testFATLoaderNames() {
        var fat = Data(count: 1024)
        fat.replaceSubrange(100..<111, with: Data("BOOTX64 EFI".utf8))
        XCTAssertEqual(ISOInspector.fatLoaderArchitectures(in: fat), [.x86_64])
        fat.replaceSubrange(300..<311, with: Data("BOOTAA64EFI".utf8))
        XCTAssertEqual(ISOInspector.fatLoaderArchitectures(in: fat), [.x86_64, .arm64])
        XCTAssertEqual(ISOInspector.loaderArchitecture(fileName: "bootaa64.efi"), .arm64)
        XCTAssertNil(ISOInspector.loaderArchitecture(fileName: "grubx64.efi"))
    }
}

final class CloudInitTests: XCTestCase {
    func testUserDataContents() {
        let config = CloudInitConfig(instanceID: "iid-1", hostname: "zbox", password: "s3cr\"et",
                                     sshAuthorizedKeys: ["ssh-ed25519 AAAA test"], packages: ["xdotool"],
                                     agentBinaryName: "zguest-linux-arm64", runCommands: ["echo done"])
        let yaml = config.userData()
        XCTAssertTrue(yaml.hasPrefix("#cloud-config\n"))
        XCTAssertTrue(yaml.contains("hostname: \"zbox\"\n"))
        XCTAssertTrue(yaml.contains("  - name: \"z\"\n"))
        XCTAssertTrue(yaml.contains("    plain_text_passwd: \"s3cr\\\"et\"\n"), yaml)
        XCTAssertTrue(yaml.contains("    sudo: \"ALL=(ALL) NOPASSWD:ALL\"\n"))
        XCTAssertTrue(yaml.contains("ssh_pwauth: true\n"))
        XCTAssertTrue(yaml.contains("      - \"ssh-ed25519 AAAA test\"\n"))
        XCTAssertTrue(yaml.contains("packages:\n  - \"xdotool\"\n"))
        XCTAssertTrue(yaml.contains("  - path: /usr/local/sbin/zguest-install\n"))
        XCTAssertTrue(yaml.contains("zguest-linux-arm64"))
        XCTAssertTrue(yaml.contains("  - [sh, -c, \"/usr/local/sbin/zguest-install\"]\n"))
        XCTAssertTrue(yaml.contains("  - [sh, -c, \"echo done\"]\n"))
        XCTAssertFalse(yaml.contains("\t"))
        XCTAssertEqual(config.metaData(), "instance-id: \"iid-1\"\nlocal-hostname: \"zbox\"\n")

        let noAgent = CloudInitConfig(password: "pw", agentBinaryName: nil)
        XCTAssertFalse(noAgent.userData().contains("zguest"))
        XCTAssertFalse(noAgent.userData().contains("packages:"))
    }

    func testYAMLEscaping() {
        let c = CloudInitConfig(password: "x")
        XCTAssertEqual(c.yaml("plain"), "\"plain\"")
        XCTAssertEqual(c.yaml("a\"b\\c"), "\"a\\\"b\\\\c\"")
        XCTAssertEqual(c.yaml("line1\nline2\t"), "\"line1\\nline2\\t\"")
        XCTAssertEqual(c.yaml("\u{01}"), "\"\\u0001\"")
        XCTAssertEqual(c.yaml("ünï"), "\"ünï\"")
    }

    func testSeedImageHasCidataLabelAndFiles() throws {
        let config = CloudInitConfig(instanceID: "iid-seed", password: "pw")
        let image = CloudInitSeed.makeImage(config, date: Date(timeIntervalSince1970: 1_800_000_000))
        let reader = try ISO9660Reader(source: DataSource(image))
        XCTAssertEqual(reader.primaryVolumeIdentifier, "cidata")
        XCTAssertEqual(reader.jolietVolumeIdentifier, "cidata")
        XCTAssertEqual(try reader.list("/").map(\.name).sorted(), ["meta-data", "user-data"])
        let userData = try XCTUnwrap(reader.entry(at: "user-data"))
        XCTAssertEqual(String(decoding: try reader.contents(of: userData), as: UTF8.self), config.userData())
        let metaData = try XCTUnwrap(reader.entry(at: "meta-data"))
        XCTAssertEqual(String(decoding: try reader.contents(of: metaData), as: UTF8.self), config.metaData())

        let dir = try makeTemporaryDirectory("zvm-seed")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("seed.iso")
        try CloudInitSeed.write(config, to: url)
        XCTAssertEqual(try ISO9660Reader(url: url).jolietVolumeIdentifier, "cidata")
    }
}
