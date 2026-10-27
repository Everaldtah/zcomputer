import Foundation
import ZCore

/// On-disk layout of one VM: `<root>/<id>/`.
public struct VMBundle: Sendable, Hashable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// `spec.json` — the `VMSpec`.
    public var specURL: URL { root.appendingPathComponent("spec.json") }
    /// `disk.img` — sparse RAW boot disk.
    public var diskURL: URL { root.appendingPathComponent("disk.img") }
    /// `efi-vars` — `VZEFIVariableStore` (Linux guests).
    public var efiVariablesURL: URL { root.appendingPathComponent("efi-vars") }
    /// `machine-id` — `VZGenericMachineIdentifier` (Linux) or `VZMacMachineIdentifier` (macOS) data representation.
    public var machineIdentifierURL: URL { root.appendingPathComponent("machine-id") }
    /// `aux` — `VZMacAuxiliaryStorage` (macOS guests).
    public var auxiliaryStorageURL: URL { root.appendingPathComponent("aux") }
    /// `hardware-model` — `VZMacHardwareModel` data representation (macOS guests).
    public var hardwareModelURL: URL { root.appendingPathComponent("hardware-model") }
    /// `mac-address` — the persisted NAT MAC address so the DHCP lease stays stable.
    public var macAddressURL: URL { root.appendingPathComponent("mac-address") }
    /// `seed.iso` — cloud-init NoCloud seed (attached read-only when present).
    public var seedImageURL: URL { root.appendingPathComponent("seed.iso") }
    /// `RestoreImage.ipsw` — downloaded macOS restore image.
    public var restoreImageURL: URL { root.appendingPathComponent("RestoreImage.ipsw") }

    public var exists: Bool { FileManager.default.fileExists(atPath: specURL.path) }
}

/// The VM library: `~/Library/Application Support/ZComputer/VMs/<id>/` (inside the app container when sandboxed).
public struct VMStore: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// The default location in Application Support (created on demand).
    public static func standard() throws -> VMStore {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let root = support.appendingPathComponent("ZComputer", isDirectory: true)
            .appendingPathComponent("VMs", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return VMStore(root: root)
    }

    public func bundle(for id: UUID) -> VMBundle {
        VMBundle(root: root.appendingPathComponent(id.uuidString, isDirectory: true))
    }

    // MARK: Listing

    /// All VMs with a readable `spec.json`, oldest first. Unreadable bundles are skipped.
    public func list() throws -> [VMSpec] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var specs: [VMSpec] = []
        for dir in children {
            let specURL = dir.appendingPathComponent("spec.json")
            guard let data = try? Data(contentsOf: specURL), let spec = try? Self.decoder.decode(VMSpec.self, from: data) else { continue }
            specs.append(spec)
        }
        return specs.sorted { ($0.createdAt, $0.name) < ($1.createdAt, $1.name) }
    }

    public func load(id: UUID) throws -> VMSpec {
        let b = bundle(for: id)
        guard let data = try? Data(contentsOf: b.specURL) else { throw ZError.notFound("VM \(id.uuidString)") }
        do { return try Self.decoder.decode(VMSpec.self, from: data) }
        catch { throw ZError.decoding("spec.json of \(id.uuidString): \(error)") }
    }

    // MARK: Mutations

    /// Creates the bundle directory and writes `spec.json`. With `createDisk` (the default for ISO installs and
    /// macOS guests) an empty sparse `disk.img` of `spec.diskBytes` is created too. Cloud-image VMs pass `false`:
    /// `ImagePreparer` writes their disk.
    @discardableResult
    public func create(_ spec: VMSpec, createDisk: Bool = true) throws -> VMBundle {
        let b = bundle(for: spec.id)
        let fm = FileManager.default
        if fm.fileExists(atPath: b.specURL.path) { throw ZError.invalidArgument("VM \(spec.id.uuidString) already exists") }
        try fm.createDirectory(at: b.root, withIntermediateDirectories: true)
        try save(spec)
        if createDisk && !fm.fileExists(atPath: b.diskURL.path) {
            try Self.createSparseDisk(at: b.diskURL, bytes: spec.diskBytes)
        }
        return b
    }

    /// Writes `spec.json` atomically.
    public func save(_ spec: VMSpec) throws {
        let b = bundle(for: spec.id)
        try FileManager.default.createDirectory(at: b.root, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(spec)
        try data.write(to: b.specURL, options: .atomic)
    }

    @discardableResult
    public func rename(id: UUID, to newName: String) throws -> VMSpec {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ZError.invalidArgument("empty VM name") }
        var spec = try load(id: id)
        spec.name = trimmed
        try save(spec)
        return spec
    }

    /// Deletes the whole bundle (disk included). The VM must be stopped.
    public func delete(id: UUID) throws {
        let b = bundle(for: id)
        guard FileManager.default.fileExists(atPath: b.root.path) else { throw ZError.notFound("VM \(id.uuidString)") }
        try FileManager.default.removeItem(at: b.root)
    }

    // MARK: Disks

    /// Creates a sparse RAW disk: logical size `bytes`, blocks allocated only when the guest writes them (APFS).
    /// Fails when the file already exists.
    public static func createSparseDisk(at url: URL, bytes: UInt64) throws {
        let fm = FileManager.default
        guard bytes > 0 else { throw ZError.invalidArgument("disk size must be > 0") }
        guard !fm.fileExists(atPath: url.path) else { throw ZError.invalidArgument("\(url.lastPathComponent) already exists") }
        guard fm.createFile(atPath: url.path, contents: nil) else { throw ZError.vm("cannot create \(url.path)") }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: bytes)
    }

    /// Grows a RAW disk to `bytes` (never shrinks). Returns true when the size changed.
    @discardableResult
    public static func growDisk(at url: URL, to bytes: UInt64) throws -> Bool {
        let current = try fileSize(url)
        guard bytes > current else { return false }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: bytes)
        return true
    }

    /// Logical size of a file in bytes.
    public static func fileSize(_ url: URL) throws -> UInt64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        if let n = attrs[.size] as? NSNumber { return n.uint64Value }
        throw ZError.vm("cannot read the size of \(url.path)")
    }

    /// Bytes actually allocated on disk (shows how sparse a disk image is).
    public static func allocatedSize(_ url: URL) -> UInt64? {
        guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
              let n = values.totalFileAllocatedSize else { return nil }
        return UInt64(n)
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    static var decoder: JSONDecoder { JSONDecoder() }
}
