import Foundation
import ZCore

// Native computer-use tools, per docs/research/local-models-and-agent-loops.md Part B (§6–§8) and the
// implementation brief (B2 translation tables, B3 declarations, B4 transport notes).
//
// Transport contract with ZProviders (how native calls look as ZCore `ToolCall`s / `ToolResult`s):
//
// * Declaration: the runner advertises a `ToolSpec` named "computer" with `native = bridge.kind`.
//   `metadata["declaration"]` holds the exact vendor tool entry to send (verbatim), `metadata["beta_header"]` an
//   optional `anthropic-beta` value; `metadata["display_width_px"/"display_height_px"]` are informational only.
// * Anthropic `computer_toolset_20260801`: every member block becomes `ToolCall(id: tool_use.id,
//   name: "computer.<member>", arguments: input)`; the client turns the prefix back into `name` + `"toolset_name":
//   "computer"` on `tool_use` and `tool_result` blocks. Legacy `computer_20251124` / `computer_20250124`:
//   `ToolCall(name: "computer", arguments: input)` with `input.action`.
// * OpenAI Responses `computer`: ONE `ToolCall` per `computer_call` item — `id` = `call_id`, `name` = "computer",
//   `arguments` = `{"actions": [...], "pending_safety_checks": [...]}` (a single legacy `action` object is accepted).
//   The result's image part is the `computer_call_output` screenshot; when the result is not an error the client
//   echoes the call's `pending_safety_checks` as `acknowledged_safety_checks` (they were approved by the user before
//   anything ran). (B4 suggested N calls sharing one call_id; one call per item keeps ids unique and lets the
//   approval happen before any action of the batch.)
// * Gemini `computerUse`: each `functionCall` becomes `ToolCall(id: id ?? synthesised, name: "computer.<function>",
//   arguments: args)`; the client strips the prefix. The result's first text part is the JSON `response` object
//   (it carries `"safety_acknowledgement": true` after a confirmed `require_confirmation`), its image part goes in
//   `functionResponse.parts` as inline PNG.

/// A provider safety check that a human must clear before the call runs.
public struct NativeSafetyCheck: Hashable, Sendable, Codable {
    public var id: String?
    public var code: String?
    public var message: String
    public init(id: String? = nil, code: String? = nil, message: String) { self.id = id; self.code = code; self.message = message }
}

/// A native computer call translated into vendor-neutral actions.
public struct NativeComputerCall: Hashable, Sendable {
    /// Native action / member name(s), for display.
    public var member: String
    /// Actions in the model's coordinate space (as described by the bridge's `coordinateMapping`).
    public var actions: [ComputerAction]
    /// Gemini's per-action `intent`, shown in the activity feed.
    public var intent: String?
    public var safetyChecks: [NativeSafetyCheck]

    public init(member: String, actions: [ComputerAction], intent: String? = nil, safetyChecks: [NativeSafetyCheck] = []) {
        self.member = member; self.actions = actions; self.intent = intent; self.safetyChecks = safetyChecks
    }
}

/// What the agent can do beyond the basics; decides which native members are declared.
public struct ComputerFeatures: Hashable, Sendable {
    /// `zoom` needs an `ImageResizer` that can crop.
    public var zoom: Bool
    /// key_down / key_up / hold_key need `ComputerSurface.keyDown/keyUp`.
    public var heldKeys: Bool
    public init(zoom: Bool = false, heldKeys: Bool = true) { self.zoom = zoom; self.heldKeys = heldKeys }
}

