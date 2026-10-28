import Compression
import CryptoKit
import Foundation
import ZCore

/// Progress of a download.
public struct EmuDownloadProgress: Sendable, Hashable {
    public var receivedBytes: Int64
    public var expectedBytes: Int64?
    /// Bytes that were already on disk from an earlier, interrupted attempt.
    public var resumedFromBytes: Int64

    public var fractionCompleted: Double? {
        guard let expectedBytes, expectedBytes > 0 else { return nil }
        return min(1, Double(receivedBytes) / Double(expectedBytes))
    }
}

/// Resumable HTTP(S) downloads into a file (ZVM's `Downloader`, for iOS too).
///
/// Data goes to `<destination>.part`; `<destination>.part-info` remembers the URL and validator (ETag or
/// Last-Modified). A later call resumes with `Range` + `If-Range`, so a changed file on the server restarts from zero
/// instead of producing a corrupt mix.
public enum EmuDownloader {
    struct ResumeInfo: Codable, Equatable {
        var url: URL
        var etag: String?
        var lastModified: String?
        var expectedBytes: Int64?

        var validator: String? {
            if let etag, !etag.hasPrefix("W/") { return etag }
            return lastModified
        }

        static func load(_ url: URL) -> ResumeInfo? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(ResumeInfo.self, from: data)
        }

