import Foundation
import ZCore

/// The files to fetch for one Hugging Face repo. ZLocal only plans; the app downloads (with progress) into
/// `destination` and then calls `LocalModelStore.markInstalled(id:)`.
public struct DownloadPlan: Sendable, Hashable, Codable {
    public struct File: Sendable, Hashable, Codable {
        /// Path inside the repo (top level, e.g. `model.safetensors`).
        public var path: String
        /// `https://huggingface.co/<repo>/resolve/<revision>/<path>`.
        public var url: URL
        /// Size from the listing, when it has one.
        public var sizeBytes: Int64?
        /// LFS sha256, when listed (weights).
        public var sha256: String?

        public init(path: String, url: URL, sizeBytes: Int64? = nil, sha256: String? = nil) {
            self.path = path; self.url = url; self.sizeBytes = sizeBytes; self.sha256 = sha256
        }
    }

    public var repoID: String
    /// Commit sha when the listing reported one (so every file comes from the same commit), else the requested revision.
    public var revision: String
    public var files: [File]
    /// Local directory the files go into (`<root>/<org>/<repo>`).
    public var destination: URL

    public init(repoID: String, revision: String, files: [File], destination: URL) {
        self.repoID = repoID; self.revision = revision; self.files = files; self.destination = destination
    }

    /// Sum of known file sizes.
    public var totalBytes: Int64 { files.reduce(0) { $0 + ($1.sizeBytes ?? 0) } }

    public func localURL(for file: File) -> URL { destination.appendingPathComponent(file.path) }
}

/// A model found on disk.
public struct InstalledLocalModel: Sendable, Hashable, Codable, Identifiable {
    /// HF repo id (`<org>/<repo>`).
    public var id: String
    public var directory: URL
    public var sizeBytes: Int64
    /// False while the app is still downloading (the `.incomplete` marker exists).
    public var isComplete: Bool
    /// Catalogue entry when this is a curated model.
    public var spec: LocalModelSpec?

    public init(id: String, directory: URL, sizeBytes: Int64, isComplete: Bool, spec: LocalModelSpec?) {
        self.id = id; self.directory = directory; self.sizeBytes = sizeBytes; self.isComplete = isComplete; self.spec = spec
    }
}

