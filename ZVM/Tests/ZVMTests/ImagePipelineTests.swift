import Foundation
import XCTest
import ZCore
@testable import ZVM

final class QCOW2Tests: XCTestCase {
    private func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    private func be64(_ v: UInt64) -> [UInt8] { be32(UInt32(v >> 32)) + be32(UInt32(v & 0xFFFF_FFFF)) }

    private func put(_ bytes: [UInt8], into data: inout [UInt8], at offset: Int) {
        if data.count < offset + bytes.count { data += [UInt8](repeating: 0, count: offset + bytes.count - data.count) }
        data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }

    /// A qcow2 v3 image with 4 KiB clusters and a 64 KiB virtual disk:
    /// guest cluster 0 = plain data, 1 = zero flag, 5 = deflate-compressed data at an unaligned offset,
    /// 15 = plain data cut by the virtual size; everything else unallocated.
    private func makeImage(clusterA: [UInt8], clusterB: [UInt8], clusterLast: [UInt8], backing: Bool = false) throws -> [UInt8] {
        let clusterBits: UInt32 = 12
        let cs = 1 << Int(clusterBits)
        let virtualSize: UInt64 = 16 * UInt64(cs) - 100
        var img = [UInt8](repeating: 0, count: 5 * cs)
        // Header.
        put(be32(QCOW2.magic), into: &img, at: 0)
        put(be32(3), into: &img, at: 4)
        put(be64(backing ? 4000 : 0), into: &img, at: 8)
        put(be32(clusterBits), into: &img, at: 20)
        put(be64(virtualSize), into: &img, at: 24)
        put(be32(0), into: &img, at: 32)                         // no encryption
        put(be32(1), into: &img, at: 36)                         // l1_size
        put(be64(UInt64(cs)), into: &img, at: 40)                // L1 table at cluster 1
        put(be64(UInt64(4 * cs)), into: &img, at: 48)            // refcount table (unused here)
        put(be32(1), into: &img, at: 56)
        put(be64(0), into: &img, at: 72)                         // incompatible features
        put(be32(4), into: &img, at: 96)                         // refcount order
        put(be32(112), into: &img, at: 100)                      // header length
        img[104] = 0                                             // compression type: deflate
        // L1 -> L2 at cluster 2 (with the COPIED flag).
        put(be64(UInt64(2 * cs) | (1 << 63)), into: &img, at: cs)
        // Data cluster for guest cluster 0 at host cluster 3.
        put(clusterA, into: &img, at: 3 * cs)
        // Guest cluster 15 at host cluster 4.
        put(clusterLast, into: &img, at: 4 * cs)
        // Compressed cluster appended at an unaligned offset.
        let compressed = try XCTUnwrap(QCOW2.deflate(Data(clusterB)))
        let host = 5 * cs + 100
        put([UInt8](compressed), into: &img, at: host)
        let x: UInt64 = 62 - (UInt64(clusterBits) - 8)
        let extraSectors = UInt64((host % 512 + compressed.count + 511) / 512 - 1)
        let descriptor: UInt64 = (1 << 62) | (extraSectors << x) | UInt64(host)
        // L2 entries.
        let l2 = 2 * cs
        put(be64(UInt64(3 * cs) | (1 << 63)), into: &img, at: l2 + 0 * 8)
        put(be64(1), into: &img, at: l2 + 1 * 8)                 // zero cluster
        put(be64(descriptor), into: &img, at: l2 + 5 * 8)
        put(be64(UInt64(4 * cs) | (1 << 63)), into: &img, at: l2 + 15 * 8)
        return img
    }

    func testConvertsPlainZeroAndCompressedClusters() throws {
        let cs = 4096
        let a = (0..<cs).map { UInt8(($0 * 7 + 3) % 256) }
        let b = (0..<cs).map { UInt8(($0 / 16) % 251) }
        let last = [UInt8](repeating: 0x5A, count: cs)
        let img = try makeImage(clusterA: a, clusterB: b, clusterLast: last)

        let dir = try makeTemporaryDirectory("zvm-qcow2")
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("disk.qcow2")
        let dst = dir.appendingPathComponent("disk.img")
        try Data(img).write(to: src)
        XCTAssertTrue(QCOW2.isQCOW2(src))

        let header = try QCOW2.readHeader(FileSource(url: src))
        XCTAssertEqual(header.version, 3)
        XCTAssertEqual(header.clusterSize, cs)
        XCTAssertEqual(header.virtualSize, UInt64(16 * cs - 100))

        let fractions = Locked<[Double]>([])
        try QCOW2.convertToRaw(source: src, destination: dst) { f in fractions.update { $0.append(f) } }
        XCTAssertEqual(fractions.get().last, 1)

        let raw = try Data(contentsOf: dst)
        XCTAssertEqual(raw.count, 16 * cs - 100)
        XCTAssertEqual([UInt8](raw[0..<cs]), a)
        XCTAssertEqual([UInt8](raw[cs..<(2 * cs)]), [UInt8](repeating: 0, count: cs))
        XCTAssertEqual([UInt8](raw[(5 * cs)..<(6 * cs)]), b)
        XCTAssertEqual([UInt8](raw[(15 * cs)..<raw.count]), [UInt8](repeating: 0x5A, count: cs - 100))
        XCTAssertTrue(Bytes.isAllZero(raw[(6 * cs)..<(15 * cs)]))
        XCTAssertFalse(QCOW2.isQCOW2(dst))
    }

