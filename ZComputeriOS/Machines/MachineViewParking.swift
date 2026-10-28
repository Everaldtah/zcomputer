import SwiftUI
import UIKit

/// Keeps running machines' screen views (ZEmu's WKWebViews) inside the window when no screen shows them, so WebKit
/// keeps the emulator's JavaScript and timers running while the user is on another tab. The parking container sits
/// behind the tab view at full size (WebKit throttles hidden or windowless views, not covered ones).
@MainActor
final class MachineViewParking {
    let container: UIView

    init() {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.clipsToBounds = true
        view.backgroundColor = .clear
        view.accessibilityElementsHidden = true
        container = view
    }

    /// Moves `view` into the parking container (no-op when it is already there).
    func park(_ view: UIView) {
        guard view.superview !== container else { return }
        view.removeFromSuperview()
        view.frame = container.bounds.isEmpty ? CGRect(x: 0, y: 0, width: 1024, height: 768) : container.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.insertSubview(view, at: 0)
    }

    /// Removes a deleted machine's view.
    func evict(_ view: UIView) {
        if view.superview === container { view.removeFromSuperview() }
    }
}

/// Hosts the parking container; placed behind the root tab view.
struct ParkingLotView: UIViewRepresentable {
    let parking: MachineViewParking

    func makeUIView(context: Context) -> UIView { parking.container }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
