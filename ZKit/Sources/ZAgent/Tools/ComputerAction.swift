import Foundation
import ZCore

/// One vendor-neutral computer action. Points are in the model's coordinate space (pixels of the last screenshot,
/// or whatever space the active `CoordinateMapping` describes); a nil point means "at the current cursor".
public enum ComputerAction: Hashable, Sendable {
    case screenshot
    /// Inspect `[x0, y0, x1, y1]` at full resolution (needs an `ImageResizer` that can crop).
    case zoom(region: [Int])
    case click(at: ScreenPoint?, button: MouseButton, count: Int, modifiers: [String])
    case mouseMove(to: ScreenPoint)
    case mouseDown(at: ScreenPoint?, button: MouseButton)
    case mouseUp(at: ScreenPoint?, button: MouseButton)
    case drag(from: ScreenPoint?, to: ScreenPoint, modifiers: [String])
    /// Wheel clicks; positive dy scrolls down, positive dx right. Nil point = centre of the screen.
    case scroll(at: ScreenPoint?, dx: Int, dy: Int, modifiers: [String])
    case type(text: String)
    /// xdotool-style combination ("Return", "ctrl+c"), pressed `repeat` times.
    case key(combo: String, repeat: Int)
    case keyDown(key: String)
    case keyUp(key: String)
    case holdKey(key: String, seconds: Double)
    case wait(seconds: Double)
    /// Reports the tracked cursor position (model space).
    case cursorPosition

    /// Action names of the vendor-neutral `computer` tool (docs/research/local-models-and-agent-loops.md B1.1,
    /// plus key_down / key_up).
    public static let actionNames = ["screenshot", "click", "double_click", "triple_click", "right_click", "middle_click",
                                     "mouse_move", "mouse_down", "mouse_up", "drag", "scroll", "type", "key",
                                     "key_down", "key_up", "wait", "zoom"]

    public var name: String {
        switch self {
        case .screenshot: return "screenshot"
        case .zoom: return "zoom"
        case .click(_, let button, let count, _):
            switch (button, count) {
            case (.right, _): return "right_click"
            case (.middle, _): return "middle_click"
            case (_, 2): return "double_click"
            case (_, 3...): return "triple_click"
            default: return "click"
            }
        case .mouseMove: return "mouse_move"
        case .mouseDown: return "mouse_down"
        case .mouseUp: return "mouse_up"
        case .drag: return "drag"
        case .scroll: return "scroll"
        case .type: return "type"
        case .key: return "key"
        case .keyDown: return "key_down"
        case .keyUp: return "key_up"
        case .holdKey: return "hold_key"
        case .wait: return "wait"
        case .cursorPosition: return "cursor_position"
        }
    }

    /// Only looks (no input reaches the machine).
    public var isReadOnly: Bool {
        switch self {
        case .screenshot, .zoom, .wait, .cursorPosition, .mouseMove: return true
        default: return false
        }
    }

    /// Whether the vendor-neutral tool returns a fresh screenshot after this action
    /// ("every action except wait"; screenshot and zoom already return an image, cursor_position is text).
    public var wantsFollowUpScreenshot: Bool {
        switch self {
        case .screenshot, .zoom, .wait, .cursorPosition: return false
        default: return true
        }
    }