/// Translates a provider's native computer-use tool to and from vendor-neutral `ComputerAction`s.
public protocol NativeComputerBridge: Sendable {
    /// The native tool this bridge speaks; used when `ModelCapabilities.nativeComputerUse == kind`.
    var kind: NativeToolKind { get }
    /// The tool to advertise (name "computer", `native = kind`, declaration in metadata).
    func toolSpec(modelDisplaySize: PixelSize, features: ComputerFeatures) -> ToolSpec
    /// Native call → neutral actions (+ intent and safety checks).
    func translate(_ call: ToolCall) throws -> NativeComputerCall
    /// Coordinate hook: the screenshot↔surface mapping for this vendor's coordinates. Default: unchanged.
    func coordinateMapping(base: CoordinateMapping) -> CoordinateMapping
    /// Whether later calls in the same turn are skipped after a failure. Default true.
    var stopsBatchOnFailure: Bool { get }
    /// Whether to take a fresh screenshot after the actions ran.
    func wantsScreenshot(after translated: NativeComputerCall, execution: ComputerExecution, isLastInBatch: Bool) -> Bool
    /// Builds the tool result in the shape the vendor expects.
    func result(for call: ToolCall, translated: NativeComputerCall, execution: ComputerExecution, screenshot: ImageData?) -> ToolResult
}

public extension NativeComputerBridge {
    func coordinateMapping(base: CoordinateMapping) -> CoordinateMapping { base }
    var stopsBatchOnFailure: Bool { true }
}

public enum NativeComputerBridges {
    /// The default bridge for a model's native computer tool (nil for non-computer kinds).
    public static func bridge(for kind: NativeToolKind?) -> (any NativeComputerBridge)? {
        switch kind {
        case .anthropicComputer?: return AnthropicComputerBridge()
        case .openAIComputer?: return OpenAIComputerBridge()
        case .geminiComputer?: return GeminiComputerBridge()
        default: return nil
        }
    }

    static let prefix = ComputerTool.toolName + "."

    /// "computer.left_click" → "left_click".
    static func member(of name: String) -> String? {
        name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : nil
    }

    static func point(_ a: ToolArguments, _ key: String) -> ScreenPoint? {
        guard let arr = a[key]?.arrayValue, arr.count >= 2, let x = arr[0].lenientInt, let y = arr[1].lenientInt else { return nil }
        return ScreenPoint(x: x, y: y)
    }

    static func point(_ a: ToolArguments, x: String = "x", y: String = "y") -> ScreenPoint? {
        guard let px = a.int(x), let py = a.int(y) else { return nil }
        return ScreenPoint(x: px, y: py)
    }

    static func require(_ p: ScreenPoint?, _ what: String) throws -> ScreenPoint {
        guard let p else { throw ZError.invalidArgument("\(what) needs a coordinate.") }
        return p
    }

    static func baseSpec(_ kind: NativeToolKind, size: PixelSize, declaration: JSONValue, beta: String? = nil,
                         features: ComputerFeatures) -> ToolSpec {
        var metadata: [String: JSONValue] = [
            "declaration": declaration,
            "display_width_px": .number(Double(size.width)),
            "display_height_px": .number(Double(size.height)),
        ]
        if let beta { metadata["beta_header"] = .string(beta) }
        var description = ComputerTool.baseDescription + " The screenshot is \(size.width)x\(size.height) pixels."
        if kind == .geminiComputer { description += " Native coordinates are on a 0-999 grid." }
        return ToolSpec(name: ComputerTool.toolName, description: description,
                        parameters: ComputerTool.parameters(zoom: features.zoom), native: kind, metadata: metadata)
    }

    /// Wheel clicks from a pixel distance (100 px per click; UNVERIFIED per the research, tune in the app).
    static func wheelClicks(_ pixels: Int) -> Int {
        guard pixels != 0 else { return 0 }
        let clicks = max(1, Int((Double(abs(pixels)) / 100).rounded()))
        return pixels > 0 ? clicks : -clicks
    }
}

// MARK: - Anthropic

/// Anthropic computer use: the GA `computer_toolset_20260801` (one tool_use block per member, tagged
/// `toolset_name: "computer"`) or the legacy single `computer` tool with `input.action`.
/// Coordinates are screenshot pixels; batches run in order and stop at the first failure.
public struct AnthropicComputerBridge: NativeComputerBridge {
    public enum Version: String, Sendable, Hashable, CaseIterable {
        case toolset20260801 = "computer_toolset_20260801"
        case legacy20251124 = "computer_20251124"
        case legacy20250124 = "computer_20250124"