    func testRejectsBackingFilesAndGarbage() throws {
        let cs = 4096
        let img = try makeImage(clusterA: [UInt8](repeating: 1, count: cs), clusterB: [UInt8](repeating: 2, count: cs),
                                clusterLast: [UInt8](repeating: 3, count: cs), backing: true)
        let header = try QCOW2.readHeader(DataSource(Data(img)))
        XCTAssertThrowsError(try QCOW2.validate(header))
        XCTAssertThrowsError(try QCOW2.readHeader(DataSource(Data(count: 512))))
    }

    func testInflateRoundTrip() throws {
        let input = Data((0..<65536).map { UInt8(($0 / 3) % 200) })
        let packed = try XCTUnwrap(QCOW2.deflate(input))
        XCTAssertLessThan(packed.count, input.count)
        XCTAssertEqual(try QCOW2.inflate(packed + Data([1, 2, 3]), expectedSize: input.count), input)
        XCTAssertThrowsError(try QCOW2.inflate(Data([0xFF, 0xFF]), expectedSize: 4096))
    }
}

final class DownloadSupportTests: XCTestCase {
    func testContentRangeParsing() {
        let full = Downloader.parseContentRange("bytes 100-199/1000")
        XCTAssertEqual(full?.start, 100)
        XCTAssertEqual(full?.total, 1000)
        let unknownTotal = Downloader.parseContentRange("bytes 0-9/*")
        XCTAssertEqual(unknownTotal?.start, 0)
        XCTAssertNil(unknownTotal?.total ?? nil)
        let unsatisfiable = Downloader.parseContentRange("bytes */3221225472")
        XCTAssertNil(unsatisfiable?.start ?? nil)
        XCTAssertEqual(unsatisfiable?.total, 3_221_225_472)
        XCTAssertNil(Downloader.parseContentRange("items 1-2/3"))
    }

    func testResumeValidator() {
        let url = URL(fileURLWithPath: "/x")
        XCTAssertEqual(Downloader.ResumeInfo(url: url, etag: "\"abc\"", lastModified: "Mon", expectedBytes: nil).validator, "\"abc\"")
        XCTAssertEqual(Downloader.ResumeInfo(url: url, etag: "W/\"abc\"", lastModified: "Mon", expectedBytes: nil).validator, "Mon")
        XCTAssertNil(Downloader.ResumeInfo(url: url, etag: nil, lastModified: nil, expectedBytes: nil).validator)
        let progress = DownloadProgress(receivedBytes: 50, expectedBytes: 200, resumedFromBytes: 10)
        XCTAssertEqual(progress.fractionCompleted ?? -1, 0.25, accuracy: 1e-9)
        XCTAssertNil(DownloadProgress(receivedBytes: 1, expectedBytes: nil, resumedFromBytes: 0).fractionCompleted)
    }

    func testChecksumsFileParsing() {
        let text = """
            # comment
            ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad *noble-server-cloudimg-arm64.img
            0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef  ./debian-13-generic-arm64.raw
            nothex  file
            """
        let sums = Checksums.parse(text)
        XCTAssertEqual(sums.count, 2)
        XCTAssertEqual(sums["noble-server-cloudimg-arm64.img"], "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(sums["debian-13-generic-arm64.raw"], "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
    }

    func testDigests() throws {
        let abc = Data("abc".utf8)
        XCTAssertEqual(Checksums.hexDigest(of: abc, algorithm: .sha256),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(Checksums.hexDigest(of: abc, algorithm: .sha512),
                       "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
        let dir = try makeTemporaryDirectory("zvm-sum")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("f")
        try abc.write(to: file)
        XCTAssertEqual(try Checksums.hexDigest(of: file, algorithm: .sha256),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

final class ImageCatalogTests: XCTestCase {
    func testCatalogEntries() {
        XCTAssertEqual(ImageCatalog.all.count, 4)
        XCTAssertEqual(Set(ImageCatalog.all.map(\.id)).count, 4)
        for image in ImageCatalog.all {
            XCTAssertEqual(image.url.scheme, "https", image.id)
            XCTAssertEqual(image.checksumsURL?.scheme, "https", image.id)
            XCTAssertNotNil(image.checksumAlgorithm)
            XCTAssertGreaterThan(image.downloadBytes, 100 << 20)
            XCTAssertTrue(image.notes.contains("UNVERIFIED"), image.id)
        }
        let debianArm = ImageCatalog.image(id: "debian-13-arm64")
        XCTAssertEqual(debianArm?.fileName, "debian-13-generic-arm64.raw")
        XCTAssertEqual(debianArm?.format, .raw)
        XCTAssertEqual(debianArm?.checksumAlgorithm, .sha512)
        let ubuntuAmd = ImageCatalog.image(id: "ubuntu-24.04-amd64")
        XCTAssertEqual(ubuntuAmd?.fileName, "noble-server-cloudimg-amd64.img")
        XCTAssertEqual(ubuntuAmd?.format, .qcow2)
        XCTAssertEqual(ImageCatalog.forHost.count, 2)
        XCTAssertTrue(ImageCatalog.forHost.allSatisfy { $0.architecture == .host })
    }
}
