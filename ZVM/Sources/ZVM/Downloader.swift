import Foundation
import ZCore

/// Progress of a download.
public struct DownloadProgress: Sendable, Hashable {
    public var receivedBytes: Int64
    public var expectedBytes: Int64?
    /// Bytes that were already on disk from an earlier, interrupted attempt.
    public var resumedFromBytes: Int64

    public init(receivedBytes: Int64, expectedBytes: Int64?, resumedFromBytes: Int64) {
        self.receivedBytes = receivedBytes; self.expectedBytes = expectedBytes; self.resumedFromBytes = resumedFromBytes
    }

    public var fractionCompleted: Double? {
        guard let expectedBytes, expectedBytes > 0 else { return nil }
        return min(1, Double(receivedBytes) / Double(expectedBytes))
    }
}

/// Resumable HTTP(S) downloads into a file, for multi-GB OS images.
///
/// Data goes to `<destination>.part`; `<destination>.part-info` remembers the URL and validator (ETag or
/// Last-Modified). A later call resumes with `Range` + `If-Range`, so a changed file on the server restarts
/// from zero instead of producing a corrupt mix. With `sparse`, all-zero chunks become holes (raw disk images).
public enum Downloader {
    struct ResumeInfo: Codable, Equatable {
        var url: URL
        var etag: String?
        var lastModified: String?
        var expectedBytes: Int64?

        /// `If-Range` accepts a strong ETag or an HTTP date.
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

    /// Downloads `url` to `destination` (replacing it when complete). Resumes an earlier partial download.
    public static func download(from url: URL, to destination: URL, sparse: Bool = false,
                                timeout: TimeInterval = 60,
                                progress: (@Sendable (DownloadProgress) -> Void)? = nil) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = partialFileURL(for: destination)
        let infoURL = infoFileURL(for: destination)

        for _ in 0..<3 {
            try Task.checkCancellation()
            var offset: Int64 = 0
            var validator: String?
            if let info = ResumeInfo.load(infoURL), info.url == url, let v = info.validator,
               fm.fileExists(atPath: part.path), let size = try? VMStore.fileSize(part), size > 0 {
                offset = Int64(size)
                validator = v
            } else {
                try? fm.removeItem(at: part)
                try? fm.removeItem(at: infoURL)
            }
            let outcome = try await runTask(url: url, part: part, info: infoURL, offset: offset, validator: validator,
                                            sparse: sparse, timeout: timeout, progress: progress)
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

    private static func runTask(url: URL, part: URL, info: URL, offset: Int64, validator: String?, sparse: Bool,
                                timeout: TimeInterval,
                                progress: (@Sendable (DownloadProgress) -> Void)?) async throws -> DownloadDelegate.Outcome {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        if offset > 0, let validator {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            request.setValue(validator, forHTTPHeaderField: "If-Range")
        }
        let delegate = DownloadDelegate(sourceURL: url, partURL: part, infoURL: info, requestedOffset: offset,
                                        sparse: sparse, progress: progress)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        let box = TaskBox(task)
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
        private let sparse: Bool
        private let progress: (@Sendable (DownloadProgress) -> Void)?
        private var continuation: CheckedContinuation<Outcome, any Error>?
        private var handle: FileHandle?
        private var started = false
        private var length: Int64 = 0
        private var resumedFrom: Int64 = 0
        private var expected: Int64?
        private var failure: (any Error)?
        private var restart = false
        private var lastReport = Date.distantPast

        init(sourceURL: URL, partURL: URL, infoURL: URL, requestedOffset: Int64, sparse: Bool,
             progress: (@Sendable (DownloadProgress) -> Void)?) {
            self.sourceURL = sourceURL; self.partURL = partURL; self.infoURL = infoURL
            self.requestedOffset = requestedOffset; self.sparse = sparse; self.progress = progress
        }

        func setContinuation(_ c: CheckedContinuation<Outcome, any Error>) {
            lock.lock(); continuation = c; lock.unlock()
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            var report: DownloadProgress?
            lock.lock()
            if failure == nil && !restart {
                do {
                    if !started {
                        started = true
                        try begin(response: dataTask.response)
                    }
                    if !restart, let handle {
                        if sparse && Bytes.isAllZero(data) {
                            length += Int64(data.count)
                            try handle.truncate(atOffset: UInt64(length))   // leaves a hole, moves the file pointer
                        } else {
                            try handle.write(contentsOf: data)
                            length += Int64(data.count)
                        }
                        let now = Date()
                        if now.timeIntervalSince(lastReport) > 0.25 {
                            lastReport = now
                            report = DownloadProgress(receivedBytes: length, expectedBytes: expected, resumedFromBytes: resumedFrom)
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
            guard let http = response as? HTTPURLResponse else { throw ZError.network("no HTTP response") }
            let status = http.statusCode
            var start: Int64 = 0
            if status == 206 {
                guard let range = Downloader.parseContentRange(http.value(forHTTPHeaderField: "Content-Range") ?? ""),
                      range.start == requestedOffset else {
                    restart = true
                    return
                }
                start = requestedOffset
                expected = range.total
            } else if (200..<300).contains(status) {
                start = 0
                expected = http.expectedContentLength > 0 ? http.expectedContentLength : nil
            } else {
                throw ZError.http(status: status, body: HTTPURLResponse.localizedString(forStatusCode: status))
            }
            let fm = FileManager.default
            if !fm.fileExists(atPath: partURL.path) { _ = fm.createFile(atPath: partURL.path, contents: nil) }
            let h = try FileHandle(forWritingTo: partURL)
            try h.truncate(atOffset: UInt64(start))
            handle = h
            length = start
            resumedFrom = start
            ResumeInfo(url: sourceURL, etag: http.value(forHTTPHeaderField: "ETag"),
                       lastModified: http.value(forHTTPHeaderField: "Last-Modified"), expectedBytes: expected).save(infoURL)
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
            let final = DownloadProgress(receivedBytes: length, expectedBytes: expected, resumedFromBytes: resumedFrom)
            lock.unlock()
            session.finishTasksAndInvalidate()
            if case .success(.complete) = result { progress?(final) }
            cont?.resume(with: result)
        }

        /// A response without body: an empty file, an already complete part (416), or an error.
        private static func emptyBodyOutcome(_ response: URLResponse?, requestedOffset: Int64, partURL: URL) -> Result<Outcome, any Error> {
            guard let http = response as? HTTPURLResponse else { return .failure(ZError.network("no response")) }
            if http.statusCode == 416 {
                if let range = Downloader.parseContentRange(http.value(forHTTPHeaderField: "Content-Range") ?? ""),
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
