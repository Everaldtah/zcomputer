import Foundation
import XCTest
import ZCore
@testable import ZEmu

final class ScanCodesTests: XCTestCase {
    func testTypingPlainShiftedAndControlCharacters() throws {
        XCTAssertEqual(try ScanCodes.typing("a"), [[0x1E, 0x9E]])
        XCTAssertEqual(try ScanCodes.typing("A"), [[0x2A, 0x1E, 0x9E, 0xAA]])
        XCTAssertEqual(try ScanCodes.typing("!"), [[0x2A, 0x02, 0x82, 0xAA]])
        XCTAssertEqual(try ScanCodes.typing("_"), [[0x2A, 0x0C, 0x8C, 0xAA]])
        XCTAssertEqual(try ScanCodes.typing("~"), [[0x2A, 0x29, 0xA9, 0xAA]])
        XCTAssertEqual(try ScanCodes.typing("\n"), [[0x1C, 0x9C]])
        XCTAssertEqual(try ScanCodes.typing("\r\n"), [[0x1C, 0x9C]], "CRLF is one Return")
        XCTAssertEqual(try ScanCodes.typing("\t"), [[0x0F, 0x8F]])
        XCTAssertEqual(try ScanCodes.typing(" 0/"), [[0x39, 0xB9], [0x0B, 0x8B], [0x35, 0xB5]])
        XCTAssertEqual(try ScanCodes.typing("ls -la | grep \"x\"").count, 17)
    }

    func testEveryPrintableASCIICharacterIsTypable() {
        for scalar in 32...126 {
            let ch = Character(UnicodeScalar(UInt8(scalar)))
            XCTAssertNotNil(ScanCodes.characters[ch], "missing \(ch)")
        }
    }

    func testUntypableCharacters() {
        XCTAssertEqual(ScanCodes.untypableCharacters(in: "héllo → é"), ["é", "→"])
        XCTAssertThrowsError(try ScanCodes.typing("naïve"))
    }

    func testCombos() throws {
        XCTAssertEqual(try ScanCodes.scancodes(forKeys: "ctrl+alt+t"), [[0x1D, 0x38, 0x14, 0x94, 0xB8, 0x9D]])
        XCTAssertEqual(try ScanCodes.scancodes(forKeys: "ctrl+c"), [[0x1D, 0x2E, 0xAE, 0x9D]])
        XCTAssertEqual(try ScanCodes.scancodes(forKeys: "Return"), [[0x1C, 0x9C]])
        XCTAssertEqual(try ScanCodes.scancodes(forKeys: "KP_Enter"), [[0xE0, 0x1C, 0xE0, 0x9C]])
        XCTAssertEqual(try ScanCodes.scancodes(forKeys: "Delete"), [[0xE0, 0x53, 0xE0, 0xD3]])
        XCTAssertEqual(try ScanCodes.scancodes(forKeys: "alt+F4"), [[0x38, 0x3E, 0xBE, 0xB8]])
        XCTAssertEqual(try ScanCodes.scancodes(forKeys: "F12"), [[0x58, 0xD8]])
        XCTAssertEqual(try ScanCodes.scancodes(forKeys: "super"), [[0xE0, 0x5B, 0xE0, 0xDB]])
        XCTAssertEqual(try ScanCodes.scancodes(forKeys: "ctrl+minus"), [[0x1D, 0x0C, 0x8C, 0x9D]])
        XCTAssertEqual(try ScanCodes.scancodes(forKeys: "Page_Down"), [[0xE0, 0x51, 0xE0, 0xD1]])
        XCTAssertEqual(try ScanCodes.scancodes(forKeys: "alt_r+e"), [[0xE0, 0x38, 0x12, 0x92, 0xE0, 0xB8]])
    }

