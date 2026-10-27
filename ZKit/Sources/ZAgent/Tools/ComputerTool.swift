import Foundation
import ZCore

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

/// What a batch of computer actions produced.
public struct ComputerExecution: Hashable, Sendable {
    /// Human-readable lines ("Clicked at (10, 20).").
    public var lines: [String] = []
    /// Images produced by `screenshot` / `zoom`, in order.
    public var images: [ImageData] = []
    /// Answer to `cursor_position`, in model space.
    public var cursor: ScreenPoint?
    /// True when at least one action sent input to the machine.
    public var changedScreen = false
    /// True when the last action was `screenshot`.
    public var endedWithScreenshot = false

    public init() {}
}

/// The vendor-neutral `computer` tool over a `ComputerSurface` (research brief B1.1). Input actions return a fresh
/// screenshot, downscaled for the model; the coordinates the model sends are mapped back to the surface.
/// Also the executor behind `NativeComputerTool`.
public struct ComputerTool: Tool {
    public static let toolName = "computer"

    public var scaler: ScreenshotScaler
    public var resizer: any ImageResizer
    /// Pause after an input action before taking the follow-up screenshot (lets the UI settle).
    public var settleDelay: TimeInterval
    /// The screenshot size the model works in, when known (advertised in the tool description).
    public var modelDisplaySize: PixelSize?

    let state = ComputerToolState()

    public init(scaler: ScreenshotScaler = ScreenshotScaler(), resizer: any ImageResizer = PassThroughImageResizer(),
                settleDelay: TimeInterval = 0.5, modelDisplaySize: PixelSize? = nil) {
        self.scaler = scaler; self.resizer = resizer; self.settleDelay = settleDelay; self.modelDisplaySize = modelDisplaySize
    }

    // MARK: Spec

    public static let baseDescription = "Operate the virtual machine's screen, mouse and keyboard. Coordinates are pixels in the most recent screenshot you received (origin top-left), unless the system prompt says the 0-1000 grid is used. Every action except 'wait' returns a fresh screenshot. Prefer the shell tool for anything that does not need the GUI."

