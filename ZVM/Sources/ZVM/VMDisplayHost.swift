import AppKit
@preconcurrency import ScreenCaptureKit
@preconcurrency import Virtualization
import ZCore

/// One captured guest frame.
public struct CapturedFrame: Sendable, Hashable {
    public var png: Data
    public var width: Int
    public var height: Int
    /// "cacheDisplay" or "screenCaptureKit" — report it in the activity feed so capture regressions on new macOS
    /// releases are visible.
    public var method: String
    /// The frame is a single flat colour (still warming up, or the guest really shows a blank screen).
    public var blank: Bool
}

/// Hosts the VM's display for the agent: a `VZVirtualMachineView` in a hidden, off-screen, ordered-in window,
/// so screenshots and synthetic input work whether or not the UI shows the machine (also for headless VMs).
///
/// Capture uses public API only (brief (d)): `bitmapImageRepForCachingDisplay(in:)` + `cacheDisplay(in:to:)`,
/// blank detection with retries during the warm-up after the view is created, a Shift tap to wake a blanked
/// guest, then ScreenCaptureKit when `allowsScreenCaptureKit` is set (needs the user's Screen Recording
/// permission). The window's backing store is kept at 2× (narrow displays) or ½× (≥1920 px) the guest size,
/// because zyvor saw blank captures when it equals the guest size; frames are resampled to guest pixels, so
/// screenshot pixels == input coordinates.
@MainActor
public final class VMDisplayHost {
    /// The hidden agent view. Never show it in the UI; use `makeUserView()` for that.
    public let agentView: VZVirtualMachineView
    public let input: SyntheticInput
    public private(set) var virtualMachine: VZVirtualMachine?
    /// Seconds after (re)attaching during which blank frames are retried (an idle console can take a few seconds).
    public var warmUpSeconds: TimeInterval = 6
    /// Opt-in ScreenCaptureKit fallback (Screen Recording permission; UNVERIFIED that it sees VZ content).
    public var allowsScreenCaptureKit = false

    private let configuredSize: PixelSize
    private var window: NSWindow?
    private var windowPixels: PixelSize?
    private var attachedAt = Date()
    private let userViews = NSHashTable<VZVirtualMachineView>.weakObjects()

    public init(displaySize: PixelSize) {
        let view = VZVirtualMachineView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.automaticallyReconfiguresDisplay = false   // only the visible view may resize the guest display
        view.capturesSystemKeys = false
        agentView = view
        configuredSize = displaySize
        input = SyntheticInput(view: view, fallbackSize: displaySize)
    }

    /// Binds the views to a VM (or detaches with nil). Creates the hidden window on first attach.
    public func attach(_ vm: VZVirtualMachine?) {
        virtualMachine = vm
        agentView.virtualMachine = vm
        for view in userViews.allObjects { view.virtualMachine = vm }
        attachedAt = Date()
        if vm != nil { ensureWindow() }
    }

    /// A view for the UI (wrap it in an `NSViewRepresentable`). With `reconfiguresDisplay` the guest display
    /// follows the view size (macOS 14+, Linux needs virtio-gpu); keep it off to preserve agent coordinates.
    public func makeUserView(reconfiguresDisplay: Bool = false, capturesSystemKeys: Bool = true) -> VZVirtualMachineView {
        let view = VZVirtualMachineView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.virtualMachine = virtualMachine
        view.automaticallyReconfiguresDisplay = reconfiguresDisplay
        view.capturesSystemKeys = capturesSystemKeys
        userViews.add(view)
        return view
    }

    /// Current guest display size in pixels.
    public var displayPixels: PixelSize { input.displayPixels }

    // MARK: Capture

    /// Captures the guest display as PNG at guest pixel resolution.
    public func capture() async throws -> CapturedFrame {
        guard virtualMachine != nil else { throw ZError.vm("no VM is attached to the display") }
        var lastBlank: CGImage?
        var blankAfterWarmUp = 0
        for _ in 0..<40 {
            ensureWindow()
            let px = displayPixels
            if let raw = captureOnce() {
                let image = ImageTools.resample(raw, width: px.width, height: px.height)
                if !ImageTools.isBlank(image) {
                    return try Self.frame(image, method: "cacheDisplay", blank: false)
                }
                lastBlank = image
            }
            if Date().timeIntervalSince(attachedAt) >= warmUpSeconds {
                blankAfterWarmUp += 1
                if blankAfterWarmUp == 1 {
                    await input.wake()                 // the guest may have blanked its screen
                } else if blankAfterWarmUp >= 3 {
                    break
                }
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        if allowsScreenCaptureKit, let window {
            let px = displayPixels
            if let png = try? await Self.screenCaptureKitPNG(windowNumber: window.windowNumber, width: px.width, height: px.height) {
                return CapturedFrame(png: png, width: px.width, height: px.height, method: "screenCaptureKit", blank: false)
            }
        }
        if let lastBlank {
            return try Self.frame(lastBlank, method: "cacheDisplay", blank: true)
        }
        throw ZError.vm("display capture produced no image")
    }

    /// One `cacheDisplay` capture of the agent view (nil when the view has no size or no backing image).
    public func captureOnce() -> CGImage? {
        let view = agentView
        let bounds = view.bounds
        guard bounds.width >= 1, bounds.height >= 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        return rep.cgImage
    }

    private static func frame(_ image: CGImage, method: String, blank: Bool) throws -> CapturedFrame {
        let png = try ImageTools.pngData(image)
        return CapturedFrame(png: png, width: image.width, height: image.height, method: method, blank: blank)
    }

    /// ScreenCaptureKit capture of our own hidden window. Runs nonisolated so no framework object crosses actors.
    nonisolated static func screenCaptureKitPNG(windowNumber: Int, width: Int, height: Int) async throws -> Data {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let windowID = CGWindowID(truncatingIfNeeded: windowNumber)
        guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
            throw ZError.vm("ScreenCaptureKit does not list the capture window")
        }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, width)
        configuration.height = max(1, height)
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard !ImageTools.isBlank(image) else { throw ZError.vm("ScreenCaptureKit returned a blank frame") }
        return try ImageTools.pngData(image)
    }

    // MARK: Hidden window

    /// Creates (or resizes) the off-screen window: borderless, opaque, ordered in at (-20000, -20000).
    @discardableResult
    public func ensureWindow() -> NSWindow {
        let px = displayPixels
        let w: NSWindow
        if let existing = window {
            if windowPixels == px { return existing }
            w = existing
        } else {
            w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.borderless],
                         backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.ignoresMouseEvents = true
            w.isOpaque = true
            w.backgroundColor = .black
            w.hasShadow = false
            w.isExcludedFromWindowsMenu = true
            w.animationBehavior = .none
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.contentView = agentView
            window = w
            attachedAt = Date()
        }
        let scale = w.backingScaleFactor > 0 ? w.backingScaleFactor : 2
        let factor: CGFloat = px.width >= 1920 ? 0.5 : 2.0
        let size = NSSize(width: max(1, CGFloat(px.width) * factor / scale), height: max(1, CGFloat(px.height) * factor / scale))
        w.setContentSize(size)
        agentView.frame = NSRect(origin: .zero, size: size)
        w.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        w.orderFrontRegardless()
        windowPixels = px
        return w
    }

    /// Removes the hidden window (e.g. when the VM is deleted).
    public func tearDown() {
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        windowPixels = nil
        agentView.virtualMachine = nil
        virtualMachine = nil
    }
}