        /// `anthropic-beta` header the legacy versions need.
        public var betaHeader: String? {
            switch self {
            case .toolset20260801: return nil
            case .legacy20251124: return "computer-use-2025-11-24"
            case .legacy20250124: return "computer-use-2025-01-24"
            }
        }
    }

    public var version: Version
    public var kind: NativeToolKind { .anthropicComputer }

    public init(version: Version = .toolset20260801) { self.version = version }

    public func toolSpec(modelDisplaySize: PixelSize, features: ComputerFeatures) -> ToolSpec {
        let declaration: JSONValue
        switch version {
        case .toolset20260801:
            var configs: [String: JSONValue] = [:]
            if !features.heldKeys { configs["hold_key"] = ["enabled": false] }
            if !features.zoom { configs["zoom"] = ["enabled": false] }
            var d: [String: JSONValue] = ["type": .string(version.rawValue)]
            if !configs.isEmpty { d["configs"] = .object(configs) }
            declaration = .object(d)
        case .legacy20251124, .legacy20250124:
            var d: [String: JSONValue] = [
                "type": .string(version.rawValue), "name": .string(ComputerTool.toolName),
                "display_width_px": .number(Double(modelDisplaySize.width)),
                "display_height_px": .number(Double(modelDisplaySize.height)),
                "display_number": 1,
            ]
            if version == .legacy20251124, features.zoom { d["enable_zoom"] = true }
            declaration = .object(d)
        }
        return NativeComputerBridges.baseSpec(kind, size: modelDisplaySize, declaration: declaration,
                                              beta: version.betaHeader, features: features)
    }

    public func translate(_ call: ToolCall) throws -> NativeComputerCall {
        let a = ToolArguments(call)
        guard let member = NativeComputerBridges.member(of: call.name) ?? a.string("action") else {
            throw ZError.invalidArgument("Computer call without a member or action.")
        }
        let coordinate = NativeComputerBridges.point(a, "coordinate")
        let modifiers = ComputerAction.modifierList(a.string("text"))
        func text() throws -> String {
            guard let t = a.string("text"), !t.isEmpty else { throw ZError.invalidArgument("\(member) needs 'text'.") }
            return t
        }
        let actions: [ComputerAction]
        switch member {
        case "screenshot":
            actions = [.screenshot]
        case "zoom":
            guard let region = a["region"]?.arrayValue?.compactMap(\.lenientInt), region.count == 4 else {
                throw ZError.invalidArgument("zoom needs region [x0, y0, x1, y1].")
            }
            actions = [.zoom(region: region)]
        case "left_click":
            actions = [.click(at: coordinate, button: .left, count: 1, modifiers: modifiers)]
        case "right_click":
            actions = [.click(at: coordinate, button: .right, count: 1, modifiers: modifiers)]
        case "middle_click":
            actions = [.click(at: coordinate, button: .middle, count: 1, modifiers: modifiers)]
        case "double_click":
            actions = [.click(at: coordinate, button: .left, count: 2, modifiers: modifiers)]
        case "triple_click":
            actions = [.click(at: coordinate, button: .left, count: 3, modifiers: modifiers)]
        case "left_click_drag":
            let end = try NativeComputerBridges.require(coordinate, "left_click_drag")
            actions = [.drag(from: NativeComputerBridges.point(a, "start_coordinate"), to: end, modifiers: modifiers)]
        case "mouse_move":
            actions = [.mouseMove(to: try NativeComputerBridges.require(coordinate, "mouse_move"))]
        case "left_mouse_down":
            actions = [.mouseDown(at: coordinate, button: .left)]
        case "left_mouse_up":
            actions = [.mouseUp(at: coordinate, button: .left)]
        case "cursor_position":
            actions = [.cursorPosition]
        case "scroll":
            let amount = min(max(a.int("scroll_amount") ?? 3, 1), 100)
            let delta = ComputerAction.scrollDelta(direction: a.string("scroll_direction") ?? "down", amount: amount)
            actions = [.scroll(at: coordinate, dx: delta.dx, dy: delta.dy, modifiers: modifiers)]
        case "type":
            actions = [.type(text: try text())]
        case "key":
            actions = [.key(combo: try text(), repeat: min(max(a.int("repeat") ?? 1, 1), 100))]
        case "hold_key":
            actions = [.holdKey(key: try text(), seconds: min(max(a.double("duration") ?? 1, 0), 300))]
        case "wait":
            actions = [.wait(seconds: min(max(a.double("duration") ?? 1, 0), 30))]
        default:
            throw ZError.invalidArgument("Unknown computer action '\(member)'.")
        }
        return NativeComputerCall(member: member, actions: actions)
    }