    /// Parses vendor-neutral `computer` arguments. Lenient: accepts `coordinate: [x, y]`, numbers as strings,
    /// `key`/`text` for key names, `duration` for waits, `dx`/`dy` for scrolls, `button` on click.
    public init(arguments: JSONValue) throws {
        let a = ToolArguments(arguments, toolName: ComputerTool.toolName)
        guard let rawAction = a.string(["action", "type_of_action", "command"]) else {
            throw ZError.invalidArgument("computer needs an 'action' (one of \(Self.actionNames.joined(separator: ", "))).")
        }
        let action = rawAction.lowercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        let modifiers = Self.modifierList(a.string(["modifiers", "modifier", "hold_keys"]) ?? a.stringArray("modifiers")?.joined(separator: "+"))

        func point(_ xKey: String, _ yKey: String, _ arrayKey: String) -> ScreenPoint? {
            if let x = a.int(xKey), let y = a.int(yKey) { return ScreenPoint(x: x, y: y) }
            if let arr = a[arrayKey]?.arrayValue, arr.count >= 2, let x = arr[0].lenientInt, let y = arr[1].lenientInt {
                return ScreenPoint(x: x, y: y)
            }
            return nil
        }
        let target = point("x", "y", "coordinate")
        func requireTarget() throws -> ScreenPoint {
            guard let target else { throw ZError.invalidArgument("computer \(action) needs integer 'x' and 'y'.") }
            return target
        }
        func keyArgument() throws -> String {
            guard let k = a.string(["keys", "key", "text", "combo"])?.trimmingCharacters(in: .whitespaces), !k.isEmpty else {
                throw ZError.invalidArgument("computer \(action) needs 'keys', e.g. \"Return\" or \"ctrl+c\".")
            }
            return k
        }

        switch action {
        case "screenshot", "take_screenshot", "capture":
            self = .screenshot
        case "zoom":
            guard let region = a["region"]?.arrayValue?.compactMap(\.lenientInt), region.count == 4 else {
                throw ZError.invalidArgument("computer zoom needs 'region': [x0, y0, x1, y1].")
            }
            self = .zoom(region: region)
        case "click", "left_click":
            let button = MouseButton(rawValue: (a.string("button") ?? "left").lowercased()) ?? .left
            self = .click(at: target, button: button, count: max(1, min(a.int("clicks") ?? 1, 3)), modifiers: modifiers)
        case "double_click", "doubleclick":
            self = .click(at: target, button: .left, count: 2, modifiers: modifiers)
        case "triple_click", "tripleclick":
            self = .click(at: target, button: .left, count: 3, modifiers: modifiers)
        case "right_click", "rightclick":
            self = .click(at: target, button: .right, count: 1, modifiers: modifiers)
        case "middle_click", "middleclick":
            self = .click(at: target, button: .middle, count: 1, modifiers: modifiers)
        case "mouse_move", "move", "hover":
            self = .mouseMove(to: try requireTarget())
        case "mouse_down", "left_mouse_down":
            self = .mouseDown(at: target, button: .left)
        case "mouse_up", "left_mouse_up":
            self = .mouseUp(at: target, button: .left)
        case "drag", "left_click_drag", "drag_and_drop":
            // Neutral: x,y → to_x,to_y. Anthropic: start_coordinate → coordinate. Gemini: start_x,start_y → end_x,end_y.
            let explicitStart = point("start_x", "start_y", "start_coordinate")
            let explicitEnd = point("to_x", "to_y", "to_coordinate") ?? point("end_x", "end_y", "end_coordinate")
            if let explicitEnd {
                self = .drag(from: explicitStart ?? target, to: explicitEnd, modifiers: modifiers)
            } else if let explicitStart, let target {
                self = .drag(from: explicitStart, to: target, modifiers: modifiers)
            } else {
                throw ZError.invalidArgument("computer drag needs 'x','y' (start) and 'to_x','to_y' (end).")
            }
        case "scroll":
            var dx = a.int("dx") ?? 0
            var dy = a.int("dy") ?? 0
            if dx == 0, dy == 0 {
                let amount = min(max(a.int(["amount", "scroll_amount", "clicks"]) ?? 3, 1), 30)
                (dx, dy) = Self.scrollDelta(direction: a.string(["direction", "scroll_direction"]) ?? "down", amount: amount)
            }
            self = .scroll(at: target, dx: dx, dy: dy, modifiers: modifiers)
        case "type", "type_text", "write":
            guard let text = a.string(["text", "value", "content"]) else {
                throw ZError.invalidArgument("computer type needs a 'text' string.")
            }
            self = .type(text: text)
        case "key", "keys", "key_press", "press", "press_key", "hotkey":
            self = .key(combo: try keyArgument(), repeat: min(max(a.int("repeat") ?? 1, 1), 100))
        case "key_down", "keydown":
            self = .keyDown(key: try keyArgument())
        case "key_up", "keyup":
            self = .keyUp(key: try keyArgument())
        case "hold_key":
            self = .holdKey(key: try keyArgument(), seconds: min(max(a.double(["seconds", "duration"]) ?? 1, 0), 300))
        case "wait", "sleep", "pause":
            self = .wait(seconds: min(max(a.double(["seconds", "duration", "time"]) ?? 1, 0), 30))
        case "cursor_position":
            self = .cursorPosition
        default:
            throw ZError.invalidArgument("Unknown computer action '\(rawAction)'. Use one of: \(Self.actionNames.joined(separator: ", ")).")
        }
    }

