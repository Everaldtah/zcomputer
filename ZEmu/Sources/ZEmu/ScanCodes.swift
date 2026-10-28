import Foundation
import ZCore

/// PS/2 scan code set 1 (the "XT" set the i8042 hands to the OS after translation; what v86's `keyboard-code` bus
/// event and `keyboard_send_scancodes` take) for a US-ANSI keyboard. A key's break code is its make code | 0x80;
/// extended keys are prefixed with 0xE0.
///
/// Names follow xdotool / X keysyms ("Return", "ctrl+alt+t", "super", "Page_Up", "KP_Enter"), like ZVM's `KeyCodes`.
/// Characters the guest's US layout cannot produce (non-ASCII text) cannot be typed this way; `EmuSurface` sends
/// them through `xdotool type` on the serial shell when the guest has a desktop.
public enum ScanCodes {
    /// One physical key: the bytes for pressing and releasing it, and whether a character needs Shift.
    public struct Key: Sendable, Hashable {
        public var make: [UInt8]
        public var release: [UInt8]
        /// The character this entry stands for needs Shift held (e.g. "A", "!").
        public var shift: Bool

        public init(make: [UInt8], release: [UInt8], shift: Bool = false) {
            self.make = make; self.release = release; self.shift = shift
        }

        /// A key with a single-byte make code; `extended` adds the 0xE0 prefix.
        public static func code(_ code: UInt8, extended: Bool = false, shift: Bool = false) -> Key {
            extended ? Key(make: [0xE0, code], release: [0xE0, code | 0x80], shift: shift)
                     : Key(make: [code], release: [code | 0x80], shift: shift)
        }

        /// Make followed by break.
        public var stroke: [UInt8] { make + release }
    }

    public static let leftShift = Key.code(0x2A)
    public static let leftCtrl = Key.code(0x1D)
    public static let leftAlt = Key.code(0x38)

    /// Modifier names (lowercased), xdotool style. "super"/"win"/"meta"/"cmd" is the left Windows (GUI) key.
    public static let modifiers: [String: Key] = {
        var m: [String: Key] = [:]
        func add(_ names: [String], _ key: Key) { for n in names { m[n] = key } }
        add(["shift", "shift_l", "lshift"], .code(0x2A))
        add(["shift_r", "rshift"], .code(0x36))
        add(["ctrl", "control", "control_l", "ctrl_l", "lctrl"], .code(0x1D))
        add(["ctrl_r", "control_r", "rctrl"], .code(0x1D, extended: true))
        add(["alt", "alt_l", "option", "opt", "lalt"], .code(0x38))
        add(["alt_r", "altgr", "option_r", "iso_level3_shift", "ralt"], .code(0x38, extended: true))
        add(["super", "super_l", "win", "windows", "meta", "meta_l", "cmd", "command", "cmd_l", "logo"], .code(0x5B, extended: true))
        add(["super_r", "meta_r", "cmd_r"], .code(0x5C, extended: true))
        return m
    }()

    /// Named (non-character) keys, lowercased.
    public static let namedKeys: [String: Key] = {
        var m: [String: Key] = [:]
        func add(_ names: [String], _ key: Key) { for n in names { m[n] = key } }
        add(["return", "enter", "ret", "linefeed"], .code(0x1C))
        add(["kp_enter"], .code(0x1C, extended: true))
        add(["tab", "iso_left_tab"], .code(0x0F))
        add(["space"], .code(0x39))
        add(["backspace", "back_space", "bksp"], .code(0x0E))
        add(["escape", "esc"], .code(0x01))
        add(["delete", "del"], .code(0x53, extended: true))
        add(["insert", "ins"], .code(0x52, extended: true))
        add(["home"], .code(0x47, extended: true))
        add(["end"], .code(0x4F, extended: true))
        add(["pageup", "page_up", "prior", "pgup"], .code(0x49, extended: true))
        add(["pagedown", "page_down", "next", "pgdn"], .code(0x51, extended: true))
        add(["up"], .code(0x48, extended: true))
        add(["down"], .code(0x50, extended: true))
        add(["left"], .code(0x4B, extended: true))
        add(["right"], .code(0x4D, extended: true))
        add(["caps_lock", "capslock"], .code(0x3A))
        add(["num_lock", "numlock"], .code(0x45))
        add(["scroll_lock", "scrolllock"], .code(0x46))
        add(["menu", "contextmenu", "apps"], .code(0x5D, extended: true))
        add(["print", "printscreen", "print_screen", "sys_req"],
            Key(make: [0xE0, 0x2A, 0xE0, 0x37], release: [0xE0, 0xB7, 0xE0, 0xAA]))
        add(["pause", "break"], Key(make: [0xE1, 0x1D, 0x45, 0xE1, 0x9D, 0xC5], release: []))
        let fkeys: [UInt8] = [0x3B, 0x3C, 0x3D, 0x3E, 0x3F, 0x40, 0x41, 0x42, 0x43, 0x44, 0x57, 0x58]
        for (i, code) in fkeys.enumerated() { add(["f\(i + 1)"], .code(code)) }
        let keypad: [(String, UInt8, Bool)] = [
            ("kp_0", 0x52, false), ("kp_1", 0x4F, false), ("kp_2", 0x50, false), ("kp_3", 0x51, false),
            ("kp_4", 0x4B, false), ("kp_5", 0x4C, false), ("kp_6", 0x4D, false), ("kp_7", 0x47, false),
            ("kp_8", 0x48, false), ("kp_9", 0x49, false), ("kp_decimal", 0x53, false), ("kp_multiply", 0x37, false),
            ("kp_add", 0x4E, false), ("kp_subtract", 0x4A, false), ("kp_divide", 0x35, true),
        ]
        for (n, c, e) in keypad { add([n], .code(c, extended: e)) }
        add(["audiomute", "xf86audiomute", "mute"], .code(0x20, extended: true))
        add(["audiolowervolume", "xf86audiolowervolume", "volumedown"], .code(0x2E, extended: true))
        add(["audioraisevolume", "xf86audioraisevolume", "volumeup"], .code(0x30, extended: true))
        return m
    }()