        func save(_ url: URL) {
            if let data = try? JSONEncoder().encode(self) { try? data.write(to: url, options: .atomic) }
        }
    }

    public static func partialFileURL(for destination: URL) -> URL { destination.appendingPathExtension("part") }
    static func infoFileURL(for destination: URL) -> URL { destination.appendingPathExtension("part-info") }

    /// Downloads `url` to `destination` (replacing it when complete), resuming an earlier partial download.
    public static func download(from url: URL, to destination: URL, timeout: TimeInterval = 60,
                                progress: (@Sendable (EmuDownloadProgress) -> Void)? = nil) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = partialFileURL(for: destination)
        let infoURL = infoFileURL(for: destination)
        for _ in 0..<3 {
            try Task.checkCancellation()
            var offset: Int64 = 0
            var validator: String?
            if let info = ResumeInfo.load(infoURL), info.url == url, let v = info.validator,
               fm.fileExists(atPath: part.path), let size = try? emuFileSize(part), size > 0 {
                offset = Int64(size)
                validator = v
            } else {
                try? fm.removeItem(at: part)
                try? fm.removeItem(at: infoURL)
            }
            let outcome = try await runTask(url: url, part: part, info: infoURL, offset: offset, validator: validator,
                                            timeout: timeout, progress: progress)
            switch outcome {
            case .complete:
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.moveItem(at: part, to: destination)
                try? fm.removeItem(at: infoURL)
                return
            case .restart:
                try? fm.removeItem(at: part)
                try? fm.removeItem(at: infoURL)
            }
        }
        throw ZError.network("download of \(url.absoluteString) kept restarting")
    }

    /// Parses `Content-Range: bytes <start>-<end>/<total>` (or `bytes */<total>`).
    static func parseContentRange(_ value: String) -> (start: Int64?, total: Int64?)? {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard v.lowercased().hasPrefix("bytes") else { return nil }
        let rest = v.dropFirst(5).trimmingCharacters(in: .whitespaces)
        let parts = rest.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let total = Int64(parts[1])
        if parts[0] == "*" { return (nil, total) }
        let range = parts[0].split(separator: "-", maxSplits: 1)
        guard let first = range.first, let start = Int64(first) else { return nil }
        return (start, total)
    }

    private static func runTask(url: URL, part: URL, info: URL, offset: Int64, validator: String?, timeout: TimeInterval,
                                progress: (@Sendable (EmuDownloadProgress) -> Void)?) async throws -> DownloadDelegate.Outcome {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        if offset > 0, let validator {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            request.setValue(validator, forHTTPHeaderField: "If-Range")
        }
        let delegate = DownloadDelegate(sourceURL: url, partURL: part, infoURL: info, requestedOffset: offset, progress: progress)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let box = TaskBox(session.dataTask(with: request))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<DownloadDelegate.Outcome, any Error>) in
                delegate.setContinuation(cont)
                box.task.resume()
            }
        } onCancel: {
            box.task.cancel()
        }
    }

    final class TaskBox: @unchecked Sendable {
        let task: URLSessionDataTask
        init(_ task: URLSessionDataTask) { self.task = task }
    }

    /// Session delegate writing the body into the part file.
    final class DownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        enum Outcome: Sendable { case complete, restart }

        private let lock = NSLock()
        private let sourceURL: URL
        private let partURL: URL
        private let infoURL: URL
        private let requestedOffset: Int64
        private let progress: (@Sendable (EmuDownloadProgress) -> Void)?
        private var continuation: CheckedContinuation<Outcome, any Error>?
        private var handle: FileHandle?
        private var started = false
        private var length: Int64 = 0
        private var resumedFrom: Int64 = 0
        private var expected: Int64?
        private var failure: (any Error)?
        private var restart = false
        private var lastReport = Date.distantPast

        init(sourceURL: URL, partURL: URL, infoURL: URL, requestedOffset: Int64,
             progress: (@Sendable (EmuDownloadProgress) -> Void)?) {
            self.sourceURL = sourceURL; self.partURL = partURL; self.infoURL = infoURL
            self.requestedOffset = requestedOffset; self.progress = progress
        }

        func setContinuation(_ c: CheckedContinuation<Outcome, any Error>) {
            lock.lock(); continuation = c; lock.unlock()
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            var report: EmuDownloadProgress?
            lock.lock()
            if failure == nil && !restart {
                do {
                    if !started {
                        started = true
                        try begin(response: dataTask.response)
                    }
                    if !restart, let handle {
                        try handle.write(contentsOf: data)
                        length += Int64(data.count)
                        let now = Date()
                        if now.timeIntervalSince(lastReport) > 0.25 {
                            lastReport = now
                            report = EmuDownloadProgress(receivedBytes: length, expectedBytes: expected, resumedFromBytes: resumedFrom)
                        }
                    }
                } catch {
                    failure = error
                }
            }
            let cancel = failure != nil || restart
            lock.unlock()
            if cancel { dataTask.cancel() }
            if let report { progress?(report) }
        }

        /// Validates the response and opens the part file at the right offset. Called under the lock.
        private func begin(response: URLResponse?) throws {
            guard let response else { throw ZError.network("no response") }
            // file:// (tests, local mirrors) answers with a plain URLResponse: a whole-file 200.
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 200
            var start: Int64 = 0
            if status == 206 {
                guard let range = EmuDownloader.parseContentRange(http?.value(forHTTPHeaderField: "Content-Range") ?? ""),
                      range.start == requestedOffset else {
                    restart = true
                    return
                }
                start = requestedOffset
                expected = range.total
            } else if (200..<300).contains(status) {
                expected = response.expectedContentLength > 0 ? response.expectedContentLength : nil
            } else {
                throw ZError.http(status: status, body: HTTPURLResponse.localizedString(forStatusCode: status))
            }
            let fm = FileManager.default
            if !fm.fileExists(atPath: partURL.path) { _ = fm.createFile(atPath: partURL.path, contents: nil) }
            let h = try FileHandle(forWritingTo: partURL)
            try h.truncate(atOffset: UInt64(start))
            try h.seek(toOffset: UInt64(start))
            handle = h
            length = start
            resumedFrom = start
            ResumeInfo(url: sourceURL, etag: http?.value(forHTTPHeaderField: "ETag"),
                       lastModified: http?.value(forHTTPHeaderField: "Last-Modified"), expectedBytes: expected).save(infoURL)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            lock.lock()
            let cont = continuation
            continuation = nil
            let result: Result<Outcome, any Error>
            if restart {
                result = .success(.restart)
            } else if let failure {
                result = .failure(failure)
            } else if let error {
                result = .failure(error)
            } else if !started {
                result = Self.emptyBodyOutcome(task.response, requestedOffset: requestedOffset, partURL: partURL)
            } else if let expected, length != expected {
                result = .failure(ZError.network("download incomplete: \(length) of \(expected) bytes"))
            } else {
                result = .success(.complete)
            }
            if let handle {
                try? handle.synchronize()
                try? handle.close()
            }
            handle = nil
            let final = EmuDownloadProgress(receivedBytes: length, expectedBytes: expected, resumedFromBytes: resumedFrom)
            lock.unlock()
            session.finishTasksAndInvalidate()
            if case .success(.complete) = result { progress?(final) }
            cont?.resume(with: result)
        }

        /// A response without body: an empty file, an already complete part (416), or an error.
        private static func emptyBodyOutcome(_ response: URLResponse?, requestedOffset: Int64, partURL: URL) -> Result<Outcome, any Error> {
            guard let response else { return .failure(ZError.network("no response")) }
            guard let http = response as? HTTPURLResponse else {
                _ = FileManager.default.createFile(atPath: partURL.path, contents: Data())
                return .success(.complete)
            }
            if http.statusCode == 416 {
                if let range = EmuDownloader.parseContentRange(http.value(forHTTPHeaderField: "Content-Range") ?? ""),
                   let total = range.total, total == requestedOffset {
                    return .success(.complete)
                }
                return .success(.restart)
            }
            if (200..<300).contains(http.statusCode) {
                if requestedOffset > 0 && http.statusCode == 206 { return .success(.complete) }
                _ = FileManager.default.createFile(atPath: partURL.path, contents: Data())
                return .success(.complete)
            }
            return .failure(ZError.http(status: http.statusCode, body: HTTPURLResponse.localizedString(forStatusCode: http.statusCode)))
        }
    }
}

