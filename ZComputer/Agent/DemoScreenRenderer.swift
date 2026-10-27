import CoreGraphics
import CoreText
import Foundation
import ZCore

/// Draws the demo machine's desktop with CoreGraphics + CoreText (thread-safe, no AppKit), top-left coordinates.
enum DemoScreenRenderer {
    static let terminalFrame = CGRect(x: 40, y: 60, width: 760, height: 560)
    static let notesFrame = CGRect(x: 830, y: 60, width: 410, height: 560)
    static let dockFrame = CGRect(x: 430, y: 692, width: 420, height: 88)
    static let titleBarHeight: CGFloat = 30
    static let lineHeight: CGFloat = 18

    static func dockIcon(_ index: Int) -> CGRect {
        CGRect(x: 462 + CGFloat(index) * 130, y: 702, width: 96, height: 68)
    }

    /// The window (or dock icon) at a point, if any.
    static func window(at point: DemoPoint) -> DemoWindow? {
        let p = CGPoint(x: point.x, y: point.y)
        if terminalFrame.contains(p) || dockIcon(0).contains(p) { return .terminal }
        if notesFrame.contains(p) || dockIcon(1).contains(p) { return .notes }
        if dockIcon(2).contains(p) { return .terminal }
        return nil
    }

    static func render(_ state: DemoScreenState, size: PixelSize) -> Data? {
        let width = size.width
        let height = size.height
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        // Top-left origin; text is flipped back by the text matrix.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        // Desktop
        fill(ctx, CGRect(x: 0, y: 0, width: width, height: height), rgb(0.12, 0.33, 0.42))
        fill(ctx, CGRect(x: 0, y: CGFloat(height) * 0.55, width: CGFloat(width), height: CGFloat(height) * 0.45),
             rgb(0.09, 0.26, 0.35))
        fill(ctx, CGRect(x: 0, y: 0, width: width, height: 30), rgb(0.07, 0.07, 0.09))
        text(ctx, "Activities", at: CGPoint(x: 14, y: 20), size: 13, color: rgb(0.9, 0.9, 0.9), bold: true)
        text(ctx, "Demo machine (simulated)", at: CGPoint(x: CGFloat(width) / 2 - 80, y: 20), size: 13,
             color: rgb(0.9, 0.9, 0.9))
        text(ctx, state.clock.formatted(date: .omitted, time: .shortened), at: CGPoint(x: CGFloat(width) - 90, y: 20),
             size: 13, color: rgb(0.9, 0.9, 0.9))

        drawTerminal(ctx, state)
        drawNotes(ctx, state)
        drawDock(ctx, state)

        if let click = state.lastClick {
            ctx.setStrokeColor(rgb(1, 0.25, 0.25))
            ctx.setLineWidth(3)
            ctx.strokeEllipse(in: CGRect(x: click.x - 11, y: click.y - 11, width: 22, height: 22))
        }
        drawCursor(ctx, at: state.cursor)

        guard let image = ctx.makeImage() else { return nil }
        return CoreGraphicsImageResizer.pngData(image)
    }

    // MARK: Windows

    private static func drawTerminal(_ ctx: CGContext, _ state: DemoScreenState) {
        let frame = terminalFrame
        drawWindowChrome(ctx, frame, title: "Terminal — demo@zcomputer: ~", focused: state.focus == .terminal,
                         body: rgb(0.05, 0.05, 0.06))
        let top = frame.minY + titleBarHeight + 8
        let maxLines = Int((frame.height - titleBarHeight - 16) / lineHeight)
        let columns = Int((frame.width - 24) / 8.4)
        var lines: [String] = []
        for line in state.terminalLines { lines.append(contentsOf: wrap(line, columns)) }
        let caret = state.focus == .terminal ? "█" : ""
        lines.append(contentsOf: wrap(DemoScreenState.prompt + state.typed + caret, columns))
        for (i, line) in lines.suffix(maxLines).enumerated() {
            let isPrompt = line.hasPrefix(DemoScreenState.prompt)
            text(ctx, line, at: CGPoint(x: frame.minX + 12, y: top + CGFloat(i + 1) * lineHeight - 4), size: 14,
                 color: isPrompt ? rgb(0.45, 0.95, 0.55) : rgb(0.92, 0.92, 0.92), mono: true)
        }
    }

