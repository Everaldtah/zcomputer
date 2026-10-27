import Foundation
import ZCore

/// One vendor-neutral computer action, in the model's (screenshot) coordinate space.
public enum ComputerAction: Hashable, Sendable {
    case screenshot
    case click(x: Int, y: Int, button: MouseButton)
    case doubleClick(x: Int, y: Int)
    case rightClick(x: Int, y: Int)
    case mouseMove(x: Int, y: Int)
    case drag(fromX: Int, fromY: Int, toX: Int, toY: Int)
    /// Wheel ticks at a position (nil = centre of the screen); positive dy scrolls down, positive dx right.
    case scroll(x: Int?, y: Int?, dx: Int, dy: Int)
    case type(text: String)
    /// xdotool-style combo: "Return", "ctrl+c", "cmd+space".
    case key(combo: String)
    case wait(seconds: Double)

    /// The action names of the `computer` tool.
    public static let actionNames = ["screenshot", "click", "double_click", "right_click", "mouse_move", "drag",
                                     "scroll", "type", "key", "wait"]

    public var name: String {
        switch self {
        case .screenshot: return "screenshot"
        case .click: return "click"
        case .doubleClick: return "double_click"
        case .rightClick: return "right_click"
        case .mouseMove: return "mouse_move"
        case .drag: return "drag"
        case .scroll: return "scroll"
        case .type: return "type"
        case .key: return "key"
        case .wait: return "wait"
        }
    }

    /// True for actions that only look (screenshot, wait, mouse_move).
    public var isReadOnly: Bool {
        switch self {
        case .screenshot, .wait, .mouseMove: return true
        default: return false
        }
    }

    /// Parses the vendor-neutral `computer` arguments. Lenient: accepts `coordinate: [x, y]`, numbers as strings,
    /// `key`/`keys`/`text` for key combos, `duration`/`seconds` for waits, `direction` + `amount` for scrolls.
    public init(arguments: JSONValue) throws {
        let a = ToolArguments(arguments, toolName: ComputerTool.toolName)
        guard let rawAction = a.string(["action", "type_of_action", "command"]) else {
            throw ZError.invalidArgument("computer needs an 'action' (one of \(Self.actionNames.joined(separator: ", "))).")
        }
        let action = rawAction.lowercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")

        func point(_ xKey: String, _ yKey: String, _ arrayKey: String) -> (Int, Int)? {
            if let x = a.int(xKey), let y = a.int(yKey) { return (x, y) }
            if let arr = a[arrayKey]?.arrayValue, arr.count >= 2, let x = arr[0].lenientInt, let y = arr[1].lenientInt { return (x, y) }
            return nil
        }
        func requirePoint() throws -> (Int, Int) {
            guard let p = point("x", "y", "coordinate") else {
                throw ZError.invalidArgument("computer \(action) needs integer 'x' and 'y' in screenshot pixels.")
            }
            return p
        }

        switch action {
        case "screenshot", "take_screenshot", "capture":
            self = .screenshot
        case "click", "left_click":
            let (x, y) = try requirePoint()
            let button = MouseButton(rawValue: (a.string("button") ?? "left").lowercased()) ?? .left
            if let clicks = a.int("clicks"), clicks >= 2, button == .left {
                self = .doubleClick(x: x, y: y)
            } else {
                self = .click(x: x, y: y, button: button)
            }
        case "double_click", "doubleclick":
            let (x, y) = try requirePoint()
            self = .doubleClick(x: x, y: y)
        case "right_click", "rightclick":
            let (x, y) = try requirePoint()
            self = .rightClick(x: x, y: y)
        case "middle_click":
            let (x, y) = try requirePoint()
            self = .click(x: x, y: y, button: .middle)
        case "mouse_move", "move", "hover":
            let (x, y) = try requirePoint()
            self = .mouseMove(x: x, y: y)
        case "drag", "left_click_drag":
            let start = point("x", "y", "coordinate") ?? point("start_x", "start_y", "start_coordinate")
            let end = point("to_x", "to_y", "to_coordinate") ?? point("end_x", "end_y", "end_coordinate")
            guard let start, let end else {
                throw ZError.invalidArgument("computer drag needs 'x','y' (start) and 'to_x','to_y' (end).")
            }
            self = .drag(fromX: start.0, fromY: start.1, toX: end.0, toY: end.1)
        case "scroll":
            let p = point("x", "y", "coordinate")
            var dx = a.int("dx") ?? 0
            var dy = a.int("dy") ?? 0
            if dx == 0, dy == 0 {
                let amount = max(1, a.int(["amount", "clicks", "scroll_amount"]) ?? 3)
                switch (a.string(["direction", "scroll_direction"]) ?? "down").lowercased() {
                case "up": dy = -amount
                case "left": dx = -amount
                case "right": dx = amount
                default: dy = amount
                }
            }
            self = .scroll(x: p?.0, y: p?.1, dx: dx, dy: dy)
        case "type", "type_text", "write":
            guard let text = a.string(["text", "value", "content"]) else {
                throw ZError.invalidArgument("computer type needs a 'text' string.")
            }
            self = .type(text: text)
        case "key", "keys", "key_press", "press", "hotkey":
            guard let combo = a.string(["keys", "key", "text", "combo"]), !combo.isEmpty else {
                throw ZError.invalidArgument("computer key needs 'keys', e.g. \"Return\" or \"ctrl+c\".")
            }
            self = .key(combo: combo)
        case "wait", "sleep", "pause":
            let s = a.double(["seconds", "duration", "time"]) ?? 1
            self = .wait(seconds: min(max(s, 0), 30))
        default:
            throw ZError.invalidArgument("Unknown computer action '\(rawAction)'. Use one of: \(Self.actionNames.joined(separator: ", ")).")
        }
    }
}