    /// "shift+ctrl" / "shift ctrl" → ["shift", "ctrl"].
    public static func modifierList(_ raw: String?) -> [String] {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return raw.split(whereSeparator: { $0 == "+" || $0 == " " || $0 == "," }).map { String($0) }.filter { !$0.isEmpty }
    }

    /// Wheel deltas for a direction.
    public static func scrollDelta(direction: String, amount: Int) -> (dx: Int, dy: Int) {
        switch direction.lowercased() {
        case "up": return (0, -amount)
        case "left": return (-amount, 0)
        case "right": return (amount, 0)
        default: return (0, amount)
        }
    }
}

/// Key-name normalisation to the xdotool names `ComputerSurface.pressKeys` expects (brief B1.1 table).
public enum KeyNames {
    static let aliases: [String: String] = [
        "enter": "Return", "return": "Return", "kp_enter": "Return",
        "esc": "Escape", "escape": "Escape",
        "backspace": "BackSpace", "back_space": "BackSpace",
        "del": "Delete", "delete": "Delete",
        "space": "space", "spacebar": "space", " ": "space",
        "tab": "Tab",
        "pageup": "Page_Up", "page_up": "Page_Up", "pgup": "Page_Up", "prior": "Page_Up",
        "pagedown": "Page_Down", "page_down": "Page_Down", "pgdn": "Page_Down", "next": "Page_Down",
        "arrowup": "Up", "up": "Up", "arrowdown": "Down", "down": "Down",
        "arrowleft": "Left", "left": "Left", "arrowright": "Right", "right": "Right",
        "home": "Home", "end": "End", "insert": "Insert", "ins": "Insert",
        "capslock": "Caps_Lock", "caps_lock": "Caps_Lock",
        "ctrl": "ctrl", "control": "ctrl", "control_l": "ctrl", "ctrl_l": "ctrl",
        "alt": "alt", "option": "alt", "opt": "alt", "alt_l": "alt",
        "shift": "shift", "shift_l": "shift",
        "plus": "plus", "minus": "minus",
    ]
    static let superAliases: Set<String> = ["cmd", "command", "meta", "super", "win", "windows", "super_l", "meta_l"]

    /// Normalises a key or "+"-joined combination. CMD/META/SUPER/WIN become `super` on Linux guests, `cmd` on macOS.
    public static func normalize(_ combo: String, guestOS: String = "linux") -> String {
        let trimmed = combo.trimmingCharacters(in: .whitespaces)
        if trimmed == "+" { return "plus" }
        let tokens = trimmed.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return trimmed }
        return tokens.map { normalizeKey($0, guestOS: guestOS) }.joined(separator: "+")
    }

    public static func normalizeKey(_ key: String, guestOS: String = "linux") -> String {
        let lower = key.lowercased()
        if superAliases.contains(lower) { return guestOS.lowercased().contains("mac") ? "cmd" : "super" }
        if let alias = aliases[lower] { return alias }
        if lower.count >= 2, lower.count <= 3, lower.first == "f", Int(lower.dropFirst()) != nil { return lower.uppercased() }
        if key.count == 1, let c = key.first, c.isLetter { return lower }
        return key
    }
}
