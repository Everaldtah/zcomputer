import Foundation
import ZCore

/// Where a prepared catalogue image's files are.
public struct EmuPreparedImage: Codable, Sendable, Hashable {
    public var imageID: String
    public var version: String?
    public var cdrom: URL?
    public var hda: URL?
    public var state: URL?
    public var preparedAt: Date
}

/// Progress of `EmuImagePreparer.prepare`.
public struct EmuPrepareProgress: Sendable, Hashable {
    public enum Phase: String, Sendable, Hashable { case manifest, download, verify, decompress, done }
    public var phase: Phase
    /// Overall fraction (all files), when known.
    public var fraction: Double?
    public var detail: String
}

/// Downloads catalogue images into `EmuStore`'s `Images/<id>/`: resumable downloads, sha256 checks of the download
/// and of the decompressed file, `.xz` decompression (sparse, for multi-GB raw disks). A `ready.json` marker records
/// what was prepared; a catalogue/manifest with other sha256s makes the image "not ready" again.
public actor EmuImagePreparer {
    public nonisolated let store: EmuStore

    struct Marker: Codable {
        var imageID: String
        var version: String?
        /// role -> (local file name, verified sha256 of the download)
        var files: [String: Entry]
        var preparedAt: Date

        struct Entry: Codable {
            var localName: String
            var sha256: String?
        }
    }

    public init(store: EmuStore) {
        self.store = store
    }

    nonisolated func markerURL(_ imageID: String) -> URL {
        store.imageDirectory(imageID).appendingPathComponent("ready.json")
    }

    nonisolated func downloadsDirectory(_ imageID: String) -> URL {
        store.imageDirectory(imageID).appendingPathComponent("downloads", isDirectory: true)
    }

    nonisolated func loadMarker(_ imageID: String) -> Marker? {
        guard let data = try? Data(contentsOf: markerURL(imageID)) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Marker.self, from: data)
    }

    /// The prepared files, when the image is ready (for a manifest image whose files are not resolved yet, whatever
    /// was prepared last).
    public nonisolated func preparedImage(for image: EmuImage) -> EmuPreparedImage? {
        guard let marker = loadMarker(image.id) else { return nil }
        let dir = store.imageDirectory(image.id)
        for file in image.files {
            guard let entry = marker.files[file.role.rawValue] else { return nil }
            if let sha = file.sha256, let have = entry.sha256, sha != have { return nil }
        }
        var prepared = EmuPreparedImage(imageID: image.id, version: marker.version, cdrom: nil, hda: nil, state: nil,
                                        preparedAt: marker.preparedAt)
        for (role, entry) in marker.files {
            let url = dir.appendingPathComponent(entry.localName)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            switch EmuImageFile.Role(rawValue: role) {
            case .cdrom: prepared.cdrom = url
            case .hda: prepared.hda = url
            case .state: prepared.state = url
            case nil: break
            }
        }
        if image.kind == .instantStart, image.isResolved, prepared.state == nil { return nil }
        return prepared
    }

    public nonisolated func isReady(_ image: EmuImage) -> Bool { preparedImage(for: image) != nil }

    /// Downloads, verifies and unpacks `image` (resolving its manifest first when needed). Safe to call again after
    /// a failure or cancellation: downloads resume.
    @discardableResult
    public func prepare(_ image: EmuImage, progress: @escaping @Sendable (EmuPrepareProgress) -> Void = { _ in }) async throws -> EmuPreparedImage {
        var image = image
        if !image.isResolved, image.manifestURL != nil {
            progress(EmuPrepareProgress(phase: .manifest, fraction: nil, detail: "Reading the image manifest"))
            image = try await EmuImageCatalog.resolve(image)
        }
        if let ready = preparedImage(for: image), image.isResolved { return ready }
        guard image.isResolved else { throw ZError.notFound("\(image.name) has no files to download") }

        let fm = FileManager.default
        let dir = store.imageDirectory(image.id)
        let downloads = downloadsDirectory(image.id)
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let totalBytes = image.downloadBytes
        var doneBytes: Int64 = 0
        var marker = Marker(imageID: image.id, version: image.version, files: [:], preparedAt: Date())

        for file in image.files {
            try Task.checkCancellation()
            let local = dir.appendingPathComponent(file.localName)
            let download = downloads.appendingPathComponent(file.name)
            let base = doneBytes
            let label = file.name
            // Download (skipped when a verified download or the final file is already there).
            let finalFileValid: Bool
            if file.compression == .none, fm.fileExists(atPath: local.path), let sha = file.sha256 {
                finalFileValid = (try? await Self.offload { try EmuSHA256.hex(of: local) }) == sha
            } else {
                finalFileValid = false
            }
            if !finalFileValid {
                if !fm.fileExists(atPath: download.path) {
                    try await EmuDownloader.download(from: file.url, to: download) { p in
                        let fraction = totalBytes.map { Double(base + p.receivedBytes) / Double(max(1, $0)) }
                        progress(EmuPrepareProgress(phase: .download, fraction: fraction,
                                                    detail: "Downloading \(label): \(p.receivedBytes >> 20) MB"
                                                        + (p.expectedBytes.map { " of \($0 >> 20) MB" } ?? "")))
                    }
                }
                progress(EmuPrepareProgress(phase: .verify, fraction: nil, detail: "Checking \(label)"))
                if let expected = file.sha256 {
                    let actual = try await Self.offload { try EmuSHA256.hex(of: download) }
                    guard actual == expected else {
                        try? fm.removeItem(at: download)
                        throw ZError.vm("\(label): sha256 mismatch (expected \(expected), got \(actual))")
                    }
                }
                switch file.compression {
                case .none:
                    if fm.fileExists(atPath: local.path) { try fm.removeItem(at: local) }
                    try fm.moveItem(at: download, to: local)
                case .xz:
                    progress(EmuPrepareProgress(phase: .decompress, fraction: nil, detail: "Unpacking \(label)"))
                    let expectedOut = file.decompressedBytes
                    _ = try await Self.offload {
                        try EmuXZ.decompress(download, to: local, sparse: true) { _, produced in
                            let fraction = expectedOut.map { Double(produced) / Double(max(1, $0)) }
                            progress(EmuPrepareProgress(phase: .decompress, fraction: fraction,
                                                        detail: "Unpacking \(label): \(produced >> 20) MB"))
                        }
                    }
                    if let expectedSize = file.decompressedBytes, let size = try? emuFileSize(local), Int64(size) != expectedSize {
                        try? fm.removeItem(at: local)
                        throw ZError.vm("\(label): unpacked \(size) bytes, expected \(expectedSize)")
                    }
                    if let expected = file.decompressedSha256 {
                        progress(EmuPrepareProgress(phase: .verify, fraction: nil, detail: "Checking \(file.localName)"))
                        let actual = try await Self.offload { try EmuSHA256.hex(of: local) }
                        guard actual == expected else {
                            try? fm.removeItem(at: local)
                            throw ZError.vm("\(file.localName): sha256 mismatch after unpacking")
                        }
                    }
                    try? fm.removeItem(at: download)
                }
            }
            marker.files[file.role.rawValue] = Marker.Entry(localName: file.localName, sha256: file.sha256)
            doneBytes += file.sizeBytes ?? 0
        }
        try? fm.removeItem(at: downloads)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(marker).write(to: markerURL(image.id), options: .atomic)
        progress(EmuPrepareProgress(phase: .done, fraction: 1, detail: "Ready"))
        guard let ready = preparedImage(for: image) else { throw ZError.vm("\(image.name): prepared files are missing") }
        return ready
    }

    /// Runs blocking file work (hashing, unpacking) off the actor.
    static func offload<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .utility) { try work() }.value
    }

    /// Deletes an image's files (machines made from it can no longer start).
    public nonisolated func delete(_ image: EmuImage) throws {
        let dir = store.imageDirectory(image.id)
        if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
    }
}
