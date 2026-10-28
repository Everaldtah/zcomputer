import Foundation
import ZCore

/// One relative mouse movement in screen orientation (positive `dy` moves down). v86's `mouse-delta` bus event
/// takes PS/2 orientation (positive y moves up); `EmuHost` flips the sign when it sends.
public struct MouseDelta: Sendable, Hashable, Codable {
    public var dx: Int
    public var dy: Int
    public init(dx: Int, dy: Int) { self.dx = dx; self.dy = dy }
}

/// A point in guest display pixels.
public struct PixelPoint: Sendable, Hashable, Codable {
    public var x: Int
    public var y: Int
    public init(x: Int, y: Int) { self.x = x; self.y = y }
}

/// Absolute pointing on top of v86's *relative* PS/2 mouse: the host cannot read the guest's cursor, so it keeps
/// its own estimate. Homing drives the cursor into the top-left corner with large negative movements (the guest
/// clamps it at (0,0), whatever acceleration it applies), after which a move to (x, y) is a known relative distance.
///
/// The distance in PS/2 counts is `pixels / sensitivity`. An unaccelerated pointer (Linux console/gpm, X with a flat
/// libinput profile) moves one pixel per count (`sensitivity` 1). Accelerated pointers move further for fast,
/// large packets, so moves are split into small packets (`maxStep` counts) and re-homed before every move by
/// default, which keeps errors from accumulating. Guests with the VMware absolute pointer (xf86-input-vmmouse or
/// the kernel's vmmouse driver) do not need any of this: `EmuSurface` uses `mouse-absolute` there.
public struct CursorTracker: Sendable, Hashable {
    public var screen: PixelSize
    /// Guest pixels per PS/2 count.
    public var sensitivity: Double
    /// Largest movement per packet while positioning (counts per axis).
    public var maxStep: Int
    /// Largest movement per packet while homing (PS/2 packets carry 9-bit signed deltas).
    public var homingStep: Int
    /// The estimated cursor position; nil until the first homing.
    public private(set) var position: PixelPoint?

    public init(screen: PixelSize, sensitivity: Double = 1.0, maxStep: Int = 10, homingStep: Int = 120) {
        self.screen = screen
        self.sensitivity = sensitivity > 0 ? sensitivity : 1
        self.maxStep = max(1, maxStep)
        self.homingStep = max(1, min(255, homingStep))
        self.position = nil
    }

    /// Forgets the position (after a guest mode change, a reset or anything that may have moved the cursor).
    public mutating func invalidate() { position = nil }

    /// Clamps a point to the screen.
    public func clamp(_ p: PixelPoint) -> PixelPoint {
        PixelPoint(x: min(max(0, p.x), max(0, screen.width - 1)), y: min(max(0, p.y), max(0, screen.height - 1)))
    }

    /// Packets that push the cursor into the top-left corner: twice the screen size in counts (at the slowest
    /// assumed sensitivity), so any start position and any deceleration still ends at (0, 0).
    public func homingPackets() -> [MouseDelta] {
        let factor = max(1.0, 1.0 / sensitivity)
        let totalX = Int((Double(screen.width) * 2 * factor).rounded(.up))
        let totalY = Int((Double(screen.height) * 2 * factor).rounded(.up))
        return Self.split(dx: -totalX, dy: -totalY, step: homingStep)
    }

    /// Records that homing packets were sent.
    public mutating func didHome() { position = PixelPoint(x: 0, y: 0) }

    /// Packets that move the cursor to `target` (clamped). Homes first when the position is unknown or `rehome` is
    /// set; returns everything to send, in order, and updates the estimate.
    public mutating func move(to target: PixelPoint, rehome: Bool) -> [MouseDelta] {
        let goal = clamp(target)
        var packets: [MouseDelta] = []
        if rehome || position == nil {
            packets += homingPackets()
            didHome()
        }
        let from = position ?? PixelPoint(x: 0, y: 0)
        let countsX = Int((Double(goal.x - from.x) / sensitivity).rounded())
        let countsY = Int((Double(goal.y - from.y) / sensitivity).rounded())
        packets += Self.split(dx: countsX, dy: countsY, step: maxStep)
        position = goal
        return packets
    }

    /// Packets for a relative move by (dx, dy) pixels from the current estimate (no homing).
    public mutating func moveBy(dx: Int, dy: Int) -> [MouseDelta] {
        let from = position ?? PixelPoint(x: 0, y: 0)
        let goal = clamp(PixelPoint(x: from.x + dx, y: from.y + dy))
        let countsX = Int((Double(goal.x - from.x) / sensitivity).rounded())
        let countsY = Int((Double(goal.y - from.y) / sensitivity).rounded())
        if position != nil { position = goal }
        return Self.split(dx: countsX, dy: countsY, step: maxStep)
    }

    /// Splits a movement into packets of at most `step` counts per axis; the packets add up exactly to (dx, dy)
    /// and are spread evenly (Bresenham-style rounding).
    public static func split(dx: Int, dy: Int, step: Int) -> [MouseDelta] {
        let step = max(1, step)
        let n = max((abs(dx) + step - 1) / step, (abs(dy) + step - 1) / step)
        guard n > 0 else { return [] }
        var out: [MouseDelta] = []
        out.reserveCapacity(n)
        var sentX = 0, sentY = 0
        for i in 1...n {
            let x = Int((Double(dx) * Double(i) / Double(n)).rounded())
            let y = Int((Double(dy) * Double(i) / Double(n)).rounded())
            out.append(MouseDelta(dx: x - sentX, dy: y - sentY))
            sentX = x; sentY = y
        }
        return out
    }

    /// `mouse-absolute` arguments for v86's VMware pointer: the pixel centre, scaled by the guest display size.
    public static func absoluteArguments(for p: PixelPoint, screen: PixelSize) -> [Double] {
        let w = Double(max(1, screen.width)), h = Double(max(1, screen.height))
        let x = min(max(0, Double(p.x) + 0.5), w), y = min(max(0, Double(p.y) + 0.5), h)
        return [x, y, w, h]
    }
}
