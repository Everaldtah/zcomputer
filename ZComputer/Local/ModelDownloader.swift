import Foundation
import ZCore
import ZLocal

/// Progress of one model download.
struct ModelDownloadProgress: Sendable, Hashable {
    var completedBytes: Int64
    var totalBytes: Int64
    var currentFile: String
    var fileIndex: Int
    var fileCount: Int

    var fraction: Double { totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0 }
}

/// Downloads the files of a ZLocal `DownloadPlan` with delegate-based `URLSessionDownloadTask`s, so progress comes from
/// `didWriteData` and the same code works with a background `URLSessionConfiguration`. Files already on disk with the
/// listed size are skipped (an interrupted download resumes per file); each finished file is moved into
/// `DownloadPlan.localURL(for:)`. The caller wraps it with `LocalModelStore.prepareDirectory` / `markInstalled`.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct Pending {
        var destination: URL
        var continuation: CheckedContinuation<Void, Error>
        var onBytes: @Sendable (Int64) -> Void
        var failure: Error?
        var moved = false
    }

    private let lock = NSLock()
    private let configuration: URLSessionConfiguration
    private var sessionStorage: URLSession?
    private var pending: [Int: Pending] = [:]
    private var tasks: [Int: URLSessionDownloadTask] = [:]

    init(configuration: URLSessionConfiguration = .default) {
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        self.configuration = configuration
        super.init()
    }

    private var session: URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let sessionStorage { return sessionStorage }
        let made = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        sessionStorage = made
        return made
    }

    /// Downloads every file of `plan` (skipping complete ones). `token` is an optional Hugging Face token.
    func download(plan: DownloadPlan, token: String?, progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {
        let total = max(plan.totalBytes, 1)
        var done: Int64 = 0
        for (index, file) in plan.files.enumerated() {
            try Task.checkCancellation()
            let destination = plan.localURL(for: file)
            let base = done
            let report: @Sendable (Int64) -> Void = { written in
                progress(ModelDownloadProgress(completedBytes: base + written, totalBytes: total, currentFile: file.path,
                                               fileIndex: index + 1, fileCount: plan.files.count))
            }
            if let expected = file.sizeBytes, Self.fileSize(destination) == expected {
                done += expected
                report(0)
                continue
            }
            var request = URLRequest(url: file.url)
            if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            try await fetch(request, to: destination, onBytes: report)
            done += file.sizeBytes ?? Self.fileSize(destination) ?? 0
            report(0)
        }
    }

    private func fetch(_ request: URLRequest, to destination: URL, onBytes: @escaping @Sendable (Int64) -> Void) async throws {
        let task = session.downloadTask(with: request)
        let id = task.taskIdentifier
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                pending[id] = Pending(destination: destination, continuation: continuation, onBytes: onBytes)
                tasks[id] = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.cancelTask(id)
        }
    }

    private func cancelTask(_ id: Int) {
        lock.lock()
        let task = tasks[id]
        lock.unlock()
        task?.cancel()
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock()
        let handler = pending[downloadTask.taskIdentifier]?.onBytes
        lock.unlock()
        handler?(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let id = downloadTask.taskIdentifier
        lock.lock()
        let destination = pending[id]?.destination
        lock.unlock()
        guard let destination else { return }
        var failure: Error?
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let name = downloadTask.originalRequest?.url?.lastPathComponent ?? "file"
            failure = http.statusCode == 401 || http.statusCode == 403
                ? ZError.http(status: http.statusCode, body: "\(name): this model needs a Hugging Face token (Settings ▸ Providers ▸ Hugging Face)")
                : ZError.http(status: http.statusCode, body: "download of \(name) failed")
        } else {
            // The temporary file is deleted when this method returns, so move it now.
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.moveItem(at: location, to: destination)
            } catch {
                failure = error
            }
        }
        lock.lock()
        if failure == nil { pending[id]?.moved = true } else { pending[id]?.failure = failure }
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        lock.lock()
        let entry = pending.removeValue(forKey: id)
        tasks[id] = nil
        lock.unlock()
        guard let entry else { return }
        if let error {
            let cancelled = (error as? URLError)?.code == .cancelled
            entry.continuation.resume(throwing: cancelled ? CancellationError() : ZError.network(error.localizedDescription))
        } else if let failure = entry.failure {
            entry.continuation.resume(throwing: failure)
        } else if entry.moved {
            entry.continuation.resume()
        } else {
            entry.continuation.resume(throwing: ZError.network("the download finished without a file"))
        }
    }

    static func fileSize(_ url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize else { return nil }
        return Int64(size)
    }
}