/// Tracks MLX models downloaded under `root/<org>/<repo>` (default
/// `~/Library/Application Support/ZComputer/Models`) and plans downloads from the Hugging Face API.
public actor LocalModelStore {
    public static let huggingFaceBase = "https://huggingface.co"
    /// Marker file present while a download is in progress.
    public static let incompleteMarker = ".incomplete"

    public let root: URL
    private let transport: any LocalTransport

    public init(root: URL, transport: any LocalTransport = URLSessionLocalTransport()) {
        self.root = root
        self.transport = transport
    }

    /// `~/Library/Application Support/ZComputer/Models` (on Linux, the XDG data dir equivalent).
    public static func defaultRoot() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: false)
        return base.appendingPathComponent("ZComputer", isDirectory: true).appendingPathComponent("Models", isDirectory: true)
    }

    // MARK: Ids and paths

    /// Validates `<org>/<repo>` (letters, digits, `-`, `_`, `.`; no `..`) and returns its two parts.
    public static func splitRepoID(_ id: String) throws -> (org: String, repo: String) {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { throw ZError.invalidArgument("model id must be <org>/<repo>: \(id)") }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        for part in parts {
            guard !part.isEmpty, part != ".", part != "..", !part.hasPrefix("."),
                  part.unicodeScalars.allSatisfy({ allowed.contains($0) && $0.isASCII })
            else { throw ZError.invalidArgument("invalid model id: \(id)") }
        }
        return (parts[0], parts[1])
    }

    /// `<root>/<org>/<repo>` for a repo id.
    public func directory(for id: String) throws -> URL {
        let (org, repo) = try Self.splitRepoID(id)
        return root.appendingPathComponent(org, isDirectory: true).appendingPathComponent(repo, isDirectory: true)
    }

    // MARK: Installed models

    /// Every complete model on disk, sorted by id.
    public var installed: [InstalledLocalModel] { scan().filter(\.isComplete) }

    /// Models still downloading (marker present).
    public var incomplete: [InstalledLocalModel] { scan().filter { !$0.isComplete } }

    public func isInstalled(_ id: String) -> Bool {
        guard let dir = try? directory(for: id) else { return false }
        return Self.looksInstalled(dir)
    }

    /// Bytes on disk for a model (0 when absent).
    public func sizeOnDisk(id: String) -> Int64 {
        guard let dir = try? directory(for: id) else { return 0 }
        return Self.directorySize(dir)
    }

    /// Total bytes used by all models under the root.
    public func totalSizeOnDisk() -> Int64 { Self.directorySize(root) }

    /// Removes a model's directory (and its org directory when that becomes empty).
    public func delete(id: String) throws {
        let dir = try directory(for: id)
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { throw ZError.notFound("model \(id) is not installed") }
        try fm.removeItem(at: dir)
        let orgDir = dir.deletingLastPathComponent()
        if let rest = try? fm.contentsOfDirectory(atPath: orgDir.path), rest.isEmpty {
            try? fm.removeItem(at: orgDir)
        }
    }

    /// Creates the model directory and drops the `.incomplete` marker; call before downloading.
    @discardableResult
    public func prepareDirectory(for id: String) throws -> URL {
        let dir = try directory(for: id)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let marker = dir.appendingPathComponent(Self.incompleteMarker)
        if !fm.fileExists(atPath: marker.path) {
            guard fm.createFile(atPath: marker.path, contents: Data()) else {
                throw ZError.invalidArgument("cannot write \(marker.path)")
            }
        }
        Self.excludeFromBackup(root)
        return dir
    }

    /// Clears the `.incomplete` marker once every planned file is on disk. Throws listing the missing files otherwise.
    public func markInstalled(id: String, plan: DownloadPlan? = nil) throws {
        let dir = try directory(for: id)
        if let plan {
            let missing = missingFiles(in: plan)
            guard missing.isEmpty else {
                throw ZError.invalidArgument("download incomplete, missing: " + missing.map(\.path).joined(separator: ", "))
            }
        }
        let marker = dir.appendingPathComponent(Self.incompleteMarker)
        if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
    }

    /// Planned files that are absent or whose size differs from the listing.
    public nonisolated func missingFiles(in plan: DownloadPlan) -> [DownloadPlan.File] {
        plan.files.filter { file in
            let path = plan.localURL(for: file).path
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return true }
            guard let expected = file.sizeBytes else { return false }
            return Self.int64(attrs[.size]) != expected
        }
    }

    private func scan() -> [InstalledLocalModel] {
        let fm = FileManager.default
        guard let orgs = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var out: [InstalledLocalModel] = []
        for org in orgs where !org.hasPrefix(".") {
            let orgDir = root.appendingPathComponent(org, isDirectory: true)
            guard Self.isDirectory(orgDir), let repos = try? fm.contentsOfDirectory(atPath: orgDir.path) else { continue }
            for repo in repos where !repo.hasPrefix(".") {
                let dir = orgDir.appendingPathComponent(repo, isDirectory: true)
                guard Self.isDirectory(dir) else { continue }
                let id = "\(org)/\(repo)"
                let downloading = fm.fileExists(atPath: dir.appendingPathComponent(Self.incompleteMarker).path)
                guard downloading || Self.looksInstalled(dir) else { continue }
                out.append(InstalledLocalModel(id: id, directory: dir, sizeBytes: Self.directorySize(dir),
                                               isComplete: !downloading, spec: LocalModelCatalog.byID(id)))
            }
        }
        return out.sorted { $0.id < $1.id }
    }

    /// A complete MLX model dir has `config.json`, at least one `.safetensors`, and no `.incomplete` marker.
    static func looksInstalled(_ dir: URL) -> Bool {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
        return names.contains("config.json") && names.contains(where: { $0.hasSuffix(".safetensors") })
            && !names.contains(incompleteMarker)
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func directorySize(_ dir: URL) -> Int64 {
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: dir.path) else { return 0 }
        var total: Int64 = 0
        while let rel = walker.nextObject() as? String {
            let path = dir.appendingPathComponent(rel).path
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  (attrs[.type] as? FileAttributeType) == .typeRegular else { continue }
            total += int64(attrs[.size])
        }
        return total
    }

    static func int64(_ value: Any?) -> Int64 {
        if let n = value as? NSNumber { return n.int64Value }
        if let n = value as? Int64 { return n }
        if let n = value as? Int { return Int64(n) }
        if let n = value as? UInt64 { return Int64(clamping: n) }
        return 0
    }

    static func excludeFromBackup(_ url: URL) {
        #if canImport(Darwin)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try? target.setResourceValues(values)
        #endif
    }

    // MARK: Download planning

    /// Lists a repo through the Hugging Face API (`/api/models/<id>?blobs=true`, or `/revision/<rev>`) and keeps the
    /// top-level weights, JSON and tokenizer files. `token` is an optional HF token for gated repos.
    public func downloadPlan(for id: String, revision: String = "main", token: String? = nil,
                             timeout: TimeInterval = 20) async throws -> DownloadPlan {
        let destination = try directory(for: id)
        guard let url = Self.listingURL(for: id, revision: revision) else {
            throw ZError.invalidArgument("cannot build listing URL for \(id)@\(revision)")
        }
        var headers = ["Accept": "application/json"]
        if let token, !token.isEmpty { headers["Authorization"] = "Bearer \(token)" }
        let response: LocalHTTPResponse
        do {
            response = try await transport.send(LocalHTTPRequest(method: "GET", url: url, headers: headers, timeout: timeout))
        } catch let error as LocalTransportError {
            switch error {
            case .timedOut: throw ZError.network("Hugging Face listing timed out for \(id)")
            case .connectionFailed(let message): throw ZError.network(message)
            }
        }
        switch response.status {
        case 200..<300: break
        case 404: throw ZError.notFound("Hugging Face repo \(id)@\(revision)")
        case 429: throw ZError.rateLimited(retryAfter: nil)
        default: throw ZError.http(status: response.status, body: response.text)
        }
        let listing: JSONValue
        do { listing = try JSONValue.parse(response.data) } catch {
            throw ZError.decoding("Hugging Face listing for \(id): \(error)")
        }
        return try Self.plan(fromListing: listing, repoID: id, revision: revision, destination: destination)
    }

    static func listingURL(for id: String, revision: String) -> URL? {
        guard let revEncoded = revision.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/")))
        else { return nil }
        let path = revision == "main" ? "/api/models/\(id)" : "/api/models/\(id)/revision/\(revEncoded)"
        return URL(string: huggingFaceBase + path + "?blobs=true")
    }

    /// Builds a plan from either listing shape: model info `{"sha", "siblings": [{"rfilename", "size", "lfs"}]}` or
    /// the tree API `[{"type": "file", "path", "size", "lfs": {"oid", "size"}}]`.
    static func plan(fromListing listing: JSONValue, repoID: String, revision: String, destination: URL) throws -> DownloadPlan {
        struct Entry { let path: String; let size: Int64?; let sha: String? }
        var entries: [Entry] = []
        var commit: String?
        if let siblings = listing["siblings"]?.arrayValue {
            commit = listing["sha"]?.stringValue
            for s in siblings {
                guard let path = s["rfilename"]?.stringValue else { continue }
                let size = (s["lfs"]?["size"]?.doubleValue ?? s["size"]?.doubleValue).map { Int64($0) }
                entries.append(Entry(path: path, size: size, sha: s["lfs"]?["sha256"]?.stringValue ?? s["lfs"]?["oid"]?.stringValue))
            }
        } else if let tree = listing.arrayValue {
            for t in tree where (t["type"]?.stringValue ?? "file") == "file" {
                guard let path = t["path"]?.stringValue else { continue }
                let size = (t["lfs"]?["size"]?.doubleValue ?? t["size"]?.doubleValue).map { Int64($0) }
                entries.append(Entry(path: path, size: size, sha: t["lfs"]?["oid"]?.stringValue ?? t["lfs"]?["sha256"]?.stringValue))
            }
        } else {
            throw ZError.decoding("unexpected Hugging Face listing for \(repoID)")
        }

        let pinned = commit.flatMap { $0.isEmpty ? nil : $0 } ?? revision
        var files: [DownloadPlan.File] = []
        for e in entries where isModelFile(e.path) {
            guard let url = resolveURL(repoID: repoID, revision: pinned, path: e.path) else { continue }
            files.append(DownloadPlan.File(path: e.path, url: url, sizeBytes: e.size, sha256: e.sha))
        }
        files.sort { $0.path < $1.path }
        guard files.contains(where: { $0.path.hasSuffix(".safetensors") }) else {
            throw ZError.unsupported("\(repoID) has no top-level .safetensors weights (not an MLX/safetensors repo)")
        }
        return DownloadPlan(repoID: repoID, revision: pinned, files: files, destination: destination)
    }

    /// Top-level tokenizer/vocab files that are not JSON.
    static let tokenizerFileNames: Set<String> = ["tokenizer.model", "vocab.txt", "merges.txt", "spiece.model", "sentencepiece.bpe.model"]

    /// Keeps weights (`*.safetensors`), JSON (config, tokenizer, index, processor) and tokenizer files at the repo's
    /// top level. Drops README, `.gitattributes`, other weight formats (`.bin`, `.gguf`, `.onnx`, ...) and subfolders.
    public static func isModelFile(_ path: String) -> Bool {
        guard !path.contains("/"), !path.hasPrefix(".") else { return false }
        let lower = path.lowercased()
        if lower.hasSuffix(".safetensors") || lower.hasSuffix(".json") { return true }
        if lower.hasSuffix(".jinja") || lower.hasSuffix(".tiktoken") { return true }   // chat_template.jinja, tiktoken vocab
        return tokenizerFileNames.contains(lower)
    }

    static func resolveURL(repoID: String, revision: String, path: String) -> URL? {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
        guard let rev = revision.addingPercentEncoding(withAllowedCharacters: allowed),
              let file = path.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "\(huggingFaceBase)/\(repoID)/resolve/\(rev)/\(file)")
    }
}