extension ToolArguments {
    func int(_ keys: [String]) -> Int? {
        for k in keys { if let v = int(k) { return v } }
        return nil
    }

    func double(_ keys: [String]) -> Double? {
        for k in keys { if let v = double(k) { return v } }
        return nil
    }
}

/// The vendor-neutral `computer` tool over a `ComputerSurface`. Every action returns a fresh screenshot,
/// downscaled for the model; coordinates the model sends are mapped back to the surface.
public struct ComputerTool: Tool {
    public static let toolName = "computer"

    public var scaler: ScreenshotScaler
    public var resizer: any ImageResizer
    /// Pause after an input action before taking the follow-up screenshot (lets the UI settle).
    public var settleDelay: TimeInterval
    /// The screenshot size the model works in, when known (advertised in the tool description).
    public var modelDisplaySize: PixelSize?

    private let state = ComputerToolState()

    public init(scaler: ScreenshotScaler = ScreenshotScaler(), resizer: any ImageResizer = PassThroughImageResizer(),
                settleDelay: TimeInterval = 0.5, modelDisplaySize: PixelSize? = nil) {
        self.scaler = scaler; self.resizer = resizer; self.settleDelay = settleDelay; self.modelDisplaySize = modelDisplaySize
    }

    public var spec: ToolSpec {
        var description = """
        Control the machine's screen, mouse and keyboard. Actions: screenshot, click, double_click, right_click, \
        mouse_move, drag (x,y → to_x,to_y), scroll (x,y + direction up/down/left/right + amount, or dx/dy), \
        type (text), key (keys, xdotool style: "Return", "ctrl+c", "alt+F4"), wait (seconds). \
        Coordinates are pixels in the latest screenshot, origin top-left. Every action returns a new screenshot.
        """
        var metadata: [String: JSONValue] = [:]
        if let s = modelDisplaySize {
            description += " The screenshot is \(s.width)x\(s.height) pixels."
            metadata["display_width_px"] = .number(Double(s.width))
            metadata["display_height_px"] = .number(Double(s.height))
        }
        let properties: [String: JSONValue] = [
            "action": Schema.string("What to do.", oneOf: ComputerAction.actionNames),
            "x": Schema.integer("X in screenshot pixels (start point for drag)."),
            "y": Schema.integer("Y in screenshot pixels (start point for drag)."),
            "to_x": Schema.integer("Drag end X."),
            "to_y": Schema.integer("Drag end Y."),
            "button": Schema.string("Mouse button for click (default left).", oneOf: ["left", "right", "middle"]),
            "direction": Schema.string("Scroll direction.", oneOf: ["up", "down", "left", "right"]),
            "amount": Schema.integer("Scroll wheel ticks (default 3)."),
            "text": Schema.string("Text to type."),
            "keys": Schema.string("Key combination for the key action, e.g. \"ctrl+s\"."),
            "seconds": Schema.number("Seconds to wait (max 30)."),
        ]
        return ToolSpec(name: Self.toolName, description: description,
                        parameters: Schema.object(properties, required: ["action"]), metadata: metadata)
    }

    public func risk(of call: ToolCall) -> ToolRisk {
        if let action = try? ComputerAction(arguments: call.arguments), action.isReadOnly { return .readOnly(Self.toolName) }
        return .normal(Self.toolName)
    }

    public func invoke(_ call: ToolCall, ctx: ToolContext) async throws -> ToolResult {
        let surface = try ctx.requireSurface(for: Self.toolName)
        let action = try ComputerAction(arguments: call.arguments)
        return try await perform([action], callID: call.id, surface: surface)
    }

