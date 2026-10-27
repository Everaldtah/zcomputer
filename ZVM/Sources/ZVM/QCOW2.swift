import Compression
import Foundation
import ZCore

/// qcow2 → sparse RAW conversion. Virtualization.framework only attaches RAW (or ASIF) disks, while Ubuntu ships
/// its cloud images as compressed qcow2. Supports versions 2 and 3, deflate-compressed clusters, zero clusters;
/// rejects backing files, encryption, external data files, extended L2 entries and zstd compression.
public enum QCOW2 {
    public static let magic: UInt32 = 0x5146_49FB   // "QFI\xfb"

    public struct Header: Sendable, Hashable {
        public var version: UInt32
        public var backingFileOffset: UInt64
        public var clusterBits: UInt32
        public var virtualSize: UInt64
        public var cryptMethod: UInt32
        public var l1Size: UInt32
        public var l1TableOffset: UInt64
        public var incompatibleFeatures: UInt64
        /// 0 = deflate (zlib), 1 = zstd.
        public var compressionType: UInt8

        public var clusterSize: Int { 1 << Int(clusterBits) }
    }

    /// True when the file starts with the qcow2 magic.
    public static func isQCOW2(_ url: URL) -> Bool {
        guard let source = try? FileSource(url: url), let head = try? source.read(at: 0, count: 4) else { return false }
        return head.count == 4 && Bytes.u32be(head, 0) == magic
    }

    public static func readHeader(_ source: any RandomAccessSource) throws -> Header {
        let h = try source.read(at: 0, count: 112)
        guard h.count >= 72, Bytes.u32be(h, 0) == magic else { throw ZError.invalidArgument("not a qcow2 image") }
        var header = Header(version: Bytes.u32be(h, 4), backingFileOffset: Bytes.u64be(h, 8),
                            clusterBits: Bytes.u32be(h, 20), virtualSize: Bytes.u64be(h, 24),
                            cryptMethod: Bytes.u32be(h, 32), l1Size: Bytes.u32be(h, 36),
                            l1TableOffset: Bytes.u64be(h, 40), incompatibleFeatures: 0, compressionType: 0)
        if header.version >= 3, h.count >= 104 {
            header.incompatibleFeatures = Bytes.u64be(h, 72)
            let headerLength = Bytes.u32be(h, 100)
            if headerLength > 104 { header.compressionType = Bytes.byte(h, 104) }
        }
        return header
    }

    /// Throws when the image uses a feature this converter does not support.
    public static func validate(_ h: Header) throws {
        guard h.version == 2 || h.version == 3 else { throw ZError.unsupported("qcow2 version \(h.version)") }
        guard (9...21).contains(h.clusterBits) else { throw ZError.unsupported("qcow2 cluster_bits \(h.clusterBits)") }
        guard h.backingFileOffset == 0 else { throw ZError.unsupported("qcow2 images with a backing file") }
        guard h.cryptMethod == 0 else { throw ZError.unsupported("encrypted qcow2 images") }
        // Bit 0 dirty (fine for reading), 1 corrupt, 2 external data file, 3 compression type, 4 extended L2.
        if h.incompatibleFeatures & 0b10 != 0 { throw ZError.vm("the qcow2 image is marked corrupt") }
        if h.incompatibleFeatures & 0b100 != 0 { throw ZError.unsupported("qcow2 external data files") }
        if h.incompatibleFeatures & 0b1_0000 != 0 { throw ZError.unsupported("qcow2 extended L2 entries") }
        if h.incompatibleFeatures & ~UInt64(0b1_1111) != 0 { throw ZError.unsupported("unknown qcow2 features") }
        guard h.compressionType == 0 else { throw ZError.unsupported("zstd-compressed qcow2 images") }
        guard UInt64(h.l1Size) * 8 <= 512 << 20 else { throw ZError.vm("qcow2 L1 table too large") }
    }

