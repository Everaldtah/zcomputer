import Foundation
import ZCore

/// Minimal ISO 9660 image writer with a Joliet tree (long, lowercase names), enough for cloud-init NoCloud
/// seeds (`genisoimage -volid cidata -joliet` equivalent) and for test fixtures. Linux reads the Joliet names.
public struct ISO9660Builder {
    public static let sectorSize = 2048

    public var volumeIdentifier: String
    public var date: Date
    private var root = Node(name: "", isDirectory: true)

    public init(volumeIdentifier: String, date: Date = Date()) {
        self.volumeIdentifier = volumeIdentifier
        self.date = date
    }

    /// Adds a file; intermediate directories are created. Paths use "/" ("EFI/BOOT/BOOTAA64.EFI").
    public mutating func addFile(path: String, contents: Data) {
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return }
        root.insert(parts: parts[...], contents: contents)
    }

    /// Adds an empty directory.
    public mutating func addDirectory(path: String) {
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return }
        root.insertDirectory(parts: parts[...])
    }

    // MARK: Tree

    fileprivate final class Node {
        let name: String
        let isDirectory: Bool
        var contents = Data()
        var children: [Node] = []
        // Layout (filled by build()).
        var fileExtent: UInt32 = 0
        var dirExtent: [Bool: UInt32] = [:]     // keyed by "joliet"
        var dirSize: [Bool: UInt32] = [:]
        var number: [Bool: Int] = [:]           // path table directory number
        weak var parent: Node?

        init(name: String, isDirectory: Bool) { self.name = name; self.isDirectory = isDirectory }

        func child(named n: String) -> Node? { children.first { $0.name == n } }

        func insert(parts: ArraySlice<String>, contents: Data) {
            guard let first = parts.first else { return }
            if parts.count == 1 {
                children.removeAll { $0.name == first }
                let f = Node(name: first, isDirectory: false)
                f.contents = contents
                f.parent = self
                children.append(f)
                return
            }
            let dir: Node
            if let existing = child(named: first), existing.isDirectory { dir = existing } else {
                dir = Node(name: first, isDirectory: true)
                dir.parent = self
                children.append(dir)
            }
            dir.insert(parts: parts.dropFirst(), contents: contents)
        }

        func insertDirectory(parts: ArraySlice<String>) {
            guard let first = parts.first else { return }
            let dir: Node
            if let existing = child(named: first), existing.isDirectory { dir = existing } else {
                dir = Node(name: first, isDirectory: true)
                dir.parent = self
                children.append(dir)
            }
            dir.insertDirectory(parts: parts.dropFirst())
        }
    }

    // MARK: Names

    /// ISO 9660 identifier: d-characters (A–Z 0–9 _), files as NAME.EXT;1.
    static func primaryIdentifier(_ name: String, isDirectory: Bool) -> [UInt8] {
        func clean(_ s: Substring, max: Int) -> String {
            let mapped = s.uppercased().map { ch -> Character in
                if ch.isASCII, ch.isLetter || ch.isNumber || ch == "_" { return ch }
                return "_"
            }
            return String(String(mapped).prefix(max))
        }
        if isDirectory { return Array(clean(Substring(name), max: 31).utf8) }
        let base: Substring
        let ext: Substring
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            base = name[..<dot]
            ext = name[name.index(after: dot)...]
        } else {
            base = Substring(name)
            ext = ""
        }
        return Array((clean(base, max: 24) + "." + clean(ext, max: 5) + ";1").utf8)
    }

    /// Joliet identifier: UCS-2 big-endian, at most 64 characters.
    static func jolietIdentifier(_ name: String) -> [UInt8] {
        var out: [UInt8] = []
        for unit in name.utf16.prefix(64) { out.append(UInt8(unit >> 8)); out.append(UInt8(unit & 0xFF)) }
        return out
    }

    private static func identifier(_ node: Node, joliet: Bool) -> [UInt8] {
        joliet ? jolietIdentifier(node.name) : primaryIdentifier(node.name, isDirectory: node.isDirectory)
    }

    private static func sortedChildren(_ node: Node, joliet: Bool) -> [Node] {
        node.children.sorted { identifier($0, joliet: joliet).lexicographicallyPrecedes(identifier($1, joliet: joliet)) }
    }

    // MARK: Build

    /// Serialises the image.
    public func build() -> Data {
        let ss = Self.sectorSize
        // Directories in path-table order (breadth first; children sorted), per tree.
        func directories(joliet: Bool) -> [Node] {
            var out: [Node] = [root]
            var i = 0
            while i < out.count {
                for c in Self.sortedChildren(out[i], joliet: joliet) where c.isDirectory { out.append(c) }
                i += 1
            }
            for (n, d) in out.enumerated() { d.number[joliet] = n + 1 }
            return out
        }
        let primaryDirs = directories(joliet: false)
        let jolietDirs = directories(joliet: true)

        func pathTableSize(_ dirs: [Node], joliet: Bool) -> Int {
            dirs.reduce(0) { acc, d in
                let len = d === root ? 1 : Self.identifier(d, joliet: joliet).count
                return acc + 8 + len + (len % 2)
            }
        }
        func directorySize(_ d: Node, joliet: Bool) -> Int {
            var size = 34 + 34   // "." and ".."
            for c in Self.sortedChildren(d, joliet: joliet) {
                let len = Self.recordLength(identifierLength: Self.identifier(c, joliet: joliet).count)
                if size % ss + len > ss { size = (size / ss + 1) * ss }
                size += len
            }
            return size
        }
        func sectors(_ bytes: Int) -> Int { max(1, (bytes + ss - 1) / ss) }

        let ptPrimary = pathTableSize(primaryDirs, joliet: false)
        let ptJoliet = pathTableSize(jolietDirs, joliet: true)
        var next = 19                                     // 16 PVD, 17 Joliet SVD, 18 terminator
        let ptLPrimary = next; next += sectors(ptPrimary)
        let ptMPrimary = next; next += sectors(ptPrimary)
        let ptLJoliet = next; next += sectors(ptJoliet)
        let ptMJoliet = next; next += sectors(ptJoliet)
        for (dirs, joliet) in [(primaryDirs, false), (jolietDirs, true)] {
            for d in dirs {
                let size = directorySize(d, joliet: joliet)
                d.dirExtent[joliet] = UInt32(next)
                d.dirSize[joliet] = UInt32(sectors(size) * ss)
                next += sectors(size)
            }
        }
        var files: [Node] = []
        func collectFiles(_ n: Node) {
            for c in n.children { if c.isDirectory { collectFiles(c) } else { files.append(c) } }
        }
        collectFiles(root)
        for f in files {
            f.fileExtent = UInt32(next)
            if !f.contents.isEmpty { next += sectors(f.contents.count) }
        }
        let totalSectors = next

        var image = [UInt8](repeating: 0, count: totalSectors * ss)
        func put(_ bytes: [UInt8], at offset: Int) {
            image.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }

        // Volume descriptors.
        put(volumeDescriptor(type: 1, joliet: false, totalSectors: totalSectors, pathTableSize: ptPrimary,
                             pathL: ptLPrimary, pathM: ptMPrimary), at: 16 * ss)
        put(volumeDescriptor(type: 2, joliet: true, totalSectors: totalSectors, pathTableSize: ptJoliet,
                             pathL: ptLJoliet, pathM: ptMJoliet), at: 17 * ss)
        var terminator = [UInt8](repeating: 0, count: ss)
        terminator[0] = 255
        terminator.replaceSubrange(1..<6, with: Array("CD001".utf8))
        terminator[6] = 1
        put(terminator, at: 18 * ss)

        // Path tables.
        for (dirs, joliet, lSector, mSector) in [(primaryDirs, false, ptLPrimary, ptMPrimary), (jolietDirs, true, ptLJoliet, ptMJoliet)] {
            var l: [UInt8] = []
            var m: [UInt8] = []
            for d in dirs {
                let ident: [UInt8] = d === root ? [0] : Self.identifier(d, joliet: joliet)
                let extent = d.dirExtent[joliet] ?? 0
                let parentNumber = UInt16(d.parent?.number[joliet] ?? 1)
                for bigEndian in [false, true] {
                    var rec: [UInt8] = [UInt8(ident.count), 0]
                    rec += bigEndian ? Self.be32(extent) : Self.le32(extent)
                    rec += bigEndian ? Self.be16(parentNumber) : Self.le16(parentNumber)
                    rec += ident
                    if ident.count % 2 == 1 { rec.append(0) }
                    if bigEndian { m += rec } else { l += rec }
                }
            }
            put(l, at: lSector * ss)
            put(m, at: mSector * ss)
        }

        // Directory extents.
        for (dirs, joliet) in [(primaryDirs, false), (jolietDirs, true)] {
            for d in dirs {
                var bytes: [UInt8] = []
                let selfExtent = d.dirExtent[joliet] ?? 0
                let selfSize = d.dirSize[joliet] ?? UInt32(ss)
                let parent = d.parent ?? d
                bytes += directoryRecord(identifier: [0], extent: selfExtent, size: selfSize, isDirectory: true)
                bytes += directoryRecord(identifier: [1], extent: parent.dirExtent[joliet] ?? selfExtent,
                                         size: parent.dirSize[joliet] ?? selfSize, isDirectory: true)
                for c in Self.sortedChildren(d, joliet: joliet) {
                    let rec: [UInt8]
                    if c.isDirectory {
                        rec = directoryRecord(identifier: Self.identifier(c, joliet: joliet), extent: c.dirExtent[joliet] ?? 0,
                                              size: c.dirSize[joliet] ?? UInt32(ss), isDirectory: true)
                    } else {
                        rec = directoryRecord(identifier: Self.identifier(c, joliet: joliet), extent: c.fileExtent,
                                              size: UInt32(c.contents.count), isDirectory: false)
                    }
                    if bytes.count % ss + rec.count > ss {
                        bytes += [UInt8](repeating: 0, count: ss - bytes.count % ss)
                    }
                    bytes += rec
                }
                put(bytes, at: Int(selfExtent) * ss)
            }
        }

        // File data.
        for f in files where !f.contents.isEmpty {
            put([UInt8](f.contents), at: Int(f.fileExtent) * ss)
        }
        return Data(image)
    }

    static func recordLength(identifierLength n: Int) -> Int { 33 + n + (n % 2 == 0 ? 1 : 0) }

    private func directoryRecord(identifier: [UInt8], extent: UInt32, size: UInt32, isDirectory: Bool) -> [UInt8] {
        var r: [UInt8] = [UInt8(Self.recordLength(identifierLength: identifier.count)), 0]
        r += Self.both32(extent)
        r += Self.both32(size)
        r += recordingDate()
        r.append(isDirectory ? 0x02 : 0x00)
        r += [0, 0]
        r += Self.both16(1)
        r.append(UInt8(identifier.count))
        r += identifier
        if identifier.count % 2 == 0 { r.append(0) }
        return r
    }

    private func volumeDescriptor(type: UInt8, joliet: Bool, totalSectors: Int, pathTableSize: Int,
                                  pathL: Int, pathM: Int) -> [UInt8] {
        var v = [UInt8](repeating: 0, count: Self.sectorSize)
        func set(_ bytes: [UInt8], _ offset: Int) { v.replaceSubrange(offset..<(offset + bytes.count), with: bytes) }
        func text(_ s: String, _ length: Int) -> [UInt8] {
            if joliet {
                var out = Self.jolietIdentifier(s)
                while out.count + 2 <= length { out += [0x00, 0x20] }
                if out.count < length { out.append(0x00) }
                return Array(out.prefix(length))
            }
            var out = Array(s.utf8.prefix(length))
            out += [UInt8](repeating: 0x20, count: length - out.count)
            return out
        }
        v[0] = type
        set(Array("CD001".utf8), 1)
        v[6] = 1
        set(text("", 32), 8)                            // system identifier
        set(text(volumeIdentifier, 32), 40)             // volume identifier
        set(Self.both32(UInt32(totalSectors)), 80)      // volume space size
        if joliet { set([0x25, 0x2F, 0x45], 88) }       // UCS-2 level 3 escape sequence "%/E"
        set(Self.both16(1), 120)                        // volume set size
        set(Self.both16(1), 124)                        // volume sequence number
        set(Self.both16(UInt16(Self.sectorSize)), 128)  // logical block size
        set(Self.both32(UInt32(pathTableSize)), 132)
        set(Self.le32(UInt32(pathL)), 140)
        set(Self.be32(UInt32(pathM)), 148)
        let rootExtent = root.dirExtent[joliet] ?? 0
        let rootSize = root.dirSize[joliet] ?? UInt32(Self.sectorSize)
        set(directoryRecord(identifier: [0], extent: rootExtent, size: rootSize, isDirectory: true), 156)
        set(text("", 128), 190)                         // volume set
        set(text("", 128), 318)                         // publisher
        set(text("", 128), 446)                         // data preparer
        set(text("ZCOMPUTER", 128), 574)                // application
        set(text("", 37), 702)
        set(text("", 37), 739)
        set(text("", 37), 776)
        let stamp = volumeDate()
        set(stamp, 813)
        set(stamp, 830)
        set(Array("0000000000000000".utf8) + [0], 847)
        set(stamp, 864)
        v[881] = 1                                      // file structure version
        return v
    }

    private func utcComponents() -> DateComponents {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? TimeZone.current
        return cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    }

    private func recordingDate() -> [UInt8] {
        let c = utcComponents()
        return [UInt8(clamping: (c.year ?? 1970) - 1900), UInt8(clamping: c.month ?? 1), UInt8(clamping: c.day ?? 1),
                UInt8(clamping: c.hour ?? 0), UInt8(clamping: c.minute ?? 0), UInt8(clamping: c.second ?? 0), 0]
    }

    private func volumeDate() -> [UInt8] {
        let c = utcComponents()
        func pad(_ v: Int, _ width: Int) -> String {
            let s = String(v)
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        let s = pad(c.year ?? 1970, 4) + pad(c.month ?? 1, 2) + pad(c.day ?? 1, 2) + pad(c.hour ?? 0, 2)
            + pad(c.minute ?? 0, 2) + pad(c.second ?? 0, 2) + "00"
        return Array(s.utf8) + [0]
    }

    static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    static func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    static func both16(_ v: UInt16) -> [UInt8] { le16(v) + be16(v) }
    static func both32(_ v: UInt32) -> [UInt8] { le32(v) + be32(v) }
}