    func testShiftedKeysInCombosAddShiftOnce() throws {
        let expected: [[UInt8]] = [[0x1D, 0x2A, 0x14, 0x94, 0xAA, 0x9D]]
        XCTAssertEqual(try ScanCodes.scancodes(forKeys: "ctrl+T"), expected)
        XCTAssertEqual(try ScanCodes.scancodes(forKeys: "ctrl+shift+t"), expected)
        XCTAssertEqual(try ScanCodes.scancodes(forKeys: "ctrl+shift+T"), expected, "Shift is not pressed twice")
        XCTAssertEqual(try ScanCodes.scancodes(forKeys: "ctrl++"), [[0x1D, 0x2A, 0x0D, 0x8D, 0xAA, 0x9D]])
        XCTAssertEqual(try ScanCodes.scancodes(forKeys: "+"), [[0x2A, 0x0D, 0x8D, 0xAA]])
    }

    func testSequencesAndErrors() throws {
        XCTAssertEqual(try ScanCodes.scancodes(forKeys: "ctrl+a Delete"), [[0x1D, 0x1E, 0x9E, 0x9D], [0xE0, 0x53, 0xE0, 0xD3]])
        XCTAssertThrowsError(try ScanCodes.parseCombo(""))
        XCTAssertThrowsError(try ScanCodes.parseCombo("ctrl+"))
        XCTAssertThrowsError(try ScanCodes.parseCombo("hyper+a"))
        XCTAssertThrowsError(try ScanCodes.parseCombo("ctrl+nosuchkey"))
    }

    func testHeldKeysAndSpecials() {
        XCTAssertEqual(ScanCodes.anyKey(named: "shift")?.make, [0x2A])
        XCTAssertEqual(ScanCodes.anyKey(named: "Control_R")?.release, [0xE0, 0x9D])
        XCTAssertEqual(ScanCodes.anyKey(named: "a")?.stroke, [0x1E, 0x9E])
        XCTAssertEqual(ScanCodes.anyKey(named: "Pause")?.make, [0xE1, 0x1D, 0x45, 0xE1, 0x9D, 0xC5])
        XCTAssertEqual(ScanCodes.anyKey(named: "Pause")?.release, [])
        XCTAssertEqual(ScanCodes.anyKey(named: "Print")?.make, [0xE0, 0x2A, 0xE0, 0x37])
        XCTAssertNil(ScanCodes.anyKey(named: "nope"))
    }
}

final class CursorTrackerTests: XCTestCase {
    func testSplitAddsUpAndRespectsTheStep() {
        let packets = CursorTracker.split(dx: 25, dy: -7, step: 10)
        XCTAssertEqual(packets.count, 3)
        XCTAssertEqual(packets.reduce(0) { $0 + $1.dx }, 25)
        XCTAssertEqual(packets.reduce(0) { $0 + $1.dy }, -7)
        XCTAssertTrue(packets.allSatisfy { abs($0.dx) <= 10 && abs($0.dy) <= 10 })
        XCTAssertEqual(CursorTracker.split(dx: 0, dy: 0, step: 10), [])
        let big = CursorTracker.split(dx: -1000, dy: 333, step: 7)
        XCTAssertEqual(big.reduce(0) { $0 + $1.dx }, -1000)
        XCTAssertEqual(big.reduce(0) { $0 + $1.dy }, 333)
        XCTAssertTrue(big.allSatisfy { abs($0.dx) <= 7 && abs($0.dy) <= 7 })
    }

    func testHomingOvershootsTheScreen() {
        let tracker = CursorTracker(screen: PixelSize(width: 1024, height: 768), sensitivity: 1, maxStep: 10, homingStep: 120)
        let home = tracker.homingPackets()
        XCTAssertEqual(home.count, 18)
        XCTAssertEqual(home.reduce(0) { $0 + $1.dx }, -2048)
        XCTAssertEqual(home.reduce(0) { $0 + $1.dy }, -1536)
        XCTAssertTrue(home.allSatisfy { $0.dx <= 0 && $0.dy <= 0 && abs($0.dx) <= 120 && abs($0.dy) <= 120 })
        // A fast pointer (2 px per count) still needs the full distance: never fewer counts than pixels.
        let fast = CursorTracker(screen: PixelSize(width: 100, height: 100), sensitivity: 2).homingPackets()
        XCTAssertEqual(fast.reduce(0) { $0 + $1.dx }, -200)
        // A slow pointer (0.5 px per count) needs twice the counts.
        let slow = CursorTracker(screen: PixelSize(width: 100, height: 100), sensitivity: 0.5).homingPackets()
        XCTAssertEqual(slow.reduce(0) { $0 + $1.dx }, -400)
    }