    /// The brief's flat schema (B1.1) plus `key_down` / `key_up`.
    static let schemaJSON = #"""
    {
      "type": "object",
      "properties": {
        "action": {
          "type": "string",
          "enum": ["screenshot", "click", "double_click", "triple_click", "right_click", "middle_click",
                   "mouse_move", "mouse_down", "mouse_up", "drag", "scroll", "type", "key", "key_down", "key_up", "wait", "zoom"],
          "description": "What to do."
        },
        "x": {"type": "integer", "minimum": 0, "description": "Target x for click/double_click/triple_click/right_click/middle_click/mouse_move/mouse_down/mouse_up/scroll, and drag start x."},
        "y": {"type": "integer", "minimum": 0, "description": "Target y (same actions as x)."},
        "to_x": {"type": "integer", "minimum": 0, "description": "Drag end x (action=drag)."},
        "to_y": {"type": "integer", "minimum": 0, "description": "Drag end y (action=drag)."},
        "text": {"type": "string", "description": "Literal text to type (action=type). Unicode allowed. Use action=key for Enter/Tab/shortcuts."},
        "keys": {"type": "string", "description": "Key or '+'-joined combination for action=key, xdotool names: 'Return', 'Escape', 'Tab', 'BackSpace', 'ctrl+c', 'ctrl+shift+t', 'super', 'alt+F4', 'Page_Down'. A single key for action=key_down/key_up (hold / release it)."},
        "repeat": {"type": "integer", "minimum": 1, "maximum": 100, "description": "Times to press 'keys' (action=key). Default 1."},
        "modifiers": {"type": "string", "description": "Modifiers held during a click or scroll: 'shift', 'ctrl', 'alt', 'super', or '+'-joined."},
        "direction": {"type": "string", "enum": ["up", "down", "left", "right"], "description": "Scroll direction (action=scroll)."},
        "amount": {"type": "integer", "minimum": 1, "maximum": 30, "description": "Scroll wheel clicks (action=scroll). Default 3."},
        "seconds": {"type": "number", "minimum": 0.1, "maximum": 30, "description": "Pause length (action=wait). Default 1."},
        "region": {"type": "array", "items": {"type": "integer", "minimum": 0}, "minItems": 4, "maxItems": 4,
                   "description": "[x0, y0, x1, y1] to inspect at full resolution (action=zoom)."}
      },
      "required": ["action"],
      "additionalProperties": false
    }
    """#

    /// The parameters schema; without `zoom` when the resizer cannot crop.
    public static func parameters(zoom: Bool) -> JSONValue {
        guard case .object(var root)? = try? JSONValue.parse(schemaJSON),
              case .object(var props)? = root["properties"] else {
            return Schema.object(["action": Schema.string("What to do.", oneOf: ComputerAction.actionNames)], required: ["action"])
        }
        if !zoom {
            props["region"] = nil
            if case .object(var action)? = props["action"], let names = action["enum"]?.arrayValue {
                action["enum"] = .array(names.filter { $0.stringValue != "zoom" })
                props["action"] = .object(action)
            }
            root["properties"] = .object(props)
        }
        return .object(root)
    }

    public var spec: ToolSpec {
        var description = Self.baseDescription
        var metadata: [String: JSONValue] = [:]
        if let s = modelDisplaySize {
            description += " The screenshot is \(s.width)x\(s.height) pixels."
            metadata["display_width_px"] = .number(Double(s.width))
            metadata["display_height_px"] = .number(Double(s.height))
        }
        return ToolSpec(name: Self.toolName, description: description,
                        parameters: Self.parameters(zoom: resizer.canCrop), metadata: metadata)
    }

    public func risk(of call: ToolCall) -> ToolRisk {
        if let action = try? ComputerAction(arguments: call.arguments), action.isReadOnly { return .readOnly(Self.toolName) }
        return .normal(Self.toolName)
    }

    // MARK: Vendor-neutral invocation

    public func invoke(_ call: ToolCall, ctx: ToolContext) async throws -> ToolResult {
        let surface = try ctx.requireSurface(for: Self.toolName)
        let action = try ComputerAction(arguments: call.arguments)
        let execution = try await execute([action], on: surface)
        var lines = execution.lines
        var followUp: ImageData?
        if action.wantsFollowUpScreenshot {
            do {
                followUp = try await screenshotAfter(execution, on: surface)
            } catch let e as ZError {
                // The action itself worked; say so even when the screenshot failed.
                lines.append("(No screenshot: \(e.description))")
            }
        }
        var parts: [ContentPart] = []
        if !lines.isEmpty { parts.append(.text(lines.joined(separator: "\n"))) }
        parts += execution.images.map { ContentPart.image($0) }
        if let followUp { parts.append(.image(followUp)) }
        return ToolResult(callID: call.id, parts: parts.isEmpty ? [.text("OK")] : parts)
    }

    // MARK: Execution

    /// Runs actions in order (model coordinates) and stops at the first failure (throws).
    /// `adjustMapping` lets native bridges change the coordinate space (e.g. Gemini's 0–999 grid).
    public func execute(_ actions: [ComputerAction], on surface: any ComputerSurface,
                        adjustMapping: (@Sendable (CoordinateMapping) -> CoordinateMapping)? = nil) async throws -> ComputerExecution {
        var mapping = await currentMapping(for: surface)
        if let adjustMapping { mapping = adjustMapping(mapping) }
        let guestOS = await surface.info.osFamily
        var out = ComputerExecution()
        for action in actions {
            try await run(action, on: surface, mapping: mapping, guestOS: guestOS, into: &out)
            out.endedWithScreenshot = action == .screenshot
            if !action.isReadOnly { out.changedScreen = true }
        }
        return out
    }

    /// Waits `settleDelay` when the screen may have changed, then takes a screenshot for the model.
    public func screenshotAfter(_ execution: ComputerExecution, on surface: any ComputerSurface) async throws -> ImageData {
        if execution.changedScreen, settleDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))
        }
        return try await captureScreenshot(from: surface)
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

    /// The tracked cursor position in surface coordinates (nil until the agent moved or clicked).
    public func trackedCursor() async -> ScreenPoint? { await state.cursor }

    private func run(_ action: ComputerAction, on surface: any ComputerSurface, mapping: CoordinateMapping,
                     guestOS: String, into out: inout ComputerExecution) async throws {
        func toSurface(_ p: ScreenPoint) -> ScreenPoint { mapping.toSurface(x: p.x, y: p.y) }
        func toModel(_ p: ScreenPoint) -> ScreenPoint { mapping.toModel(x: p.x, y: p.y) }
        func resolve(_ p: ScreenPoint?) async throws -> ScreenPoint {
            if let p { return toSurface(p) }
            if let c = await state.cursor { return c }
            throw ZError.invalidArgument("The cursor position is unknown; give x and y.")
        }
        func describe(_ s: ScreenPoint) -> String { let m = toModel(s); return "(\(m.x), \(m.y))" }

        switch action {
        case .screenshot:
            out.images.append(try await captureScreenshot(from: surface))

        case .zoom(let region):
            out.images.append(try await zoom(region, on: surface, mapping: mapping))
            out.lines.append("Zoomed into \(region).")

        case .click(let at, let button, let count, let modifiers):
            let s = try await resolve(at)
            try await withModifiers(modifiers, on: surface, guestOS: guestOS) {
                try await surface.click(x: s.x, y: s.y, button: button, count: count)
            }
            await state.setCursor(s)
            let what = action.name.replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: "click", with: "clicked")
            let verb = what == "clicked" ? "Clicked" : what.prefix(1).uppercased() + what.dropFirst()
            out.lines.append("\(verb) at \(describe(s))\(modifiers.isEmpty ? "" : " holding \(modifiers.joined(separator: "+"))").")

        case .mouseMove(let to):
            let s = toSurface(to)
            try await surface.mouseMove(x: s.x, y: s.y)
            await state.setCursor(s)
            out.lines.append("Moved the mouse to \(describe(s)).")

        case .mouseDown(let at, let button):
            let s = try await resolve(at)
            try await surface.mouseDown(x: s.x, y: s.y, button: button)
            await state.setCursor(s)
            out.lines.append("Pressed the \(button.rawValue) button at \(describe(s)).")

        case .mouseUp(let at, let button):
            let s = try await resolve(at)
            try await surface.mouseUp(x: s.x, y: s.y, button: button)
            await state.setCursor(s)
            out.lines.append("Released the \(button.rawValue) button at \(describe(s)).")

        case .drag(let from, let to, let modifiers):
            let a = try await resolve(from)
            let b = toSurface(to)
            try await withModifiers(modifiers, on: surface, guestOS: guestOS) {
                try await surface.drag(fromX: a.x, fromY: a.y, toX: b.x, toY: b.y)
            }
            await state.setCursor(b)
            out.lines.append("Dragged from \(describe(a)) to \(describe(b)).")

        case .scroll(let at, let dx, let dy, let modifiers):
            let s = at.map(toSurface) ?? ScreenPoint(x: mapping.surfaceSize.width / 2, y: mapping.surfaceSize.height / 2)
            try await withModifiers(modifiers, on: surface, guestOS: guestOS) {
                try await surface.scroll(x: s.x, y: s.y, dx: dx, dy: dy)
            }
            out.lines.append("Scrolled (dx \(dx), dy \(dy)) at \(describe(s)).")

        case .type(let text):
            try await surface.typeText(text)
            out.lines.append("Typed \(text.count) characters.")

        case .key(let combo, let count):
            let keys = KeyNames.normalize(combo, guestOS: guestOS)
            for _ in 0..<max(1, count) { try await surface.pressKeys(keys) }
            out.lines.append(count > 1 ? "Pressed \(keys) \(count) times." : "Pressed \(keys).")

        case .keyDown(let key):
            let k = KeyNames.normalize(key, guestOS: guestOS)
            do { try await surface.keyDown(k) } catch { throw Self.explain(error, "Holding keys (key_down)") }
            out.lines.append("Holding \(k).")

        case .keyUp(let key):
            let k = KeyNames.normalize(key, guestOS: guestOS)
            do { try await surface.keyUp(k) } catch { throw Self.explain(error, "Releasing held keys (key_up)") }
            out.lines.append("Released \(k).")

        case .holdKey(let key, let seconds):
            let k = KeyNames.normalize(key, guestOS: guestOS)
            do { try await surface.keyDown(k) } catch { throw Self.explain(error, "Holding keys (hold_key)") }
            do {
                if seconds > 0 { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            } catch {
                try? await surface.keyUp(k)
                throw error
            }
            try await surface.keyUp(k)
            out.lines.append("Held \(k) for \(seconds) s.")

        case .wait(let seconds):
            if seconds > 0 { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            out.lines.append("Waited \(seconds) s.")

        case .cursorPosition:
            guard let c = await state.cursor else {
                throw ZError.tool(name: Self.toolName, message: "The cursor position is unknown (no mouse action yet).")
            }
            let m = toModel(c)
            out.cursor = m
            out.lines.append("X=\(m.x), Y=\(m.y)")
        }
    }

    /// Holds modifier keys (key_down) around `body`, releasing them in reverse order even when it fails.
    private func withModifiers(_ modifiers: [String], on surface: any ComputerSurface, guestOS: String,
                               _ body: () async throws -> Void) async throws {
        guard !modifiers.isEmpty else {
            try await body()
            return
        }
        var held: [String] = []
        do {
            for m in modifiers {
                let key = KeyNames.normalizeKey(m, guestOS: guestOS)
                try await surface.keyDown(key)
                held.append(key)
            }
            try await body()
        } catch {
            for k in held.reversed() { try? await surface.keyUp(k) }
            throw Self.explain(error, "Holding modifier keys (\(modifiers.joined(separator: "+")))")
        }
        for k in held.reversed() { try await surface.keyUp(k) }
    }

    /// `[x0, y0, x1, y1]` (model space) at full resolution, scaled to fit the normal screenshot size.
    private func zoom(_ region: [Int], on surface: any ComputerSurface, mapping: CoordinateMapping) async throws -> ImageData {
        guard resizer.canCrop else {
            throw ZError.tool(name: Self.toolName, message: "zoom is not available on this machine yet; take a screenshot instead.")
        }
        guard region.count == 4 else { throw ZError.invalidArgument("zoom needs region [x0, y0, x1, y1].") }
        let a = mapping.toSurface(x: min(region[0], region[2]), y: min(region[1], region[3]))
        let b = mapping.toSurface(x: max(region[0], region[2]), y: max(region[1], region[3]))
        let raw = try await surface.screenshot().withDetectedSize()
        let surfaceSize = mapping.surfaceSize
        let fx = Double(raw.width ?? surfaceSize.width) / Double(max(1, surfaceSize.width))
        let fy = Double(raw.height ?? surfaceSize.height) / Double(max(1, surfaceSize.height))
        let rect = ScreenRect(x: Int(Double(a.x) * fx), y: Int(Double(a.y) * fy),
                              width: max(1, Int(Double(b.x - a.x + 1) * fx)), height: max(1, Int(Double(b.y - a.y + 1) * fy)))
        let cropped = try await resizer.crop(raw, to: rect).withDetectedSize()
        let target = ScreenshotScaler.fit(PixelSize(width: rect.width, height: rect.height),
                                          into: scaler.scaledSize(for: surfaceSize))
        return try await resizer.resize(cropped, to: target).withDetectedSize()
    }

    static func explain(_ error: Error, _ what: String) -> Error {
        if let z = error as? ZError, case .unsupported = z {
            return ZError.tool(name: toolName, message: "\(what) is not supported on this machine.")
        }
        return error
    }
}

/// Mutable bits of a ComputerTool: the coordinate mapping of the last screenshot and the tracked cursor.
actor ComputerToolState {
    private(set) var mapping: CoordinateMapping?
    private(set) var cursor: ScreenPoint?
    func setMapping(_ m: CoordinateMapping) { mapping = m }
    func setCursor(_ p: ScreenPoint) { cursor = p }
}