    private static func drawNotes(_ ctx: CGContext, _ state: DemoScreenState) {
        let frame = notesFrame
        drawWindowChrome(ctx, frame, title: "Notes", focused: state.focus == .notes, body: rgb(0.99, 0.98, 0.93))
        let top = frame.minY + titleBarHeight + 10
        let maxLines = Int((frame.height - titleBarHeight - 20) / lineHeight)
        let columns = Int((frame.width - 24) / 7.6)
        var lines: [String] = []
        let body = state.notes.isEmpty && state.focus != .notes ? "Click here and type to take notes." : state.notes
        for paragraph in body.split(separator: "\n", omittingEmptySubsequences: false) {
            lines.append(contentsOf: wrap(String(paragraph), columns))
        }
        if state.focus == .notes, let last = lines.indices.last { lines[last] += "|" }
        for (i, line) in lines.suffix(maxLines).enumerated() {
            text(ctx, line, at: CGPoint(x: frame.minX + 12, y: top + CGFloat(i + 1) * lineHeight - 4), size: 14,
                 color: state.notes.isEmpty && state.focus != .notes ? rgb(0.55, 0.55, 0.55) : rgb(0.1, 0.1, 0.1))
        }
    }

    private static func drawDock(_ ctx: CGContext, _ state: DemoScreenState) {
        let path = CGPath(roundedRect: dockFrame, cornerWidth: 18, cornerHeight: 18, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(rgb(1, 1, 1, 0.18))
        ctx.fillPath()
        let names = ["Terminal", "Notes", "Files"]
        let colors = [rgb(0.15, 0.15, 0.17), rgb(0.98, 0.84, 0.3), rgb(0.35, 0.6, 0.95)]
        for i in 0..<3 {
            let icon = dockIcon(i)
            let tile = CGRect(x: icon.midX - 24, y: icon.minY, width: 48, height: 44)
            ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 10, cornerHeight: 10, transform: nil))
            ctx.setFillColor(colors[i])
            ctx.fillPath()
            let label = names[i]
            text(ctx, label, at: CGPoint(x: icon.midX - CGFloat(label.count) * 3.3, y: icon.maxY - 4), size: 11,
                 color: rgb(1, 1, 1))
        }
    }

    private static func drawWindowChrome(_ ctx: CGContext, _ frame: CGRect, title: String, focused: Bool, body: CGColor) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 18, color: rgb(0, 0, 0, 0.45))
        ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.setFillColor(body)
        ctx.fillPath()
        ctx.restoreGState()
        let bar = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: titleBarHeight)
        fill(ctx, bar, focused ? rgb(0.24, 0.24, 0.27) : rgb(0.36, 0.36, 0.38))
        for (i, color) in [rgb(1, 0.37, 0.34), rgb(1, 0.74, 0.18), rgb(0.16, 0.79, 0.25)].enumerated() {
            ctx.setFillColor(color)
            ctx.fillEllipse(in: CGRect(x: frame.minX + 12 + CGFloat(i) * 20, y: frame.minY + 9, width: 12, height: 12))
        }
        text(ctx, title, at: CGPoint(x: frame.minX + 80, y: frame.minY + 20), size: 13, color: rgb(0.95, 0.95, 0.95),
             bold: focused)
    }

    private static func drawCursor(_ ctx: CGContext, at point: DemoPoint) {
        let x = CGFloat(point.x)
        let y = CGFloat(point.y)
        let shape = [(0.0, 0.0), (0.0, 19.0), (5.0, 15.0), (9.0, 23.0), (12.5, 21.5), (8.5, 14.0), (14.0, 14.0)]
        ctx.beginPath()
        for (i, p) in shape.enumerated() {
            let pt = CGPoint(x: x + p.0, y: y + p.1)
            if i == 0 { ctx.move(to: pt) } else { ctx.addLine(to: pt) }
        }
        ctx.closePath()
        ctx.setFillColor(rgb(1, 1, 1))
        ctx.setStrokeColor(rgb(0, 0, 0))
        ctx.setLineWidth(1.4)
        ctx.drawPath(using: .fillStroke)
    }

    // MARK: Primitives

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: r, green: g, blue: b, alpha: a)
    }

    private static func fill(_ ctx: CGContext, _ rect: CGRect, _ color: CGColor) {
        ctx.setFillColor(color)
        ctx.fill(rect)
    }

    /// Draws one line of text with its baseline at `point`.
    private static func text(_ ctx: CGContext, _ string: String, at point: CGPoint, size: CGFloat, color: CGColor,
                             mono: Bool = false, bold: Bool = false) {
        let name: String
        switch (mono, bold) {
        case (true, true): name = "Menlo-Bold"
        case (true, false): name = "Menlo-Regular"
        case (false, true): name = "HelveticaNeue-Bold"
        case (false, false): name = "HelveticaNeue"
        }
        let font = CTFontCreateWithName(name as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        ctx.textPosition = point
        CTLineDraw(line, ctx)
    }

    /// Hard-wraps a line at `columns` characters.
    private static func wrap(_ line: String, _ columns: Int) -> [String] {
        guard columns > 0, line.count > columns else { return [line] }
        var out: [String] = []
        var rest = Substring(line)
        while rest.count > columns {
            out.append(String(rest.prefix(columns)))
            rest = rest.dropFirst(columns)
        }
        out.append(String(rest))
        return out
    }
}
