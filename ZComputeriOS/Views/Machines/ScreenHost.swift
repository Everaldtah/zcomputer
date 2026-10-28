import SwiftUI
import UIKit
import ZCore

/// Pinch-to-zoom container for a machine's screen. One finger drives the guest's mouse (touch layer); two fingers
/// scroll the guest when not zoomed and pan the zoomed screen otherwise.
@MainActor
final class ZoomingScreenView: UIScrollView, UIScrollViewDelegate {
    let contentView = UIView()
    let touchLayer: TouchLayer
    private(set) weak var screen: UIView?
    private var baseSize: CGSize = .zero

    /// The guest display size; the screen is fitted to it.
    var guestSize = CGSize(width: 1024, height: 768) {
        didSet {
            guard guestSize != oldValue else { return }
            baseSize = .zero
            setNeedsLayout()
        }
    }

    init(input: MachineInput) {
        touchLayer = TouchLayer(input: input)
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        bouncesZoom = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .black
        panGestureRecognizer.minimumNumberOfTouches = 2
        panGestureRecognizer.isEnabled = false
        contentView.backgroundColor = .black
        addSubview(contentView)
        touchLayer.frame = contentView.bounds
        touchLayer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(touchLayer)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    /// Shows `view` (moved from wherever it was, e.g. the parking lot) under the touch layer.
    func show(_ view: UIView) {
        guard view.superview !== contentView else { return }
        view.removeFromSuperview()
        view.frame = contentView.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.isUserInteractionEnabled = false
        contentView.insertSubview(view, belowSubview: touchLayer)
        screen = view
    }

    /// True while `view` is still shown here (another host may have taken it).
    func owns(_ view: UIView) -> Bool { view.superview === contentView }

    override func layoutSubviews() {
        super.layoutSubviews()
        let fitted = Self.aspectFit(guestSize, in: bounds.size)
        if fitted != baseSize, fitted.width > 0, fitted.height > 0 {
            baseSize = fitted
            if zoomScale != 1 { zoomScale = 1 }
            contentView.transform = .identity
            contentView.frame = CGRect(origin: .zero, size: fitted)
            contentSize = fitted
        }
        centerContent()
    }

    private func centerContent() {
        let size = contentView.frame.size
        let dx = max(0, (bounds.width - size.width) / 2)
        let dy = max(0, (bounds.height - size.height) / 2)
        let inset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
        if contentInset != inset { contentInset = inset }
    }

    static func aspectFit(_ size: CGSize, in bounds: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: (size.width * scale).rounded(.down), height: (size.height * scale).rounded(.down))
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { contentView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        let zoomed = zoomScale > 1.01
        panGestureRecognizer.isEnabled = zoomed
        touchLayer.twoFingerScrollEnabled = !zoomed
    }
}

/// Touch → mouse: tap = click, long press = right click, one-finger drag = drag, two-finger pan = wheel scroll.
@MainActor
final class TouchLayer: UIView {
    let input: MachineInput
    private let scrollPan = UIPanGestureRecognizer()
    private var scrollRemainder = CGPoint.zero
    private let haptics = UIImpactFeedbackGenerator(style: .medium)

    var twoFingerScrollEnabled = true {
        didSet { scrollPan.isEnabled = twoFingerScrollEnabled }
    }

    init(input: MachineInput) {
        self.input = input
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityLabel = "Machine screen"
        accessibilityHint = "Tap to click, touch and hold to right-click, drag to drag, two fingers to scroll."

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.require(toFail: longPress)
        let drag = UIPanGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        drag.maximumNumberOfTouches = 1
        scrollPan.addTarget(self, action: #selector(handleScroll(_:)))
        scrollPan.minimumNumberOfTouches = 2
        scrollPan.maximumNumberOfTouches = 2
        for recognizer in [longPress, tap, drag, scrollPan] as [UIGestureRecognizer] { addGestureRecognizer(recognizer) }
    }

    required init?(coder: NSCoder) {
        return nil
    }

    /// The gesture's position as a fraction of the screen (0...1 on both axes).
    private func position(_ recognizer: UIGestureRecognizer) -> CGPoint {
        let point = recognizer.location(in: self)
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        return CGPoint(x: point.x / bounds.width, y: point.y / bounds.height)
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        input.tap(at: position(recognizer))
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        haptics.impactOccurred()
        input.tap(at: position(recognizer), button: .right)
    }

    @objc private func handleDrag(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began: input.dragBegan(at: position(recognizer))
        case .changed: input.dragMoved(to: position(recognizer))
        case .ended, .cancelled, .failed: input.dragEnded(at: position(recognizer))
        default: break
        }
    }

