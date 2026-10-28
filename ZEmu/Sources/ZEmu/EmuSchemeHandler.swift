import Foundation
import WebKit
import ZCore

/// Serves the `zemu://app/...` origin the host page runs in:
///
/// * `zemu://app/host/...`, `zemu://app/v86/...` — the page, v86 (libv86.js, v86.wasm) and the BIOS files from the
///   package bundle;
/// * `zemu://app/files/<token>/<name>` — files registered by `EmuHost` (ISOs, disk images, saved states), with HTTP
///   `Range` support, so v86 loads multi-GB images with `async: true` block by block instead of into memory;
/// * `zemu://app/proxy?url=<encoded>` — the CORS proxy of v86's `fetch` network backend (the guest's plain-HTTP
///   requests), fetched with `URLSession`.
///
/// Everything is one origin, so the page needs no CORS (WebKit refuses cross-origin requests between custom-scheme
/// origins). File reads run off the main thread; responses are delivered on the main thread only while WebKit has
/// not stopped the task (sending to a stopped task raises an Objective-C exception).
@MainActor
public final class EmuSchemeHandler: NSObject, WKURLSchemeHandler {
    public nonisolated static let scheme = "zemu"
    public nonisolated static let host = "app"
    public nonisolated static let origin = "zemu://app"

    /// Bytes per `didReceive` call.
    static let chunkSize = 1 << 20

    private let registry = EmuLocked<[String: URL]>([:])
    private let bundleRoot: URL?
    private let session: URLSession
    private var active: [ObjectIdentifier: any WKURLSchemeTask] = [:]

