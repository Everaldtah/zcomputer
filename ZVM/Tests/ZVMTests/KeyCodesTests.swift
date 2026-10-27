import XCTest
import ZCore
@testable import ZVM

final class KeyCodesTests: XCTestCase {
    func testLettersDigitsAndShift() throws {
        XCTAssertEqual(KeyCodes.characters["a"], KeyCodes.Key(keyCode: 0x00, shift: false, characters: "a"))
        XCTAssertEqual(KeyCodes.characters["A"], KeyCodes.Key(keyCode: 0x00, shift: true, characters: "A"))
        XCTAssertEqual(KeyCodes.characters["z"]?.keyCode, 0x06)
        XCTAssertEqual(KeyCodes.characters["m"]?.keyCode, 0x2E)
        XCTAssertEqual(KeyCodes.characters["1"]?.keyCode, 0x12)
        XCTAssertEqual(KeyCodes.characters["0"]?.keyCode, 0x1D)
        XCTAssertEqual(KeyCodes.characters["!"], KeyCodes.Key(keyCode: 0x12, shift: true, characters: "!"))
        XCTAssertEqual(KeyCodes.characters["~"]?.keyCode, 0x32)
        XCTAssertEqual(KeyCodes.characters["~"]?.shift, true)
        XCTAssertEqual(KeyCodes.characters["/"]?.keyCode, 0x2C)
        XCTAssertEqual(KeyCodes.characters["?"]?.shift, true)
        XCTAssertEqual(KeyCodes.characters[" "]?.keyCode, 0x31)
        XCTAssertEqual(KeyCodes.characters["\n"]?.keyCode, 0x24)
        XCTAssertEqual(KeyCodes.characters["\r\n"]?.keyCode, 0x24)
        XCTAssertEqual(KeyCodes.characters["\t"]?.keyCode, 0x30)
        // Every printable ASCII character is typable.
        for scalar in (0x20...0x7E).compactMap({ Unicode.Scalar(UInt32($0)) }) {
            XCTAssertNotNil(KeyCodes.characters[Character(scalar)], "missing \(scalar)")
        }
    }

    func testNamedKeys() {
        XCTAssertEqual(KeyCodes.key(named: "Return")?.keyCode, 0x24)
        XCTAssertEqual(KeyCodes.key(named: "enter")?.keyCode, 0x24)
        XCTAssertEqual(KeyCodes.key(named: "BackSpace")?.keyCode, 0x33)
        XCTAssertEqual(KeyCodes.key(named: "Delete")?.keyCode, 0x75)
        XCTAssertEqual(KeyCodes.key(named: "Escape")?.keyCode, 0x35)
        XCTAssertEqual(KeyCodes.key(named: "Page_Up")?.keyCode, 0x74)
        XCTAssertEqual(KeyCodes.key(named: "Next")?.keyCode, 0x79)
        XCTAssertEqual(KeyCodes.key(named: "Left")?.keyCode, 0x7B)
        XCTAssertEqual(KeyCodes.key(named: "Up")?.keyCode, 0x7E)
        XCTAssertEqual(KeyCodes.key(named: "F1")?.keyCode, 0x7A)
        XCTAssertEqual(KeyCodes.key(named: "F4")?.keyCode, 0x76)
        XCTAssertEqual(KeyCodes.key(named: "F12")?.keyCode, 0x6F)
        XCTAssertEqual(KeyCodes.key(named: "F20")?.keyCode, 0x5A)
        XCTAssertEqual(KeyCodes.key(named: "KP_Enter")?.keyCode, 0x4C)
        XCTAssertEqual(KeyCodes.key(named: "minus")?.keyCode, 0x1B)
        XCTAssertEqual(KeyCodes.key(named: "plus")?.shift, true)
        XCTAssertEqual(KeyCodes.key(named: "a")?.shift, false)
        XCTAssertEqual(KeyCodes.key(named: "A")?.shift, true)
        XCTAssertNil(KeyCodes.key(named: "NoSuchKey"))
    }