    /// Converts `source` into a new sparse RAW file at `destination` (replaced if present).
    /// Only non-zero clusters are written, so the RAW file stays sparse on APFS.
    public static func convertToRaw(source: URL, destination: URL, progress: (@Sendable (Double) -> Void)? = nil) throws {
        let input = try FileSource(url: source)
        let fm = FileManager.default
        let tmp = destination.appendingPathExtension("converting")
        try? fm.removeItem(at: tmp)
        guard fm.createFile(atPath: tmp.path, contents: nil) else { throw ZError.vm("cannot create \(tmp.path)") }
        do {
            let handle = try FileHandle(forWritingTo: tmp)
            defer { try? handle.close() }
            try convert(input, into: handle, progress: progress)
            try handle.synchronize()
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: tmp, to: destination)
    }

    /// Converts into an open handle (the file is sized to the virtual size first).
    public static func convert(_ source: any RandomAccessSource, into handle: FileHandle,
                               progress: (@Sendable (Double) -> Void)? = nil) throws {
        let header = try readHeader(source)
        try validate(header)
        let cs = header.clusterSize
        let l2Entries = cs / 8
        try handle.truncate(atOffset: header.virtualSize)

        let l1Bytes = Int(header.l1Size) * 8
        let l1 = try source.read(at: header.l1TableOffset, count: l1Bytes)
        guard l1.count == l1Bytes else { throw ZError.vm("qcow2: truncated L1 table") }

        let offsetMask: UInt64 = 0x00FF_FFFF_FFFF_FE00
        let compressedFlag: UInt64 = 1 << 62
        let x = 62 - (Int(header.clusterBits) - 8)
        let hostMask: UInt64 = (UInt64(1) << UInt64(x)) - 1
        let sectorsMask: UInt64 = (UInt64(1) << UInt64(62 - x)) - 1
        let total = max(1, Int(header.l1Size))

        for i in 0..<Int(header.l1Size) {
            progress?(Double(i) / Double(total))
            let l2Offset = Bytes.u64be(l1, i * 8) & offsetMask
            if l2Offset == 0 { continue }
            let l2 = try source.read(at: l2Offset, count: cs)
            guard l2.count == cs else { throw ZError.vm("qcow2: truncated L2 table") }
            for j in 0..<l2Entries {
                let guest = (UInt64(i) * UInt64(l2Entries) + UInt64(j)) * UInt64(cs)
                if guest >= header.virtualSize { break }
                let entry = Bytes.u64be(l2, j * 8)
                if entry == 0 { continue }
                let want = Int(min(UInt64(cs), header.virtualSize - guest))
                var cluster: Data
                if entry & compressedFlag != 0 {
                    let host = entry & hostMask
                    let extraSectors = (entry >> UInt64(x)) & sectorsMask
                    let length = Int((extraSectors + 1) * 512 - (host & 511))
                    let compressed = try source.read(at: host, count: length)
                    cluster = try inflate(compressed, expectedSize: cs)
                } else {
                    if header.version >= 3 && entry & 1 != 0 { continue }   // reads as zeros
                    let host = entry & offsetMask
                    if host == 0 { continue }
                    cluster = try source.read(at: host, count: cs)
                    if cluster.count < cs { cluster.append(Data(count: cs - cluster.count)) }
                }
                if cluster.count > want { cluster = Data(cluster.prefix(want)) }
                if Bytes.isAllZero(cluster) { continue }
                try handle.seek(toOffset: guest)
                try handle.write(contentsOf: cluster)
            }
        }
        progress?(1)
    }

    /// Raw DEFLATE (RFC 1951) decoding of one cluster. Apple's `COMPRESSION_ZLIB` is raw deflate, like qemu's.
    static func inflate(_ input: Data, expectedSize: Int) throws -> Data {
        guard !input.isEmpty, expectedSize > 0 else { throw ZError.vm("qcow2: empty compressed cluster") }
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let d = dst.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let s = src.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                return compression_decode_buffer(d, expectedSize, s, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else {
            throw ZError.vm("qcow2: corrupt compressed cluster (\(written) of \(expectedSize) bytes)")
        }
        return output
    }

    /// Raw DEFLATE encoding (used by tests to build fixtures).
    static func deflate(_ input: Data) -> Data? {
        guard !input.isEmpty else { return nil }
        let capacity = input.count + 1024
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let d = dst.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let s = src.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                return compression_encode_buffer(d, capacity, s, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return Data(output.prefix(written))
    }
}
