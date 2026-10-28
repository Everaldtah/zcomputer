import Foundation
import WebKit
import ZCore
#if canImport(UIKit)
import UIKit
/// The view type of the live screen (`WKWebView` is a `UIView` on iOS).
public typealias EmuPlatformView = UIView
#elseif canImport(AppKit)
import AppKit
/// The view type of the live screen (`WKWebView` is an `NSView` on macOS).
public typealias EmuPlatformView = NSView
#endif

/// Something the host page reported.
public enum EmuHostEvent: Sendable, Equatable {
    /// The page script is running (`window.zemu` exists).
    case pageLoaded
    /// v86 created its hardware (`emulator-ready`).
    case ready
    /// v86 loaded its files and restored the initial state, if any (`emulator-loaded`).
    case loaded
    case started
    case stopped
    /// Bytes from COM1.
    case serial(Data)
    /// `screen-set-size`: graphical modes report pixels and bits per pixel; text modes columns, rows and bpp 0.
    case screenSize(width: Int, height: Int, bpp: Int)
    /// The guest enabled or disabled the VMware absolute pointer.
    case absoluteMouse(Bool)
    case progress(file: String, loaded: Int64, total: Int64)
    case bootAssist(ok: Bool, detail: String)
    case log(level: String, message: String)
    case error(String)
    /// WebKit's web-content process died (usually memory); the page and the emulator are gone.
    case processTerminated
}

/// The `WKWebView` that runs v86, its `zemu://` scheme handler and the JavaScript bridge.
///
/// **Keep the view in a window while a machine runs.** WebKit throttles timers and stops `requestAnimationFrame` for
/// views that are not in a window or are hidden, and iOS may suspend the page. Put the view in the view hierarchy;
/// when no screen shows it, park it behind other views or at `alpha = 0.01` (not `isHidden`, not alpha 0). Screenshots
/// do not depend on display: `screenshot()` refreshes v86's own framebuffer canvas before reading it. iOS still
/// suspends WebKit when the whole app is in the background; pause or save the machine then.
@MainActor
public final class EmuHost {
    public let webView: WKWebView
    public let schemeHandler: EmuSchemeHandler
    /// Receives every event from the page (on the main actor).
    public var onEvent: ((EmuHostEvent) -> Void)?
    public private(set) var isPageLoaded = false
    /// Recent warnings and errors from the page (newest last), for diagnostics.
    public private(set) var recentLogs: [String] = []
    private var pageError: String?
    private let scriptProxy: EmuScriptProxy
    private let navigationProxy: EmuNavigationProxy

    public static let pageURL = "\(EmuSchemeHandler.origin)/host/emu.html"
    public static let wasmURL = "\(EmuSchemeHandler.origin)/v86/v86.wasm"
    public static let biosURL = "\(EmuSchemeHandler.origin)/v86/seabios.bin"
    public static let vgaBiosURL = "\(EmuSchemeHandler.origin)/v86/vgabios.bin"
    public static let corsProxyPrefix = "\(EmuSchemeHandler.origin)/proxy?url="

    /// The live screen.
    public var view: EmuPlatformView { webView }