    func testModifiersCarryDeviceDependentBits() throws {
        let shift = try XCTUnwrap(KeyCodes.modifier(named: "shift"))
        XCTAssertEqual(shift.keyCode, 0x38)
        XCTAssertEqual(shift.flags, (1 << 17) | 0x02)
        let ctrl = try XCTUnwrap(KeyCodes.modifier(named: "Ctrl"))
        XCTAssertEqual(ctrl.keyCode, 0x3B)
        XCTAssertEqual(ctrl.flags, (1 << 18) | 0x01)
        let alt = try XCTUnwrap(KeyCodes.modifier(named: "alt"))
        XCTAssertEqual(alt.keyCode, 0x3A)
        XCTAssertEqual(alt.flags, (1 << 19) | 0x20)
        let superKey = try XCTUnwrap(KeyCodes.modifier(named: "super"))
        XCTAssertEqual(superKey.keyCode, 0x37)
        XCTAssertEqual(superKey.flags, (1 << 20) | 0x08)
        XCTAssertEqual(KeyCodes.modifier(named: "win"), KeyCodes.modifier(named: "cmd"))
        XCTAssertEqual(KeyCodes.modifier(named: "shift_r")?.flags, (1 << 17) | 0x04)
        XCTAssertEqual(KeyCodes.modifier(named: "control_r")?.flags, (1 << 18) | 0x2000)
    }

    func testComboParsing() throws {
        let copy = try KeyCodes.parseCombo("ctrl+c")
        XCTAssertEqual(copy.modifiers.map(\.name), ["ctrl"])
        XCTAssertEqual(copy.key?.keyCode, 0x08)

        let reopen = try KeyCodes.parseCombo("ctrl+shift+t")
        XCTAssertEqual(reopen.modifiers.map(\.name), ["ctrl", "shift"])
        XCTAssertEqual(reopen.key?.keyCode, 0x11)

        let close = try KeyCodes.parseCombo("alt+F4")
        XCTAssertEqual(close.modifiers.map(\.name), ["alt"])
        XCTAssertEqual(close.key?.keyCode, 0x76)

        let zoom = try KeyCodes.parseCombo("ctrl++")
        XCTAssertEqual(zoom.modifiers.map(\.name), ["ctrl"])
        XCTAssertEqual(zoom.key?.keyCode, 0x18)
        XCTAssertEqual(zoom.key?.shift, true)

        let plus = try KeyCodes.parseCombo("+")
        XCTAssertTrue(plus.modifiers.isEmpty)
        XCTAssertEqual(plus.key?.keyCode, 0x18)

        let superOnly = try KeyCodes.parseCombo("super")
        XCTAssertNil(superOnly.key)
        XCTAssertEqual(superOnly.modifiers.map(\.keyCode), [0x37])

        XCTAssertThrowsError(try KeyCodes.parseCombo(""))
        XCTAssertThrowsError(try KeyCodes.parseCombo("ctrl+"))
        XCTAssertThrowsError(try KeyCodes.parseCombo("hyper+x"))
        XCTAssertThrowsError(try KeyCodes.parseCombo("ctrl+nosuchkey"))
    }

    func testSequences() throws {
        let seq = try KeyCodes.parseSequence("ctrl+a Delete")
        XCTAssertEqual(seq.count, 2)
        XCTAssertEqual(seq[0].key?.keyCode, 0x00)
        XCTAssertEqual(seq[1].key?.keyCode, 0x75)
        XCTAssertThrowsError(try KeyCodes.parseSequence("   "))
    }

    func testUntypableCharacters() {
        XCTAssertEqual(KeyCodes.untypableCharacters(in: "hello, world!"), [])
        XCTAssertEqual(KeyCodes.untypableCharacters(in: "café ☕ café"), ["é", "☕"])
    }
}