    /// Characters typable on a US-ANSI keyboard.
    public static let characters: [Character: Key] = {
        var m: [Character: Key] = [:]
        let letters: [(Character, UInt8)] = [
            ("q", 0x10), ("w", 0x11), ("e", 0x12), ("r", 0x13), ("t", 0x14), ("y", 0x15), ("u", 0x16), ("i", 0x17),
            ("o", 0x18), ("p", 0x19), ("a", 0x1E), ("s", 0x1F), ("d", 0x20), ("f", 0x21), ("g", 0x22), ("h", 0x23),
            ("j", 0x24), ("k", 0x25), ("l", 0x26), ("z", 0x2C), ("x", 0x2D), ("c", 0x2E), ("v", 0x2F), ("b", 0x30),
            ("n", 0x31), ("m", 0x32),
        ]
        for (c, code) in letters {
            m[c] = .code(code)
            m[Character(c.uppercased())] = .code(code, shift: true)
        }
        let plain: [(Character, UInt8)] = [
            ("1", 0x02), ("2", 0x03), ("3", 0x04), ("4", 0x05), ("5", 0x06), ("6", 0x07), ("7", 0x08), ("8", 0x09),
            ("9", 0x0A), ("0", 0x0B), ("-", 0x0C), ("=", 0x0D), ("[", 0x1A), ("]", 0x1B), (";", 0x27), ("'", 0x28),
            ("`", 0x29), ("\\", 0x2B), (",", 0x33), (".", 0x34), ("/", 0x35), (" ", 0x39),
        ]
        for (c, code) in plain { m[c] = .code(code) }
        let shifted: [(Character, UInt8)] = [
            ("!", 0x02), ("@", 0x03), ("#", 0x04), ("$", 0x05), ("%", 0x06), ("^", 0x07), ("&", 0x08), ("*", 0x09),
            ("(", 0x0A), (")", 0x0B), ("_", 0x0C), ("+", 0x0D), ("{", 0x1A), ("}", 0x1B), (":", 0x27), ("\"", 0x28),
            ("~", 0x29), ("|", 0x2B), ("<", 0x33), (">", 0x34), ("?", 0x35),
        ]
        for (c, code) in shifted { m[c] = .code(code, shift: true) }
        m["\n"] = .code(0x1C)
        m["\r"] = .code(0x1C)
        m["\r\n"] = .code(0x1C)
        m["\t"] = .code(0x0F)
        m["\u{08}"] = .code(0x0E)
        m["\u{1B}"] = .code(0x01)
        return m
    }()

    /// X keysym names for punctuation (xdotool accepts these in combos, e.g. "ctrl+minus").
    public static let keysymCharacters: [String: Character] = [
        "minus": "-", "equal": "=", "plus": "+", "bracketleft": "[", "bracketright": "]", "braceleft": "{",
        "braceright": "}", "semicolon": ";", "colon": ":", "apostrophe": "'", "quotedbl": "\"", "grave": "`",
        "asciitilde": "~", "backslash": "\\", "bar": "|", "comma": ",", "less": "<", "period": ".", "greater": ">",
        "slash": "/", "question": "?", "exclam": "!", "at": "@", "numbersign": "#", "dollar": "$", "percent": "%",
        "asciicircum": "^", "ampersand": "&", "asterisk": "*", "parenleft": "(", "parenright": ")",
        "underscore": "_",
    ]