    public init(frame: CGRect = CGRect(x: 0, y: 0, width: 1024, height: 768)) {
        let handler = EmuSchemeHandler()
        let scriptProxy = EmuScriptProxy()
        let navigationProxy = EmuNavigationProxy()
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: EmuSchemeHandler.scheme)
        configuration.websiteDataStore = .nonPersistent()
        let content = WKUserContentController()
        content.add(scriptProxy, name: "zemu")
        configuration.userContentController = content
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        #endif
        let webView = WKWebView(frame: frame, configuration: configuration)
        webView.navigationDelegate = navigationProxy
        #if os(iOS)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        #elseif os(macOS)
        webView.underPageBackgroundColor = .black
        #endif
        #if DEBUG
        webView.isInspectable = true
        #endif
        self.webView = webView
        self.schemeHandler = handler
        self.scriptProxy = scriptProxy
        self.navigationProxy = navigationProxy
        scriptProxy.host = self
        navigationProxy.host = self
    }

    // MARK: Page

    /// Loads the host page (once) and waits until its script runs.
    public func loadPage(timeout: TimeInterval = 30) async throws {
        if isPageLoaded { return }
        guard let url = URL(string: Self.pageURL) else { throw ZError.vm("bad page URL") }
        pageError = nil
        webView.load(URLRequest(url: url))
        let deadline = Date().addingTimeInterval(timeout)
        while !isPageLoaded {
            if let pageError { throw ZError.vm("emulator page failed to load: \(pageError)") }
            if Date() > deadline { throw ZError.vm("emulator page did not load within \(Int(timeout)) s") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Reloads the page (after the web-content process died); the emulator must be started again.
    public func reloadPage(timeout: TimeInterval = 30) async throws {
        isPageLoaded = false
        try await loadPage(timeout: timeout)
    }

    /// Makes a file available to the page; returns its `zemu://app/files/...` URL.
    public func registerFile(_ url: URL) -> String { schemeHandler.register(url) }

    // MARK: Calls

    /// Calls `zemu.cmd_<name>(...args)` in the page and returns its JSON result.
    @discardableResult
    public func call(_ name: String, _ args: [JSONValue] = []) async throws -> JSONValue {
        guard isPageLoaded else { throw ZError.vm("the emulator page is not loaded") }
        let argsJSON = JSONValue.array(args).jsonString()
        let result = try await webView.callAsyncJavaScript(
            "return await window.zemu.call(name, args);",
            arguments: ["name": name, "args": argsJSON],
            in: nil,
            contentWorld: .page)
        guard let text = result as? String else { throw ZError.vm("\(name): the page returned no result") }
        let reply = try JSONValue.parse(text)
        if reply["ok"]?.boolValue == true { return reply["value"] ?? .null }
        throw ZError.vm("\(name): \(reply["error"]?.stringValue ?? "failed")")
    }

    // MARK: Events

    func handle(_ event: EmuHostEvent) {
        switch event {
        case .pageLoaded:
            isPageLoaded = true
        case .log(let level, let message):
            remember("[\(level)] \(message)")
        case .error(let message):
            remember("[error] \(message)")
        case .processTerminated:
            isPageLoaded = false
            remember("[error] web content process terminated")
        default:
            break
        }
        onEvent?(event)
    }

    func pageFailed(_ message: String) {
        pageError = message
        remember("[error] page: \(message)")
    }

    private func remember(_ line: String) {
        recentLogs.append(line)
        if recentLogs.count > 200 { recentLogs.removeFirst(recentLogs.count - 200) }
    }

    /// Converts a message body from the page into an event (pure; tested).
    nonisolated static func parse(_ body: Any) -> EmuHostEvent? {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return nil }
        func int(_ key: String) -> Int { (dict[key] as? NSNumber)?.intValue ?? 0 }
        func int64(_ key: String) -> Int64 { (dict[key] as? NSNumber)?.int64Value ?? 0 }
        func string(_ key: String) -> String { dict[key] as? String ?? "" }
        switch type {
        case "page": return .pageLoaded
        case "ready": return .ready
        case "loaded": return .loaded
        case "started": return .started
        case "stopped": return .stopped
        case "serial":
            guard let data = Data(base64Encoded: string("data")) else { return nil }
            return .serial(data)
        case "screen": return .screenSize(width: int("width"), height: int("height"), bpp: int("bpp"))
        case "absolute-mouse": return .absoluteMouse((dict["enabled"] as? NSNumber)?.boolValue ?? false)
        case "progress": return .progress(file: string("file"), loaded: int64("loaded"), total: int64("total"))
        case "boot-assist": return .bootAssist(ok: (dict["ok"] as? NSNumber)?.boolValue ?? false, detail: string("detail"))
        case "log": return .log(level: string("level"), message: string("message"))
        case "error": return .error(string("message"))
        default: return nil
        }
    }
}

/// Receives `window.webkit.messageHandlers.zemu.postMessage(...)` (held weakly by the host).
@MainActor
final class EmuScriptProxy: NSObject, WKScriptMessageHandler {
    weak var host: EmuHost?

    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let host, let event = EmuHost.parse(message.body) else { return }
            host.handle(event)
        }
    }
}

/// Navigation callbacks: load failures and web-content process crashes.
@MainActor
final class EmuNavigationProxy: NSObject, WKNavigationDelegate {
    weak var host: EmuHost?

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            host?.handle(.processTerminated)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: any Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated {
            host?.pageFailed(message)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated {
            host?.pageFailed(message)
        }
    }
}