/// Read-only ISO 9660 access (primary and Joliet trees, El Torito boot catalog).
public final class ISO9660Reader {
    public struct Entry: Sendable, Hashable {
        public var name: String
        public var isDirectory: Bool
        public var extent: UInt32
        public var size: UInt32
    }

    /// An El Torito boot entry.
    public struct BootEntry: Sendable, Hashable {
        /// 0x00 = x86 BIOS, 0xEF = UEFI.
        public var platformID: UInt8
        public var loadSector: UInt32
        /// In 512-byte units (often 0 or 1 for EFI images, i.e. unreliable).
        public var sectorCount: UInt16
        public var isEFI: Bool { platformID == 0xEF }
    }

    private let source: any RandomAccessSource
    public let primaryVolumeIdentifier: String
    public let jolietVolumeIdentifier: String?
    private let primaryRoot: Entry
    private let jolietRoot: Entry?
    public let bootCatalogSector: UInt32?

    public init(source: any RandomAccessSource) throws {
        self.source = source
        var primary: (String, Entry)?
        var joliet: (String, Entry)?
        var catalog: UInt32?
        var sector: UInt64 = 16
        while sector < 16 + 64 {
            let vd = try source.read(at: sector * 2048, count: 2048)
            guard vd.count == 2048, Bytes.slice(vd, 1, 5) == Data("CD001".utf8) else { break }
            let type = Bytes.byte(vd, 0)
            if type == 255 { break }
            if type == 0 {
                let ident = String(decoding: Bytes.slice(vd, 7, 32), as: UTF8.self)
                if ident.hasPrefix("EL TORITO SPECIFICATION") { catalog = Bytes.u32le(vd, 71) }
            } else if type == 1, primary == nil {
                let id = String(decoding: Bytes.slice(vd, 40, 32), as: UTF8.self).trimmingCharacters(in: .whitespaces)
                if let root = Self.parseRecord(Bytes.slice(vd, 156, 34), joliet: false) { primary = (id, root) }
            } else if type == 2 {
                let esc = Bytes.slice(vd, 88, 3)
                if esc == Data([0x25, 0x2F, 0x40]) || esc == Data([0x25, 0x2F, 0x43]) || esc == Data([0x25, 0x2F, 0x45]) {
                    let id = Self.decodeUCS2(Bytes.slice(vd, 40, 32)).trimmingCharacters(in: .whitespaces)
                    if let root = Self.parseRecord(Bytes.slice(vd, 156, 34), joliet: true) { joliet = (id, root) }
                }
            }
            sector += 1
        }
        guard let primary else { throw ZError.invalidArgument("not an ISO 9660 image (no primary volume descriptor)") }
        primaryVolumeIdentifier = primary.0
        primaryRoot = primary.1
        jolietVolumeIdentifier = joliet?.0
        jolietRoot = joliet?.1
        bootCatalogSector = catalog
    }

