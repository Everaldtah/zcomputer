import Foundation
import ZCore

/// US-ANSI keyboard map for synthetic input into `VZVirtualMachineView`.
///
/// Key codes are physical Carbon `kVK_*` codes; Virtualization.framework converts them to USB HID usages, so
/// what the guest sees depends on the **guest** keyboard layout (assumed US). Text outside this map has to go
/// through the guest agent (`input` op, unicode via xdotool/wtype).
public enum KeyCodes {
    /// A key to press: physical key code, whether Shift is needed, and the characters a real event would carry.
    public struct Key: Sendable, Hashable {
        public var keyCode: UInt16
        public var shift: Bool
        public var characters: String
        public init(keyCode: UInt16, shift: Bool = false, characters: String = "") {
            self.keyCode = keyCode; self.shift = shift; self.characters = characters
        }
    }

    /// A modifier key. `flags` is the `NSEvent.ModifierFlags` raw value **including the device-dependent
    /// left/right bit** (NX_DEVICEL*KEYMASK): `VZVirtualMachineView` ignores modifier events without it.
    public struct Modifier: Sendable, Hashable {
        public var name: String
        public var keyCode: UInt16
        public var flags: UInt
    }

    // NSEvent.ModifierFlags device-independent bits.
    public static let shiftFlag: UInt = 1 << 17
    public static let controlFlag: UInt = 1 << 18
    public static let optionFlag: UInt = 1 << 19
    public static let commandFlag: UInt = 1 << 20
    // Device-dependent bits (IOKit NX_DEVICE*KEYMASK).
    public static let deviceLeftControl: UInt = 0x0001
    public static let deviceLeftShift: UInt = 0x0002
    public static let deviceRightShift: UInt = 0x0004
    public static let deviceLeftCommand: UInt = 0x0008
    public static let deviceRightCommand: UInt = 0x0010
    public static let deviceLeftOption: UInt = 0x0020
    public static let deviceRightOption: UInt = 0x0040
    public static let deviceRightControl: UInt = 0x2000

    /// Modifier names (lowercased), xdotool style. Linux "super"/"win"/"meta" is the HID GUI key = Mac Command.
    public static let modifiers: [String: Modifier] = {
        var m: [String: Modifier] = [:]
        func add(_ names: [String], _ code: UInt16, _ flags: UInt) {
            for n in names { m[n] = Modifier(name: names[0], keyCode: code, flags: flags) }
        }
        add(["shift", "shift_l", "lshift"], 0x38, shiftFlag | deviceLeftShift)
        add(["shift_r", "rshift"], 0x3C, shiftFlag | deviceRightShift)
        add(["ctrl", "control", "control_l", "ctrl_l", "lctrl"], 0x3B, controlFlag | deviceLeftControl)
        add(["control_r", "ctrl_r", "rctrl"], 0x3E, controlFlag | deviceRightControl)
        add(["alt", "option", "alt_l", "opt", "lalt"], 0x3A, optionFlag | deviceLeftOption)
        add(["alt_r", "option_r", "altgr", "iso_level3_shift", "ralt"], 0x3D, optionFlag | deviceRightOption)
        add(["super", "cmd", "command", "meta", "win", "windows", "super_l", "meta_l", "cmd_l", "logo"], 0x37,
            commandFlag | deviceLeftCommand)
        add(["super_r", "meta_r", "cmd_r"], 0x36, commandFlag | deviceRightCommand)
        return m
    }()