    func testMovesFromHome() {
        var tracker = CursorTracker(screen: PixelSize(width: 1024, height: 768), sensitivity: 1, maxStep: 10)
        XCTAssertNil(tracker.position)
        let first = tracker.move(to: PixelPoint(x: 100, y: 50), rehome: false)
        XCTAssertEqual(first.count, 18 + 10, "unknown position: home first, then 100 px in 10-count packets")
        XCTAssertEqual(first.suffix(10).reduce(0) { $0 + $1.dx }, 100)
        XCTAssertEqual(first.suffix(10).reduce(0) { $0 + $1.dy }, 50)
        XCTAssertEqual(tracker.position, PixelPoint(x: 100, y: 50))

        let second = tracker.move(to: PixelPoint(x: 110, y: 50), rehome: false)
        XCTAssertEqual(second, [MouseDelta(dx: 10, dy: 0)])

        let rehomed = tracker.move(to: PixelPoint(x: 110, y: 50), rehome: true)
        XCTAssertEqual(rehomed.count, 18 + 11)

        let clamped = tracker.move(to: PixelPoint(x: 5000, y: -3), rehome: false)
        XCTAssertEqual(tracker.position, PixelPoint(x: 1023, y: 0))
        XCTAssertEqual(clamped.reduce(0) { $0 + $1.dx }, 913)
        XCTAssertEqual(clamped.reduce(0) { $0 + $1.dy }, -50)
    }

    func testSensitivityScalesCounts() {
        var tracker = CursorTracker(screen: PixelSize(width: 800, height: 600), sensitivity: 2, maxStep: 50)
        tracker.didHome()
        let packets = tracker.move(to: PixelPoint(x: 100, y: 0), rehome: false)
        XCTAssertEqual(packets.reduce(0) { $0 + $1.dx }, 50)
        tracker.invalidate()
        XCTAssertNil(tracker.position)
        tracker.assume(PixelPoint(x: 900, y: 900))
        XCTAssertEqual(tracker.position, PixelPoint(x: 799, y: 599))
    }

    func testAbsoluteArguments() {
        XCTAssertEqual(CursorTracker.absoluteArguments(for: PixelPoint(x: 0, y: 0), screen: PixelSize(width: 1024, height: 768)),
                       [0.5, 0.5, 1024, 768])
        XCTAssertEqual(CursorTracker.absoluteArguments(for: PixelPoint(x: 700, y: 500), screen: PixelSize(width: 1024, height: 768)),
                       [700.5, 500.5, 1024, 768])
    }
}

final class HostMessageTests: XCTestCase {
    func testParsesPageMessages() {
        XCTAssertEqual(EmuHost.parse(["type": "page", "v86": true] as [String: Any]), .pageLoaded)
        XCTAssertEqual(EmuHost.parse(["type": "serial", "data": Data("hi\r\n".utf8).base64EncodedString()] as [String: Any]),
                       .serial(Data("hi\r\n".utf8)))
        XCTAssertEqual(EmuHost.parse(["type": "screen", "width": 1024, "height": 768, "bpp": 32] as [String: Any]),
                       .screenSize(width: 1024, height: 768, bpp: 32))
        XCTAssertEqual(EmuHost.parse(["type": "absolute-mouse", "enabled": true] as [String: Any]), .absoluteMouse(true))
        XCTAssertEqual(EmuHost.parse(["type": "progress", "file": "x.iso", "loaded": 5, "total": 10] as [String: Any]),
                       .progress(file: "x.iso", loaded: 5, total: 10))
        XCTAssertEqual(EmuHost.parse(["type": "error", "message": "boom"] as [String: Any]), .error("boom"))
        XCTAssertNil(EmuHost.parse(["type": "unknown"] as [String: Any]))
        XCTAssertNil(EmuHost.parse("not a dictionary"))
        XCTAssertNil(EmuHost.parse(["type": "serial", "data": "%%%"] as [String: Any]))
    }
}