    public convenience init(url: URL) throws {
        try self.init(source: try FileSource(url: url))
    }

    public var hasJoliet: Bool { jolietRoot != nil }

    /// Entries of a directory ("/" or "EFI/BOOT"); names are compared case-insensitively.
    public func list(_ path: String, joliet: Bool = true) throws -> [Entry] {
        let dir = try resolve(path, joliet: joliet)
        guard dir.isDirectory else { throw ZError.invalidArgument("\(path) is not a directory") }
        return try readDirectory(dir, joliet: joliet && jolietRoot != nil)
    }

    /// The entry at `path`, or nil.
    public func entry(at path: String, joliet: Bool = true) -> Entry? {
        try? resolve(path, joliet: joliet)
    }

    public func contents(of entry: Entry, limit: Int = 64 << 20) throws -> Data {
        try source.read(at: UInt64(entry.extent) * 2048, count: min(Int(entry.size), limit))
    }

    /// El Torito boot entries (empty when the image is not bootable).
    public func bootEntries() throws -> [BootEntry] {
        guard let catalog = bootCatalogSector else { return [] }
        let data = try source.read(at: UInt64(catalog) * 2048, count: 2048)
        guard data.count >= 64, Bytes.byte(data, 0) == 0x01 else { return [] }
        var entries: [BootEntry] = []
        var platform = Bytes.byte(data, 1)
        func entry(at o: Int, platform: UInt8) -> BootEntry? {
            let indicator = Bytes.byte(data, o)
            guard indicator == 0x88 || indicator == 0x00 else { return nil }
            let lba = Bytes.u32le(data, o + 8)
            guard lba != 0 else { return nil }
            return BootEntry(platformID: platform, loadSector: lba, sectorCount: Bytes.u16le(data, o + 6))
        }
        if let e = entry(at: 32, platform: platform) { entries.append(e) }
        var o = 64
        while o + 32 <= data.count {
            let header = Bytes.byte(data, o)
            guard header == 0x90 || header == 0x91 else { break }
            platform = Bytes.byte(data, o + 1)
            let count = Int(Bytes.u16le(data, o + 2))
            o += 32
            for _ in 0..<count where o + 32 <= data.count {
                if let e = entry(at: o, platform: platform) { entries.append(e) }
                o += 32
            }
            if header == 0x91 { break }
        }
        return entries
    }