    /// Runs actions (model coordinates) and returns a result with a description and one fresh screenshot.
    /// `adjustMapping` lets native bridges change the coordinate space (e.g. normalised coordinates).
    public func perform(_ actions: [ComputerAction], callID: String, surface: any ComputerSurface,
                        adjustMapping: (@Sendable (CoordinateMapping) -> CoordinateMapping)? = nil) async throws -> ToolResult {
        var mapping = await currentMapping(for: surface)
        if let adjustMapping { mapping = adjustMapping(mapping) }
        var lines: [String] = []
        var changedScreen = false
        for action in actions {
            lines.append(try await execute(action, on: surface, mapping: mapping))
            if !action.isReadOnly { changedScreen = true }
        }
        if changedScreen, settleDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))
        }
        do {
            let shot = try await captureScreenshot(from: surface)
            var parts: [ContentPart] = []
            let text = lines.filter { !$0.isEmpty }.joined(separator: "\n")
            if !text.isEmpty { parts.append(.text(text)) }
            parts.append(.image(shot))
            return ToolResult(callID: callID, parts: parts)
        } catch let e as ZError {
            // The action itself worked; say so even when the screenshot failed.
            let text = (lines + ["(No screenshot: \(e.description))"]).joined(separator: "\n")
            return ToolResult(callID: callID, text: text, isError: actions == [.screenshot])
        }
    }

    /// Takes a screenshot scaled for the model and remembers the matching coordinate mapping.
    public func captureScreenshot(from surface: any ComputerSurface) async throws -> ImageData {
        let raw = try await surface.screenshot()
        let size = await surface.displaySize
        let prepared = try await scaler.prepare(raw, surfaceSize: size, resizer: resizer)
        await state.setMapping(prepared.mapping)
        return prepared.image
    }

    /// The mapping of the last screenshot, or the expected one when none was taken yet.
    public func currentMapping(for surface: any ComputerSurface) async -> CoordinateMapping {
        if let m = await state.mapping { return m }
        return scaler.mapping(for: await surface.displaySize, resizing: resizer.canResize)
    }

    private func execute(_ action: ComputerAction, on surface: any ComputerSurface, mapping: CoordinateMapping) async throws -> String {
        func p(_ x: Int, _ y: Int) -> ScreenPoint { mapping.toSurface(x: x, y: y) }
        switch action {
        case .screenshot:
            return ""
        case .click(let x, let y, let button):
            let s = p(x, y)
            try await surface.click(x: s.x, y: s.y, button: button, count: 1)
            return button == .left ? "Clicked at (\(x), \(y))." : "\(button.rawValue.capitalized)-clicked at (\(x), \(y))."
        case .doubleClick(let x, let y):
            let s = p(x, y)
            try await surface.click(x: s.x, y: s.y, button: .left, count: 2)
            return "Double-clicked at (\(x), \(y))."
        case .rightClick(let x, let y):
            let s = p(x, y)
            try await surface.click(x: s.x, y: s.y, button: .right, count: 1)
            return "Right-clicked at (\(x), \(y))."
        case .mouseMove(let x, let y):
            let s = p(x, y)
            try await surface.mouseMove(x: s.x, y: s.y)
            return "Moved the mouse to (\(x), \(y))."
        case .drag(let fx, let fy, let tx, let ty):
            let a = p(fx, fy), b = p(tx, ty)
            try await surface.drag(fromX: a.x, fromY: a.y, toX: b.x, toY: b.y)
            return "Dragged from (\(fx), \(fy)) to (\(tx), \(ty))."
        case .scroll(let x, let y, let dx, let dy):
            let s: ScreenPoint
            if let x, let y { s = p(x, y) } else { s = ScreenPoint(x: mapping.surfaceSize.width / 2, y: mapping.surfaceSize.height / 2) }
            try await surface.scroll(x: s.x, y: s.y, dx: dx, dy: dy)
            return "Scrolled (dx \(dx), dy \(dy))."
        case .type(let text):
            try await surface.typeText(text)
            return "Typed \(text.count) characters."
        case .key(let combo):
            try await surface.pressKeys(combo)
            return "Pressed \(combo)."
        case .wait(let seconds):
            if seconds > 0 { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            return "Waited \(seconds) s."
        }
    }
}

/// Mutable bits of a ComputerTool (the coordinate mapping of the last screenshot).
actor ComputerToolState {
    private(set) var mapping: CoordinateMapping?
    func setMapping(_ m: CoordinateMapping) { mapping = m }
}
