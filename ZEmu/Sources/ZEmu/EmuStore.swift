import Foundation
import ZCore

/// On-disk library of emulated machines and their images:
///
///     <root>/Machines/<uuid>/spec.json        the EmuSpec
///     <root>/Machines/<uuid>/states/*.v86state saved states (autosave.v86state is the rolling autosave)
///     <root>/Machines/<uuid>/disk.img          the machine's own blank disk (installs), when created
///     <root>/Images/<image-id>/...             catalogue images, shared by machines (EmuImagePreparer)
///     <root>/ISOs/...                          ISOs the user imported
///
/// `standard()` puts it in Application Support (`ZComputer/Emu`) and excludes it from iCloud/iTunes backup (multi-GB
/// images and states are re-creatable). Paths inside the store (and the app's Documents) are written to `spec.json`
/// as `zemu-store:` / `zemu-documents:` URLs because iOS moves the app container on updates.
public struct EmuStore: Sendable {
    public let root: URL
    /// The app's Documents directory (user ISOs), for portable paths in spec files.
    public let documents: URL?

    public static let specFileName = "spec.json"
    public static let stateExtension = "v86state"
    public static let autosaveName = "autosave.v86state"

    public init(root: URL, documents: URL? = nil) {
        self.root = root
        self.documents = documents
    }

    /// `~/Library/Application Support/ZComputer/Emu` (inside the app container), created and excluded from backup.
    public static func standard() throws -> EmuStore {
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = support.appendingPathComponent("ZComputer", isDirectory: true).appendingPathComponent("Emu", isDirectory: true)
        let documents = try? fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let store = EmuStore(root: root, documents: documents)
        try store.prepare()
        return store
    }

    /// Creates the folders and marks the root as excluded from backup.
    public func prepare() throws {
        let fm = FileManager.default
        for dir in [root, machinesDirectory, imagesDirectory, isoDirectory] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = root
        try url.setResourceValues(values)
    }

    // MARK: Layout

    public var machinesDirectory: URL { root.appendingPathComponent("Machines", isDirectory: true) }
    public var imagesDirectory: URL { root.appendingPathComponent("Images", isDirectory: true) }
    public var isoDirectory: URL { root.appendingPathComponent("ISOs", isDirectory: true) }

    public func machineDirectory(_ id: UUID) -> URL {
        machinesDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func specURL(_ id: UUID) -> URL { machineDirectory(id).appendingPathComponent(Self.specFileName) }
    public func statesDirectory(_ id: UUID) -> URL { machineDirectory(id).appendingPathComponent("states", isDirectory: true) }
    public func autosaveStateURL(_ id: UUID) -> URL { statesDirectory(id).appendingPathComponent(Self.autosaveName) }
    public func diskURL(_ id: UUID) -> URL { machineDirectory(id).appendingPathComponent("disk.img") }
    public func imageDirectory(_ imageID: String) -> URL {
        imagesDirectory.appendingPathComponent(Self.safeName(imageID), isDirectory: true)
    }

    /// A new, timestamped state file name for a manual save.
    public func newStateURL(_ id: UUID, date: Date = Date()) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return statesDirectory(id).appendingPathComponent("state-\(f.string(from: date)).\(Self.stateExtension)")
    }