    // MARK: Internals

    private func resolve(_ path: String, joliet: Bool) throws -> Entry {
        let useJoliet = joliet && jolietRoot != nil
        var current = useJoliet ? (jolietRoot ?? primaryRoot) : primaryRoot
        for part in path.split(separator: "/") where !part.isEmpty {
            let children = try readDirectory(current, joliet: useJoliet)
            guard let next = children.first(where: { $0.name.caseInsensitiveCompare(String(part)) == .orderedSame }) else {
                throw ZError.notFound(path)
            }
            current = next
        }
        return current
    }

    private func readDirectory(_ dir: Entry, joliet: Bool) throws -> [Entry] {
        let data = try source.read(at: UInt64(dir.extent) * 2048, count: Int(min(dir.size, 16 << 20)))
        var out: [Entry] = []
        var o = 0
        while o < data.count {
            let len = Int(Bytes.byte(data, o))
            if len == 0 {
                o = (o / 2048 + 1) * 2048       // records never cross sectors; zero padding up to the next one
                continue
            }
            if let e = Self.parseRecord(Bytes.slice(data, o, len), joliet: joliet), e.name != "." && e.name != ".." {
                out.append(e)
            }
            o += len
        }
        return out
    }

    static func parseRecord(_ r: Data, joliet: Bool) -> Entry? {
        guard r.count >= 34 else { return nil }
        let extent = Bytes.u32le(r, 2)
        let size = Bytes.u32le(r, 10)
        let flags = Bytes.byte(r, 25)
        let nameLength = Int(Bytes.byte(r, 32))
        let ident = Bytes.slice(r, 33, nameLength)
        var name: String
        if nameLength == 1 && Bytes.byte(ident, 0) == 0 {
            name = "."
        } else if nameLength == 1 && Bytes.byte(ident, 0) == 1 {
            name = ".."
        } else if joliet {
            name = decodeUCS2(ident)
        } else {
            name = String(decoding: ident, as: UTF8.self)
        }
        if let semicolon = name.firstIndex(of: ";") { name = String(name[..<semicolon]) }
        if !joliet, name.hasSuffix("."), name != ".", name != ".." { name.removeLast() }
        return Entry(name: name, isDirectory: flags & 0x02 != 0, extent: extent, size: size)
    }

    static func decodeUCS2(_ d: Data) -> String {
        var units: [UInt16] = []
        var i = 0
        while i + 1 < d.count {
            units.append(UInt16(Bytes.byte(d, i)) << 8 | UInt16(Bytes.byte(d, i + 1)))
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }
}