    @objc private func handleScroll(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self)
        scrollRemainder.x += translation.x
        scrollRemainder.y += translation.y
        let step: CGFloat = 24
        // Finger up (negative y) scrolls the content down (positive wheel dy), like a trackpad.
        let dy = Int(-scrollRemainder.y / step)
        let dx = Int(-scrollRemainder.x / step)
        scrollRemainder.y += CGFloat(dy) * step
        scrollRemainder.x += CGFloat(dx) * step
        input.scroll(at: position(recognizer), dx: dx, dy: dy)
        if recognizer.state == .ended || recognizer.state == .cancelled { scrollRemainder = .zero }
    }
}

/// The software keyboard for the machine: a first-responder view that forwards text, Backspace and (on iPad with a
/// hardware keyboard) arrows, Escape, Tab and Ctrl-combos to `MachineInput`.
@MainActor
final class KeyboardCatcher: UIView, UIKeyInput {
    weak var input: MachineInput?

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable
    var returnKeyType: UIReturnKeyType = .default

    override var canBecomeFirstResponder: Bool { true }

    var hasText: Bool { true }

    func insertText(_ text: String) { input?.type(text) }

    func deleteBackward() { input?.deleteBackward() }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let names = presses.compactMap { $0.key.flatMap(Self.name(for:)) }
        guard !names.isEmpty else {
            super.pressesBegan(presses, with: event)
            return
        }
        for name in names { input?.key(name) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.key.flatMap(Self.name(for:)) != nil }) { return }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.key.flatMap(Self.name(for:)) != nil }) { return }
        super.pressesCancelled(presses, with: event)
    }

    /// xdotool key names for hardware keys the text path does not deliver.
    static func name(for key: UIKey) -> String? {
        if key.modifierFlags.contains(.control) {
            let base = key.charactersIgnoringModifiers.lowercased()
            if base.count == 1 { return "ctrl+\(base)" }
        }
        switch key.keyCode {
        case .keyboardUpArrow: return "Up"
        case .keyboardDownArrow: return "Down"
        case .keyboardLeftArrow: return "Left"
        case .keyboardRightArrow: return "Right"
        case .keyboardEscape: return "Escape"
        case .keyboardTab: return "Tab"
        case .keyboardHome: return "Home"
        case .keyboardEnd: return "End"
        case .keyboardPageUp: return "Page_Up"
        case .keyboardPageDown: return "Page_Down"
        case .keyboardDeleteForward: return "Delete"
        default: return nil
        }
    }
}

/// Puts the keyboard catcher into the hierarchy (it must be in a window to become first responder).
struct KeyboardCatcherHost: UIViewRepresentable {
    let catcher: KeyboardCatcher

    func makeUIView(context: Context) -> KeyboardCatcher { catcher }

    func updateUIView(_ uiView: KeyboardCatcher, context: Context) {}
}

/// The Demo machine's screen as an image refreshed while shown.
@MainActor
final class DemoScreenFeed {
    let imageView: UIImageView
    private var task: Task<Void, Never>?

    init() {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.backgroundColor = .black
        imageView = view
    }

    func start(surface: MockComputerSurface) {
        task?.cancel()
        let view = imageView
        task = Task {
            while !Task.isCancelled {
                if let shot = try? await surface.screenshot(), let image = UIImage(data: shot.data) {
                    view.image = image
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

/// Hosts a machine's screen view with zoom and touch input; parks live machine views again when it goes away.
struct MachineScreenHost: UIViewRepresentable {
    let screen: UIView
    let guestSize: CGSize
    let input: MachineInput
    /// Where the view goes back to (nil for the Demo machine's image view).
    let parking: MachineViewParking?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ZoomingScreenView {
        let view = ZoomingScreenView(input: input)
        view.guestSize = guestSize
        view.show(screen)
        context.coordinator.screen = screen
        context.coordinator.parking = parking
        return view
    }

    func updateUIView(_ uiView: ZoomingScreenView, context: Context) {
        uiView.guestSize = guestSize
        if context.coordinator.screen !== screen {
            if let old = context.coordinator.screen, uiView.owns(old) { context.coordinator.parking?.park(old) }
            context.coordinator.screen = screen
        }
        uiView.show(screen)
    }

    static func dismantleUIView(_ uiView: ZoomingScreenView, coordinator: Coordinator) {
        guard let screen = coordinator.screen, uiView.owns(screen) else { return }
        if let parking = coordinator.parking {
            parking.park(screen)
        } else {
            screen.removeFromSuperview()
        }
    }

    @MainActor
    final class Coordinator {
        weak var screen: UIView?
        var parking: MachineViewParking?
    }
}