    /// The last block of a batch gets the current screenshot unless it already is one.
    public func wantsScreenshot(after translated: NativeComputerCall, execution: ComputerExecution, isLastInBatch: Bool) -> Bool {
        isLastInBatch && !execution.endedWithScreenshot
    }

    /// Images for screenshot / zoom, "X=…, Y=…" for cursor_position, "OK" otherwise; plus the trailing screenshot.
    public func result(for call: ToolCall, translated: NativeComputerCall, execution: ComputerExecution, screenshot: ImageData?) -> ToolResult {
        var parts: [ContentPart] = []
        if let c = execution.cursor { parts.append(.text("X=\(c.x), Y=\(c.y)")) }
        parts += execution.images.map { ContentPart.image($0) }
        if parts.isEmpty { parts.append(.text("OK")) }
        if let screenshot { parts.append(.image(screenshot)) }
        return ToolResult(callID: call.id, parts: parts)
    }
}

// MARK: - OpenAI

/// OpenAI Responses `computer` tool: one `computer_call` with a batch of `actions`, screenshot pixels,
/// `pending_safety_checks` that need a human before anything runs.
public struct OpenAIComputerBridge: NativeComputerBridge {
    public var kind: NativeToolKind { .openAIComputer }
    /// Seconds for the argument-less `wait` action (the official samples sleep 2 s).
    public var waitSeconds: Double

    public init(waitSeconds: Double = 2) { self.waitSeconds = waitSeconds }

    public func toolSpec(modelDisplaySize: PixelSize, features: ComputerFeatures) -> ToolSpec {
        NativeComputerBridges.baseSpec(kind, size: modelDisplaySize, declaration: ["type": "computer"], features: features)
    }

    public func translate(_ call: ToolCall) throws -> NativeComputerCall {
        let a = ToolArguments(call)
        var raw: [JSONValue] = a["actions"]?.arrayValue ?? []
        if raw.isEmpty, let single = a["action"], single.objectValue != nil { raw = [single] }
        var actions: [ComputerAction] = []
        var names: [String] = []
        if raw.isEmpty {
            if a.string("type") != nil {
                raw = [a.raw]                                   // the arguments are one action object
            } else if a.string("action") != nil {
                let neutral = try ComputerAction(arguments: a.raw) // vendor-neutral fallback
                return NativeComputerCall(member: neutral.name, actions: [neutral], safetyChecks: Self.safetyChecks(a))
            } else {
                throw ZError.invalidArgument("computer_call without actions.")
            }
        }
        for item in raw {
            let o = ToolArguments(item, toolName: ComputerTool.toolName)
            names.append(o.string("type") ?? "?")
            actions += try translateAction(o)
        }
        return NativeComputerCall(member: names.joined(separator: ","), actions: actions, safetyChecks: Self.safetyChecks(a))
    }

    static func safetyChecks(_ a: ToolArguments) -> [NativeSafetyCheck] {
        (a["pending_safety_checks"]?.arrayValue ?? []).map { v in
            let o = ToolArguments(v, toolName: ComputerTool.toolName)
            return NativeSafetyCheck(id: o.string("id"), code: o.string("code"),
                                     message: o.string("message") ?? o.string("code") ?? "OpenAI safety check")
        }
    }