    /// All saved states of a machine, newest first.
    public func states(_ id: UUID) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: statesDirectory(id), includingPropertiesForKeys: [.contentModificationDateKey],
                                                       options: [.skipsHiddenFiles]) else { return [] }
        let states = items.filter { $0.pathExtension == Self.stateExtension }
        func date(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return states.sorted { date($0) > date($1) }
    }

    /// The newest saved state (autosave or manual), if any.
    public func latestState(_ id: UUID) -> URL? { states(id).first }

    // MARK: Machines

    /// All machines with a readable spec, oldest first. Unreadable folders are skipped.
    public func list() throws -> [EmuSpec] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: machinesDirectory.path) else { return [] }
        let children = try fm.contentsOfDirectory(at: machinesDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var specs: [EmuSpec] = []
        for dir in children {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(Self.specFileName)),
                  let spec = try? decodeSpec(data) else { continue }
            specs.append(spec)
        }
        return specs.sorted { ($0.createdAt, $0.name) < ($1.createdAt, $1.name) }
    }

    public func load(id: UUID) throws -> EmuSpec {
        guard let data = try? Data(contentsOf: specURL(id)) else { throw ZError.notFound("machine \(id.uuidString)") }
        do { return try decodeSpec(data) } catch { throw ZError.decoding("spec.json of \(id.uuidString): \(error)") }
    }

    /// Writes `spec.json` (creating the machine folder).
    public func save(_ spec: EmuSpec) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: statesDirectory(spec.id), withIntermediateDirectories: true)
        try encodeSpec(spec).write(to: specURL(spec.id), options: .atomic)
    }

    /// Creates a machine. With `blankDiskBytes`, a sparse `disk.img` of that size is created and attached as `hda`
    /// (an install target next to an ISO).
    @discardableResult
    public func create(_ spec: EmuSpec, blankDiskBytes: UInt64? = nil) throws -> EmuSpec {
        var spec = spec
        let fm = FileManager.default
        guard !fm.fileExists(atPath: specURL(spec.id).path) else { throw ZError.invalidArgument("machine \(spec.id) exists") }
        try fm.createDirectory(at: statesDirectory(spec.id), withIntermediateDirectories: true)
        if let blankDiskBytes {
            let disk = diskURL(spec.id)
            try Self.createSparseFile(at: disk, bytes: blankDiskBytes)
            if case .iso = spec.boot { spec.hda = disk } else { spec.boot = .disk(disk) }
        }
        try save(spec)
        return spec
    }

    /// Deletes a machine folder (its states and own disk). Shared catalogue images stay.
    public func delete(id: UUID) throws {
        let dir = machineDirectory(id)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try FileManager.default.removeItem(at: dir)
    }

    /// Copies an ISO into `ISOs/` (unique name) and returns the copy.
    public func importISO(from source: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: isoDirectory, withIntermediateDirectories: true)
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        var target = isoDirectory.appendingPathComponent(Self.safeName(source.lastPathComponent))
        var n = 1
        let base = target.deletingPathExtension().lastPathComponent
        let ext = target.pathExtension
        while fm.fileExists(atPath: target.path) {
            n += 1
            target = isoDirectory.appendingPathComponent("\(base)-\(n)" + (ext.isEmpty ? "" : ".\(ext)"))
        }
        try fm.copyItem(at: source, to: target)
        return target
    }

    /// Creates (or truncates to) a sparse file of `bytes`.
    public static func createSparseFile(at url: URL, bytes: UInt64) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { _ = fm.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: bytes)
    }

    /// File-system-safe name (letters, digits, `.-_`).
    static func safeName(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let mapped = String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return mapped.isEmpty ? "unnamed" : mapped
    }

    // MARK: Portable paths

    static let storeScheme = "zemu-store"
    static let documentsScheme = "zemu-documents"

    /// Replaces file URLs inside the store or Documents with `zemu-store:` / `zemu-documents:` URLs.
    public func portable(_ url: URL) -> URL {
        guard url.isFileURL else { return url }
        let path = url.standardizedFileURL.path
        for (scheme, base) in bases {
            let basePath = base.standardizedFileURL.path
            if path.hasPrefix(basePath + "/") {
                let rel = String(path.dropFirst(basePath.count + 1))
                let encoded = rel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? rel
                if let u = URL(string: "\(scheme):\(encoded)") { return u }
            }
        }
        return url
    }

    /// Turns a portable URL back into a file URL in this container.
    public func resolve(_ url: URL) -> URL {
        guard let scheme = url.scheme, scheme != "file" else { return url }
        for (s, base) in bases where s == scheme {
            let raw = url.absoluteString.dropFirst(scheme.count + 1)
            let rel = String(raw).removingPercentEncoding ?? String(raw)
            return base.appendingPathComponent(rel)
        }
        return url
    }

    private var bases: [(String, URL)] {
        var b: [(String, URL)] = [(Self.storeScheme, root)]
        if let documents { b.append((Self.documentsScheme, documents)) }
        return b
    }

    /// Applies `transform` to every URL of a spec.
    static func mapURLs(_ spec: EmuSpec, _ transform: (URL) -> URL) -> EmuSpec {
        var s = spec
        switch s.boot {
        case .iso(let u): s.boot = .iso(transform(u))
        case .disk(let u): s.boot = .disk(transform(u))
        case .state(let u, let d): s.boot = .state(transform(u), disk: d.map(transform))
        }
        s.cdrom = s.cdrom.map(transform)
        s.hda = s.hda.map(transform)
        s.shareDirectory = s.shareDirectory.map(transform)
        return s
    }

    func encodeSpec(_ spec: EmuSpec) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(Self.mapURLs(spec, portable))
    }

    func decodeSpec(_ data: Data) throws -> EmuSpec {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return Self.mapURLs(try dec.decode(EmuSpec.self, from: data), resolve)
    }
}