    public init(bundleRoot: URL? = EmuResources.root) {
        self.bundleRoot = bundleRoot
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)
        super.init()
    }

    // MARK: Registry

    /// Makes `file` available to the page; returns its URL (`zemu://app/files/<token>/<name>`).
    public func register(_ file: URL) -> String {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        registry.update { $0[token] = file }
        let name = file.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "file"
        return "\(Self.origin)/files/\(token)/\(name)"
    }

    /// Forgets all registered files.
    public func unregisterAll() { registry.set([:]) }

    func registeredFile(token: String) -> URL? { registry.get()[token] }

    // MARK: WKURLSchemeHandler

    public nonisolated func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        MainActor.assumeIsolated {
            let id = ObjectIdentifier(urlSchemeTask)
            active[id] = urlSchemeTask
            let request = urlSchemeTask.request
            Task { @MainActor in await self.serve(id: id, request: request) }
        }
    }

    public nonisolated func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        MainActor.assumeIsolated {
            active[ObjectIdentifier(urlSchemeTask)] = nil
        }
    }

    // MARK: Routing

    enum Route: Equatable {
        case bundle(String)
        case file(token: String)
        case proxy(URL)
        case notFound
    }

    /// Maps a request URL to a route (pure; tested).
    nonisolated static func route(for url: URL?) -> Route {
        guard let url, url.scheme == scheme, url.host == host else { return .notFound }
        let parts = url.path.split(separator: "/").map(String.init)
        guard let first = parts.first else { return .notFound }
        if parts.contains("..") || parts.contains(".") { return .notFound }
        switch first {
        case "host", "v86":
            return .bundle(parts.joined(separator: "/"))
        case "files":
            guard parts.count >= 2 else { return .notFound }
            return .file(token: parts[1])
        case "proxy":
            guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let raw = comps.queryItems?.first(where: { $0.name == "url" })?.value,
                  let target = URL(string: raw), let s = target.scheme?.lowercased(), s == "http" || s == "https" else {
                return .notFound
            }
            return .proxy(target)
        default:
            return .notFound
        }
    }

    private func serve(id: ObjectIdentifier, request: URLRequest) async {
        let method = request.httpMethod ?? "GET"
        switch Self.route(for: request.url) {
        case .bundle(let path):
            guard let root = bundleRoot else { return fail(id, request, status: 404) }
            let file = root.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: file.path) else { return fail(id, request, status: 404) }
            await serveFile(id: id, request: request, file: file, method: method)
        case .file(let token):
            guard let file = registeredFile(token: token) else { return fail(id, request, status: 404) }
            await serveFile(id: id, request: request, file: file, method: method)
        case .proxy(let target):
            await proxy(id: id, request: request, target: target)
        case .notFound:
            fail(id, request, status: 404)
        }
    }

    private func serveFile(id: ObjectIdentifier, request: URLRequest, file: URL, method: String) async {
        let size: UInt64
        do { size = try emuFileSize(file) } catch { return fail(id, request, status: 404) }
        let head = EmuFileResponse.make(method: method, rangeHeader: request.value(forHTTPHeaderField: "Range"),
                                        fileSize: size, contentType: EmuFileResponse.contentType(forExtension: file.pathExtension))
        guard let task = active[id], let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: head.status, httpVersion: "HTTP/1.1", headerFields: head.headers) else {
            return
        }
        task.didReceive(response)
        for chunk in EmuFileReader.chunks(offset: head.offset, length: head.length, chunkSize: Self.chunkSize) {
            let data: Data
            do {
                data = try await Task.detached(priority: .userInitiated) {
                    try EmuFileReader.read(file, offset: chunk.offset, count: chunk.length)
                }.value
            } catch {
                if let task = active.removeValue(forKey: id) { task.didFailWithError(error) }
                return
            }
            guard let task = active[id] else { return }
            task.didReceive(data)
            if data.count < chunk.length { break }
        }
        if let task = active.removeValue(forKey: id) { task.didFinish() }
    }

    private func proxy(id: ObjectIdentifier, request: URLRequest, target: URL) async {
        var outgoing = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        outgoing.httpMethod = request.httpMethod ?? "GET"
        outgoing.httpBody = request.httpBody
        for (key, value) in request.allHTTPHeaderFields ?? [:] where !Self.hopByHop.contains(key.lowercased()) {
            outgoing.setValue(value, forHTTPHeaderField: key)
        }
        let session = self.session
        let prepared = outgoing
        let result: ProxyResult
        do {
            result = try await Task.detached(priority: .userInitiated) { () async throws -> ProxyResult in
                let (data, response) = try await session.data(for: prepared)
                let http = response as? HTTPURLResponse
                var headers: [String: String] = [:]
                for (k, v) in http?.allHeaderFields ?? [:] {
                    if let k = k as? String, let v = v as? String { headers[k] = v }
                }
                return ProxyResult(status: http?.statusCode ?? 200, headers: headers, body: data)
            }.value
        } catch {
            if let task = active.removeValue(forKey: id) { task.didFailWithError(error) }
            return
        }
        var headers = result.headers.filter { !Self.strippedResponseHeaders.contains($0.key.lowercased()) }
        headers["Content-Length"] = String(result.body.count)
        headers["Access-Control-Allow-Origin"] = "*"
        guard let task = active[id], let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: result.status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            return
        }
        task.didReceive(response)
        if !result.body.isEmpty { task.didReceive(result.body) }
        active.removeValue(forKey: id)
        task.didFinish()
    }

    struct ProxyResult: Sendable {
        var status: Int
        var headers: [String: String]
        var body: Data
    }

    static let hopByHop: Set<String> = ["host", "connection", "keep-alive", "proxy-connection", "transfer-encoding",
                                        "upgrade", "te", "trailer", "origin", "referer", "accept-encoding",
                                        "x-accept-encoding", "content-length"]
    static let strippedResponseHeaders: Set<String> = ["content-encoding", "content-length", "transfer-encoding",
                                                       "connection", "keep-alive", "set-cookie"]

    private func fail(_ id: ObjectIdentifier, _ request: URLRequest, status: Int) {
        guard let task = active.removeValue(forKey: id) else { return }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Length": "0", "Content-Type": "text/plain"]) else {
            task.didFailWithError(ZError.notFound(request.url?.absoluteString ?? "request"))
            return
        }
        task.didReceive(response)
        task.didFinish()
    }
}

/// The package's bundled resources.
public enum EmuResources {
    /// Folder holding `host/` (the page), `v86/` (the emulator and BIOS) and `images-x86.json`.
    public static var root: URL? { Bundle.module.resourceURL }

    /// The vendored v86 build's commit (from `v86/VERSION`); saved states only restore with this build.
    public static var v86Commit: String? {
        guard let url = root?.appendingPathComponent("v86/VERSION"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("commit:") {
            let value = line.dropFirst("commit:".count).trimmingCharacters(in: .whitespaces)
            return value.split(separator: " ").first.map(String.init)
        }
        return nil
    }
}