    /// A key by xdotool-style name or single character ("Return", "a", "A", "F5", "minus"). Modifiers are not
    /// keys; see `modifier(named:)`.
    public static func key(named name: String) -> Key? {
        if name.count == 1, let ch = name.first, let k = characters[ch] { return k }
        let lower = name.lowercased()
        if let k = namedKeys[lower] { return k }
        if let ch = keysymCharacters[lower], let k = characters[ch] { return k }
        return nil
    }

    public static func modifier(named name: String) -> Key? { modifiers[name.lowercased()] }

    /// A key or a modifier by name (for `keyDown` / `keyUp`).
    public static func anyKey(named name: String) -> Key? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return modifier(named: trimmed) ?? key(named: trimmed)
    }

    /// A parsed combination: modifiers to hold, then the key (nil when it is only modifiers, e.g. "super").
    public struct Combo: Sendable, Hashable {
        public var modifiers: [Key]
        public var key: Key?
    }

    /// Parses one xdotool-style combo: "ctrl+c", "ctrl+shift+t", "alt+F4", "super", "ctrl++" (ctrl and plus).
    public static func parseCombo(_ text: String) throws -> Combo {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw ZError.invalidArgument("empty key combination") }
        var parts: [String]
        if trimmed == "+" {
            parts = ["+"]
        } else if trimmed.hasSuffix("++") {
            parts = trimmed.dropLast(2).split(separator: "+", omittingEmptySubsequences: false).map(String.init) + ["+"]
        } else {
            parts = trimmed.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        }
        parts = parts.map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.contains(where: \.isEmpty) { throw ZError.invalidArgument("malformed key combination \"\(text)\"") }
        guard let last = parts.last else { throw ZError.invalidArgument("empty key combination") }
        var mods: [Key] = []
        for name in parts.dropLast() {
            guard let m = modifier(named: name) else { throw ZError.invalidArgument("unknown modifier \"\(name)\" in \"\(text)\"") }
            mods.append(m)
        }
        if let k = key(named: last) { return Combo(modifiers: mods, key: k) }
        if let m = modifier(named: last) { return Combo(modifiers: mods + [m], key: nil) }
        throw ZError.invalidArgument("unknown key \"\(last)\" in \"\(text)\"")
    }

    /// Parses a key sequence: combos separated by spaces ("ctrl+a Delete").
    public static func parseSequence(_ text: String) throws -> [Combo] {
        let combos = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !combos.isEmpty else { throw ZError.invalidArgument("empty key combination") }
        return try combos.map(parseCombo)
    }

    /// The scan codes of one combination: modifiers pressed in order (plus Shift when the key's character needs
    /// it), the key pressed and released, modifiers released in reverse order.
    public static func scancodes(for combo: Combo) -> [UInt8] {
        var mods = combo.modifiers
        if let key = combo.key, key.shift, !mods.contains(where: isShift) { mods.append(leftShift) }
        var out: [UInt8] = []
        for m in mods { out += m.make }
        if let key = combo.key { out += key.make + key.release }
        for m in mods.reversed() { out += m.release }
        return out
    }

    /// One scan-code group per combination of an xdotool key sequence ("ctrl+alt+t", "ctrl+a Delete").
    public static func scancodes(forKeys text: String) throws -> [[UInt8]] {
        try parseSequence(text).map(scancodes(for:))
    }

    /// One scan-code group per character of `text` (Shift wrapped around characters that need it).
    /// - Throws: `ZError.invalidArgument` listing characters a US keyboard cannot type.
    public static func typing(_ text: String) throws -> [[UInt8]] {
        let bad = untypableCharacters(in: text)
        guard bad.isEmpty else {
            throw ZError.invalidArgument("cannot type \(bad.map { "\"\($0)\"" }.joined(separator: ", ")) on a US keyboard")
        }
        return text.compactMap { ch -> [UInt8]? in
            guard let key = characters[ch] else { return nil }
            return key.shift ? leftShift.make + key.stroke + leftShift.release : key.stroke
        }
    }

    /// Characters of `text` that this table cannot type.
    public static func untypableCharacters(in text: String) -> [Character] {
        var out: [Character] = []
        for ch in text where characters[ch] == nil && !out.contains(ch) { out.append(ch) }
        return out
    }

    static func isShift(_ key: Key) -> Bool { key.make == [0x2A] || key.make == [0x36] }
}