/// Streaming sha256 of files (CryptoKit).
public enum EmuSHA256 {
    public static func hex(of url: URL, progress: ((Int64) -> Void)? = nil) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var done: Int64 = 0
        while true {
            let chunk = try handle.read(upToCount: 4 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            done += Int64(chunk.count)
            progress?(done)
        }
        return emuHex(hasher.finalize())
    }

    public static func hex(of data: Data) -> String { emuHex(SHA256.hash(data: data)) }
}

/// `.xz` decompression with Apple's Compression framework. `COMPRESSION_LZMA` decodes the xz container format (LZMA2
/// filter, multi-block streams as written by `xz -T0`); the tests decode fixtures made by xz-utils 5.8 with several
/// blocks and with CRC32 / CRC64 checks.
public enum EmuXZ {
    /// Decompresses `source` into `destination`, leaving all-zero 64 KiB blocks as holes (sparse disk images).
    /// - Returns: the number of decompressed bytes.
    @discardableResult
    public static func decompress(_ source: URL, to destination: URL, sparse: Bool = true,
                                  progress: ((_ consumed: Int64, _ produced: Int64) -> Void)? = nil) throws -> Int64 {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        _ = fm.createFile(atPath: destination.path, contents: nil)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        let srcCapacity = 1 << 20
        let dstCapacity = 4 << 20
        let srcBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: srcCapacity)
        defer { srcBuffer.deallocate() }
        let dstBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCapacity)
        defer { dstBuffer.deallocate() }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA) == COMPRESSION_STATUS_OK else {
            throw ZError.vm("xz: cannot initialise the LZMA decoder")
        }
        defer { compression_stream_destroy(stream) }
        stream.pointee.src_ptr = UnsafePointer(srcBuffer)
        stream.pointee.src_size = 0

        var consumed: Int64 = 0
        var produced: Int64 = 0
        var inputDone = false
        var stalls = 0
        while true {
            if stream.pointee.src_size == 0, !inputDone {
                let chunk = try input.read(upToCount: srcCapacity) ?? Data()
                if chunk.isEmpty {
                    inputDone = true
                } else {
                    chunk.copyBytes(to: srcBuffer, count: chunk.count)
                    stream.pointee.src_ptr = UnsafePointer(srcBuffer)
                    stream.pointee.src_size = chunk.count
                    consumed += Int64(chunk.count)
                }
            }
            stream.pointee.dst_ptr = dstBuffer
            stream.pointee.dst_size = dstCapacity
            let flags = inputDone ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let status = compression_stream_process(stream, flags)
            if status == COMPRESSION_STATUS_ERROR { throw ZError.vm("xz: corrupt or unsupported data after \(produced) bytes") }
            let count = dstCapacity - stream.pointee.dst_size
            if count > 0 {
                try write(Data(bytes: dstBuffer, count: count), to: output, at: UInt64(produced), sparse: sparse)
                produced += Int64(count)
                stalls = 0
            }
            progress?(consumed, produced)
            if status == COMPRESSION_STATUS_END { break }
            if inputDone, count == 0 {
                stalls += 1
                if stalls > 2 { throw ZError.vm("xz: truncated input after \(produced) bytes") }
            }
        }
        try output.truncate(atOffset: UInt64(produced))
        try output.synchronize()
        return produced
    }

    /// Decompresses in-memory xz data (tests, small files).
    public static func decompress(_ data: Data) throws -> Data {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zemu-xz-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("in.xz"), dst = dir.appendingPathComponent("out")
        try data.write(to: src)
        try decompress(src, to: dst, sparse: false)
        return try Data(contentsOf: dst)
    }

    /// Writes `data` at `offset`, skipping all-zero 64 KiB pieces when `sparse` (the final truncate sets the size).
    private static func write(_ data: Data, to handle: FileHandle, at offset: UInt64, sparse: Bool) throws {
        guard sparse else {
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: data)
            return
        }
        let piece = 64 << 10
        var start = 0
        while start < data.count {
            let end = min(data.count, start + piece)
            let slice = data.subdata(in: start..<end)
            if !emuIsAllZero(slice) {
                try handle.seek(toOffset: offset + UInt64(start))
                try handle.write(contentsOf: slice)
            }
            start = end
        }
    }
}