    /// Named (non-character) keys, lowercased; xdotool keysym names and common aliases.
    public static let namedKeys: [String: Key] = {
        var m: [String: Key] = [:]
        func add(_ names: [String], _ code: UInt16, _ chars: String = "") {
            for n in names { m[n] = Key(keyCode: code, shift: false, characters: chars) }
        }
        add(["return", "enter", "ret", "linefeed"], 0x24, "\r")
        add(["kp_enter"], 0x4C, "\u{03}")
        add(["tab"], 0x30, "\t")
        add(["space"], 0x31, " ")
        add(["backspace", "back_space", "bksp"], 0x33, "\u{7F}")
        add(["delete", "del", "forwarddelete"], 0x75)
        add(["escape", "esc"], 0x35, "\u{1B}")
        add(["left"], 0x7B); add(["right"], 0x7C); add(["down"], 0x7D); add(["up"], 0x7E)
        add(["home"], 0x73); add(["end"], 0x77)
        add(["pageup", "page_up", "prior", "pgup"], 0x74)
        add(["pagedown", "page_down", "next", "pgdn"], 0x79)
        add(["insert", "ins", "help"], 0x72)
        add(["caps_lock", "capslock"], 0x39)
        add(["menu", "contextmenu"], 0x6E)
        add(["fn", "function"], 0x3F)
        let fkeys: [UInt16] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F,
                               0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A]
        for (i, code) in fkeys.enumerated() { add(["f\(i + 1)"], code) }
        let keypad: [(String, UInt16, String)] = [("kp_0", 0x52, "0"), ("kp_1", 0x53, "1"), ("kp_2", 0x54, "2"),
            ("kp_3", 0x55, "3"), ("kp_4", 0x56, "4"), ("kp_5", 0x57, "5"), ("kp_6", 0x58, "6"), ("kp_7", 0x59, "7"),
            ("kp_8", 0x5B, "8"), ("kp_9", 0x5C, "9"), ("kp_decimal", 0x41, "."), ("kp_multiply", 0x43, "*"),
            ("kp_add", 0x45, "+"), ("kp_subtract", 0x4E, "-"), ("kp_divide", 0x4B, "/"), ("kp_equal", 0x51, "=")]
        for (n, c, s) in keypad { add([n], c, s) }
        add(["audiomute", "xf86audiomute", "mute"], 0x4A)
        add(["audiolowervolume", "xf86audiolowervolume", "volumedown"], 0x49)
        add(["audioraisevolume", "xf86audioraisevolume", "volumeup"], 0x48)
        return m
    }()

    /// Characters typable on a US-ANSI keyboard.
    public static let characters: [Character: Key] = {
        var m: [Character: Key] = [:]
        let letters: [(Character, UInt16)] = [("a", 0x00), ("s", 0x01), ("d", 0x02), ("f", 0x03), ("h", 0x04), ("g", 0x05),
            ("z", 0x06), ("x", 0x07), ("c", 0x08), ("v", 0x09), ("b", 0x0B), ("q", 0x0C), ("w", 0x0D), ("e", 0x0E),
            ("r", 0x0F), ("y", 0x10), ("t", 0x11), ("o", 0x1F), ("u", 0x20), ("i", 0x22), ("p", 0x23), ("l", 0x25),
            ("j", 0x26), ("k", 0x28), ("n", 0x2D), ("m", 0x2E)]
        for (c, k) in letters {
            m[c] = Key(keyCode: k, shift: false, characters: String(c))
            let upper = Character(c.uppercased())
            m[upper] = Key(keyCode: k, shift: true, characters: String(upper))
        }
        let plain: [(Character, UInt16)] = [("1", 0x12), ("2", 0x13), ("3", 0x14), ("4", 0x15), ("6", 0x16), ("5", 0x17),
            ("=", 0x18), ("9", 0x19), ("7", 0x1A), ("-", 0x1B), ("8", 0x1C), ("0", 0x1D), ("]", 0x1E), ("[", 0x21),
            ("'", 0x27), (";", 0x29), ("\\", 0x2A), (",", 0x2B), ("/", 0x2C), (".", 0x2F), ("`", 0x32), (" ", 0x31)]
        for (c, k) in plain { m[c] = Key(keyCode: k, shift: false, characters: String(c)) }
        let shifted: [(Character, UInt16)] = [("!", 0x12), ("@", 0x13), ("#", 0x14), ("$", 0x15), ("^", 0x16), ("%", 0x17),
            ("+", 0x18), ("(", 0x19), ("&", 0x1A), ("_", 0x1B), ("*", 0x1C), (")", 0x1D), ("}", 0x1E), ("{", 0x21),
            ("\"", 0x27), (":", 0x29), ("|", 0x2A), ("<", 0x2B), ("?", 0x2C), (">", 0x2F), ("~", 0x32)]
        for (c, k) in shifted { m[c] = Key(keyCode: k, shift: true, characters: String(c)) }
        m["\n"] = Key(keyCode: 0x24, shift: false, characters: "\r")
        m["\r"] = Key(keyCode: 0x24, shift: false, characters: "\r")
        m["\r\n"] = Key(keyCode: 0x24, shift: false, characters: "\r")
        m["\t"] = Key(keyCode: 0x30, shift: false, characters: "\t")
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

    /// Looks up a key by xdotool-style name or single character ("Return", "a", "A", "F5", "minus").
    /// Modifier names are not keys; see `modifier(named:)`.
    public static func key(named name: String) -> Key? {
        if name.count == 1, let ch = name.first, let k = characters[ch] { return k }
        let lower = name.lowercased()
        if let k = namedKeys[lower] { return k }
        if let ch = keysymCharacters[lower], let k = characters[ch] { return k }
        return nil
    }

    public static func modifier(named name: String) -> Modifier? {
        modifiers[name.lowercased()]
    }

    /// A parsed key combination: modifiers to hold, then the key (nil when the combo is only modifiers, e.g. "super").
    public struct Combo: Sendable, Hashable {
        public var modifiers: [Modifier]
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

        var mods: [Modifier] = []
        for name in parts.dropLast() {
            guard let m = modifier(named: name) else { throw ZError.invalidArgument("unknown modifier \"\(name)\" in \"\(text)\"") }
            mods.append(m)
        }
        if let k = key(named: last) { return Combo(modifiers: mods, key: k) }
        if let m = modifier(named: last) { return Combo(modifiers: mods + [m], key: nil) }
        throw ZError.invalidArgument("unknown key \"\(last)\" in \"\(text)\"")
    }

    /// Parses a key sequence: several combos separated by spaces ("ctrl+a Delete").
    public static func parseSequence(_ text: String) throws -> [Combo] {
        let combos = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !combos.isEmpty else { throw ZError.invalidArgument("empty key combination") }
        return try combos.map(parseCombo)
    }

    /// Characters of `text` that cannot be typed with this map (route them through the guest agent).
    public static func untypableCharacters(in text: String) -> [Character] {
        var out: [Character] = []
        for ch in text where characters[ch] == nil && !out.contains(ch) { out.append(ch) }
        return out
    }
}