    func translateAction(_ o: ToolArguments) throws -> [ComputerAction] {
        let type = (o.string("type") ?? "").lowercased()
        let modifiers = (o.stringArray("keys") ?? [])
        let p = NativeComputerBridges.point(o)
        switch type {
        case "screenshot":
            return [.screenshot]
        case "click":
            switch (o.string("button") ?? "left").lowercased() {
            case "right": return [.click(at: try NativeComputerBridges.require(p, "click"), button: .right, count: 1, modifiers: modifiers)]
            case "wheel", "middle": return [.click(at: try NativeComputerBridges.require(p, "click"), button: .middle, count: 1, modifiers: modifiers)]
            case "back": return [.key(combo: "alt+Left", repeat: 1)]
            case "forward": return [.key(combo: "alt+Right", repeat: 1)]
            default: return [.click(at: try NativeComputerBridges.require(p, "click"), button: .left, count: 1, modifiers: modifiers)]
            }
        case "double_click":
            return [.click(at: try NativeComputerBridges.require(p, "double_click"), button: .left, count: 2, modifiers: modifiers)]
        case "drag":
            let path = (o["path"]?.arrayValue ?? []).compactMap { v -> ScreenPoint? in
                guard let x = v["x"]?.lenientInt, let y = v["y"]?.lenientInt else { return nil }
                return ScreenPoint(x: x, y: y)
            }
            guard let first = path.first, let last = path.last, path.count >= 2 else {
                throw ZError.invalidArgument("drag needs a path of at least two points.")
            }
            if path.count == 2 { return [.drag(from: first, to: last, modifiers: modifiers)] }
            var list: [ComputerAction] = [.mouseDown(at: first, button: .left)]
            for point in path.dropFirst() { list.append(.mouseMove(to: point)) }
            list.append(.mouseUp(at: last, button: .left))
            return list
        case "move":
            return [.mouseMove(to: try NativeComputerBridges.require(p, "move"))]
        case "scroll":
            let dx = NativeComputerBridges.wheelClicks(o.int("scroll_x") ?? 0)
            let dy = NativeComputerBridges.wheelClicks(o.int("scroll_y") ?? 0)
            return [.scroll(at: p, dx: dx, dy: dy, modifiers: modifiers)]
        case "keypress":
            let keys = o.stringArray("keys") ?? []
            guard !keys.isEmpty else { throw ZError.invalidArgument("keypress needs keys.") }
            return [.key(combo: keys.joined(separator: "+"), repeat: 1)]
        case "type":
            guard let text = o.string("text") else { throw ZError.invalidArgument("type needs text.") }
            return [.type(text: text)]
        case "wait":
            return [.wait(seconds: waitSeconds)]
        default:
            throw ZError.invalidArgument("Unknown computer action '\(type)'.")
        }
    }

    /// One screenshot after all actions (the lone first-turn `screenshot` is captured once).
    public func wantsScreenshot(after translated: NativeComputerCall, execution: ComputerExecution, isLastInBatch: Bool) -> Bool {
        !execution.endedWithScreenshot
    }

    /// Image only: the client sends it as `computer_call_output.output` (`computer_screenshot`, detail "original").
    public func result(for call: ToolCall, translated: NativeComputerCall, execution: ComputerExecution, screenshot: ImageData?) -> ToolResult {
        guard let image = screenshot ?? execution.images.last else {
            return ToolResult(callID: call.id, text: "Actions ran, but no screenshot could be taken.", isError: true)
        }
        return ToolResult(callID: call.id, parts: [.image(image)])
    }
}

// MARK: - Gemini

/// Gemini `computerUse` (`ENVIRONMENT_DESKTOP`): predefined functions with coordinates on a 0–999 grid
/// (`px = v / 1000 × width`), optional `intent`, `safety_decision` that may require confirmation.
public struct GeminiComputerBridge: NativeComputerBridge {
    public var kind: NativeToolKind { .geminiComputer }
    /// Grid size of Gemini's normalised coordinates.
    public static let grid = 1000

    public init() {}

    public func toolSpec(modelDisplaySize: PixelSize, features: ComputerFeatures) -> ToolSpec {
        let excluded: [JSONValue] = features.heldKeys ? [] : ["key_down", "key_up"]
        let declaration: JSONValue = ["computerUse": ["environment": "ENVIRONMENT_DESKTOP", "excludedPredefinedFunctions": .array(excluded)]]
        return NativeComputerBridges.baseSpec(kind, size: modelDisplaySize, declaration: declaration, features: features)
    }

    public func coordinateMapping(base: CoordinateMapping) -> CoordinateMapping {
        CoordinateMapping(surfaceSize: base.surfaceSize, modelSize: PixelSize(width: Self.grid, height: Self.grid))
    }

    public func translate(_ call: ToolCall) throws -> NativeComputerCall {
        let a = ToolArguments(call)
        guard let member = NativeComputerBridges.member(of: call.name) ?? a.string("action") ?? (call.name == ComputerTool.toolName ? nil : call.name) else {
            throw ZError.invalidArgument("Computer call without a function name.")
        }
        let p = NativeComputerBridges.point(a)
        func arg(_ k: String) throws -> String {
            guard let v = a.string(k), !v.isEmpty else { throw ZError.invalidArgument("\(member) needs '\(k)'.") }
            return v
        }
        let actions: [ComputerAction]
        switch member {
        case "take_screenshot", "screenshot":
            actions = [.screenshot]
        case "click", "click_at":
            actions = [.click(at: try NativeComputerBridges.require(p, member), button: .left, count: 1, modifiers: [])]
        case "double_click":
            actions = [.click(at: try NativeComputerBridges.require(p, member), button: .left, count: 2, modifiers: [])]
        case "triple_click":
            actions = [.click(at: try NativeComputerBridges.require(p, member), button: .left, count: 3, modifiers: [])]
        case "right_click":
            actions = [.click(at: try NativeComputerBridges.require(p, member), button: .right, count: 1, modifiers: [])]
        case "middle_click":
            actions = [.click(at: try NativeComputerBridges.require(p, member), button: .middle, count: 1, modifiers: [])]
        case "move", "hover_at", "mouse_move":
            actions = [.mouseMove(to: try NativeComputerBridges.require(p, member))]
        case "mouse_down":
            actions = [.mouseDown(at: p, button: .left)]
        case "mouse_up":
            actions = [.mouseUp(at: p, button: .left)]
        case "type", "type_text_at":
            var list: [ComputerAction] = []
            if let p { list.append(.click(at: p, button: .left, count: 1, modifiers: [])) }
            list.append(.type(text: try arg("text")))
            if a.bool("press_enter") == true { list.append(.key(combo: "Return", repeat: 1)) }
            actions = list
        case "drag_and_drop":
            guard let from = NativeComputerBridges.point(a, x: "start_x", y: "start_y"),
                  let to = NativeComputerBridges.point(a, x: "end_x", y: "end_y") else {
                throw ZError.invalidArgument("drag_and_drop needs start_x, start_y, end_x, end_y.")
            }
            actions = [.drag(from: from, to: to, modifiers: [])]
        case "scroll", "scroll_at", "scroll_document":
            let magnitude = a.int("magnitude_in_pixels") ?? a.int("magnitude") ?? 300
            let amount = max(1, Int((Double(abs(magnitude)) / 100).rounded()))
            let delta = ComputerAction.scrollDelta(direction: a.string("direction") ?? "down", amount: amount)
            actions = [.scroll(at: p, dx: delta.dx, dy: delta.dy, modifiers: [])]
        case "press_key":
            actions = [.key(combo: try arg("key"), repeat: 1)]
        case "hotkey", "key_combination":
            let keys = a.stringArray("keys") ?? []
            guard !keys.isEmpty else { throw ZError.invalidArgument("hotkey needs keys.") }
            actions = [.key(combo: keys.joined(separator: "+"), repeat: 1)]
        case "key_down":
            actions = [.keyDown(key: try arg("key"))]
        case "key_up":
            actions = [.keyUp(key: try arg("key"))]
        case "wait", "wait_5_seconds":
            let seconds = member == "wait_5_seconds" ? 5 : (a.double("seconds") ?? 1)
            actions = [.wait(seconds: min(max(seconds, 0), 30))]
        case "navigate":
            actions = [.key(combo: "ctrl+l", repeat: 1), .type(text: try arg("url")), .key(combo: "Return", repeat: 1)]
        case "go_back":
            actions = [.key(combo: "alt+Left", repeat: 1)]
        case "go_forward":
            actions = [.key(combo: "alt+Right", repeat: 1)]
        default:
            throw ZError.invalidArgument("Unknown computer function '\(member)'.")
        }
        var checks: [NativeSafetyCheck] = []
        if let decision = a["safety_decision"], decision["decision"]?.stringValue == "require_confirmation" {
            checks.append(NativeSafetyCheck(code: "require_confirmation",
                                            message: decision["explanation"]?.stringValue ?? "The model asks for confirmation before this action."))
        }
        return NativeComputerCall(member: member, actions: actions, intent: a.string("intent"), safetyChecks: checks)
    }

    /// A fresh screenshot with every function result.
    public func wantsScreenshot(after translated: NativeComputerCall, execution: ComputerExecution, isLastInBatch: Bool) -> Bool {
        !execution.endedWithScreenshot
    }

    /// First part: the JSON `response` object; then the screenshot (inline PNG in `functionResponse.parts`).
    public func result(for call: ToolCall, translated: NativeComputerCall, execution: ComputerExecution, screenshot: ImageData?) -> ToolResult {
        var response: [String: JSONValue] = [:]
        if !translated.safetyChecks.isEmpty { response["safety_acknowledgement"] = true }
        var parts: [ContentPart] = [.text(JSONValue.object(response).jsonString())]
        if let image = screenshot ?? execution.images.last { parts.append(.image(image)) }
        return ToolResult(callID: call.id, parts: parts)
    }
}

// MARK: - Tool

/// Runs a native computer-use tool through a bridge and a `ComputerTool`.
public struct NativeComputerTool: Tool {
    public let bridge: any NativeComputerBridge
    public let computer: ComputerTool
    public let modelDisplaySize: PixelSize
    public let features: ComputerFeatures

    public init(bridge: any NativeComputerBridge, computer: ComputerTool, modelDisplaySize: PixelSize,
                features: ComputerFeatures = ComputerFeatures()) {
        self.bridge = bridge; self.computer = computer; self.modelDisplaySize = modelDisplaySize; self.features = features
    }

    public var spec: ToolSpec { bridge.toolSpec(modelDisplaySize: modelDisplaySize, features: features) }
    public var stopsBatchOnFailure: Bool { bridge.stopsBatchOnFailure }

    public func risk(of call: ToolCall) -> ToolRisk {
        guard let t = try? bridge.translate(call) else { return .normal(ComputerTool.toolName) }
        if !t.safetyChecks.isEmpty {
            return .safetyCheck("\(ComputerTool.toolName):safety_check", reason: t.safetyChecks.map(\.message).joined(separator: "; "))
        }
        if !t.actions.isEmpty, t.actions.allSatisfy(\.isReadOnly) { return .readOnly(ComputerTool.toolName) }
        return .normal(ComputerTool.toolName)
    }

    public func invoke(_ call: ToolCall, ctx: ToolContext) async throws -> ToolResult {
        let surface = try ctx.requireSurface(for: ComputerTool.toolName)
        let translated = try bridge.translate(call)
        if let intent = translated.intent, !intent.isEmpty { ctx.emitter.emit(.note("Intent: \(intent)")) }
        let bridge = self.bridge
        let execution = try await computer.execute(translated.actions, on: surface,
                                                   adjustMapping: { bridge.coordinateMapping(base: $0) })
        var screenshot: ImageData?
        if bridge.wantsScreenshot(after: translated, execution: execution, isLastInBatch: ctx.batch?.isLast ?? true) {
            screenshot = try? await computer.screenshotAfter(execution, on: surface)
        }
        return bridge.result(for: call, translated: translated, execution: execution, screenshot: screenshot)
    }
}
