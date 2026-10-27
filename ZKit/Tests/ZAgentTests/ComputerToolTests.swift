import Foundation
import XCTest
import ZCore
@testable import ZAgent

final class ComputerToolTests: XCTestCase {
    private func call(_ args: JSONValue, id: String = "c") -> ToolCall { ToolCall(id: id, name: "computer", arguments: args) }

    func testSchemaIsTheBriefsFlatSchemaWithKeyDownAndKeyUp() throws {
        let params = ComputerTool.parameters(zoom: true)
        XCTAssertEqual(params["additionalProperties"], false)
        XCTAssertEqual(params["required"], ["action"])
        let actions = try XCTUnwrap(params["properties"]?["action"]?["enum"]?.arrayValue?.compactMap(\.stringValue))
        XCTAssertEqual(actions, ComputerAction.actionNames)
        XCTAssertTrue(actions.contains("key_down") && actions.contains("key_up") && actions.contains("triple_click"))
        XCTAssertEqual(params["properties"]?["amount"]?["maximum"], 30)
        XCTAssertNotNil(params["properties"]?["modifiers"])

        let noZoom = ComputerTool.parameters(zoom: false)
        XCTAssertNil(noZoom["properties"]?["region"])
        XCTAssertFalse(noZoom["properties"]?["action"]?["enum"]?.arrayValue?.contains("zoom") ?? true)
        // Pass-through resizer cannot crop → no zoom advertised.
        XCTAssertNil(ComputerTool().spec.parameters["properties"]?["region"])
    }

    func testActionParsing() throws {
        XCTAssertEqual(try ComputerAction(arguments: ["action": "triple_click", "x": 1, "y": 2]),
                       .click(at: ScreenPoint(x: 1, y: 2), button: .left, count: 3, modifiers: []))
        XCTAssertEqual(try ComputerAction(arguments: ["action": "click", "coordinate": [5, 6], "modifiers": "shift+ctrl"]),
                       .click(at: ScreenPoint(x: 5, y: 6), button: .left, count: 1, modifiers: ["shift", "ctrl"]))
        XCTAssertEqual(try ComputerAction(arguments: ["action": "scroll", "direction": "up", "amount": 99]),
                       .scroll(at: nil, dx: 0, dy: -30, modifiers: []))
        XCTAssertEqual(try ComputerAction(arguments: ["action": "key", "keys": "Return", "repeat": 3]), .key(combo: "Return", repeat: 3))
        XCTAssertEqual(try ComputerAction(arguments: ["action": "key_down", "keys": "shift"]), .keyDown(key: "shift"))
        XCTAssertEqual(try ComputerAction(arguments: ["action": "wait", "seconds": 100]), .wait(seconds: 30))
        XCTAssertEqual(try ComputerAction(arguments: ["action": "drag", "x": 1, "y": 2, "to_x": "3", "to_y": 4]),
                       .drag(from: ScreenPoint(x: 1, y: 2), to: ScreenPoint(x: 3, y: 4), modifiers: []))
        XCTAssertEqual(try ComputerAction(arguments: ["action": "mouse_down"]), .mouseDown(at: nil, button: .left))
        XCTAssertThrowsError(try ComputerAction(arguments: ["action": "mouse_move"]))
        XCTAssertThrowsError(try ComputerAction(arguments: ["action": "fly"]))
        XCTAssertThrowsError(try ComputerAction(arguments: [:]))
    }

    func testKeyNameNormalisation() {
        XCTAssertEqual(KeyNames.normalize("ENTER"), "Return")
        XCTAssertEqual(KeyNames.normalize("CTRL+A"), "ctrl+a")
        XCTAssertEqual(KeyNames.normalize("cmd+space"), "super+space")
        XCTAssertEqual(KeyNames.normalize("CMD+Q", guestOS: "macos"), "cmd+q")
        XCTAssertEqual(KeyNames.normalize("ARROWUP"), "Up")
        XCTAssertEqual(KeyNames.normalize("PAGEDOWN"), "Page_Down")
        XCTAssertEqual(KeyNames.normalize("alt+f4"), "alt+F4")
        XCTAssertEqual(KeyNames.normalize("OPTION+ESC"), "alt+Escape")
        XCTAssertEqual(KeyNames.normalize("ctrl+shift+t"), "ctrl+shift+t")
        XCTAssertEqual(KeyNames.normalize("BackSpace"), "BackSpace")
    }

    func testClickWithModifiersHoldsAndReleasesKeysAroundTheClick() async throws {
        let surface = MockSurface()
        let tool = ComputerTool(settleDelay: 0)
        let result = try await tool.invoke(call(["action": "click", "x": 10, "y": 20, "modifiers": "SHIFT+ctrl"]), ctx: testContext(surface: surface))
        XCTAssertFalse(result.isError)
        let calls = await surface.calls
        XCTAssertEqual(calls, [.keyDown("shift"), .keyDown("ctrl"), .click(10, 20, .left, 1), .keyUp("ctrl"), .keyUp("shift"), .screenshot])
        XCTAssertEqual(result.images.count, 1)
    }

    func testModifierClickOnASurfaceWithoutHeldKeysIsAClearError() async throws {
        let surface = MockSurface(heldKeys: false)
        let tool = ComputerTool(settleDelay: 0)
        do {
            _ = try await tool.invoke(call(["action": "click", "x": 1, "y": 1, "modifiers": "shift"]), ctx: testContext(surface: surface))
            XCTFail("expected an error")
        } catch let e as ZError {
            XCTAssertTrue(e.description.contains("not supported"), e.description)
        }
        let calls = await surface.calls
        XCTAssertTrue(calls.isEmpty, "no click without the modifier")
    }

    func testKeyDownKeyUpAndRepeatedKeys() async throws {
        let surface = MockSurface()
        let tool = ComputerTool(settleDelay: 0)
        let ctx = testContext(surface: surface)
        _ = try await tool.invoke(call(["action": "key_down", "keys": "SHIFT"]), ctx: ctx)
        _ = try await tool.invoke(call(["action": "key", "keys": "TAB", "repeat": 2]), ctx: ctx)
        _ = try await tool.invoke(call(["action": "key_up", "keys": "shift"]), ctx: ctx)
        let calls = await surface.calls
        XCTAssertEqual(calls, [.keyDown("shift"), .screenshot, .keys("Tab"), .keys("Tab"), .screenshot, .keyUp("shift"), .screenshot])
    }

    func testWaitReturnsNoScreenshotAndCursorIsTracked() async throws {
        let surface = MockSurface()
        let tool = ComputerTool(settleDelay: 0)
        let ctx = testContext(surface: surface)
        let wait = try await tool.invoke(call(["action": "wait", "seconds": 0]), ctx: ctx)
        XCTAssertTrue(wait.images.isEmpty)

        // Click without coordinates before any mouse action: unknown cursor.
        await XCTAssertThrowsAsync(try await tool.invoke(call(["action": "click"]), ctx: ctx))
        _ = try await tool.invoke(call(["action": "mouse_move", "x": 300, "y": 200]), ctx: ctx)
        _ = try await tool.invoke(call(["action": "click"]), ctx: ctx)
        let calls = await surface.calls
        XCTAssertTrue(calls.contains(.click(300, 200, .left, 1)))
        let execution = try await tool.execute([.cursorPosition], on: surface)
        XCTAssertEqual(execution.cursor, ScreenPoint(x: 300, y: 200))
    }

    func testCoordinatesAreScaledBackToTheSurface() async throws {
        let surface = MockSurface(size: PixelSize(width: 2732, height: 1536))
        let tool = ComputerTool(resizer: FakeResizer(), settleDelay: 0)
        let ctx = testContext(surface: surface)
        let shot = try await tool.invoke(call(["action": "screenshot"]), ctx: ctx)
        XCTAssertEqual(shot.images.first?.width, 1366)
        XCTAssertEqual(shot.images.first?.height, 768)
        _ = try await tool.invoke(call(["action": "click", "x": 683, "y": 384]), ctx: ctx)
        _ = try await tool.invoke(call(["action": "drag", "x": 0, "y": 0, "to_x": 1365, "to_y": 767]), ctx: ctx)
        let calls = await surface.calls
        XCTAssertTrue(calls.contains(.click(1366, 768, .left, 1)))
        XCTAssertTrue(calls.contains(.drag(0, 0, 2730, 1534)))
    }

    func testZoomCropsAtFullResolutionWithoutChangingTheMapping() async throws {
        let surface = MockSurface(size: PixelSize(width: 2732, height: 1536))
        let resizer = FakeResizer()
        let tool = ComputerTool(resizer: resizer, settleDelay: 0)
        let ctx = testContext(surface: surface)
        _ = try await tool.invoke(call(["action": "screenshot"]), ctx: ctx)
        let zoom = try await tool.invoke(call(["action": "zoom", "region": [0, 0, 683, 384]]), ctx: ctx)
        XCTAssertEqual(zoom.images.count, 1)
        XCTAssertEqual(resizer.crops.first, ScreenRect(x: 0, y: 0, width: 1366, height: 768))
        XCTAssertEqual(zoom.images.first?.width, 1366)
        let mapping = await tool.currentMapping(for: surface)
        XCTAssertEqual(mapping.modelSize, PixelSize(width: 1366, height: 768))

        let noCrop = ComputerTool(settleDelay: 0)
        await XCTAssertThrowsAsync(try await noCrop.invoke(call(["action": "zoom", "region": [0, 0, 10, 10]]), ctx: ctx))
    }
}

/// XCTAssertThrowsError for async expressions.
func XCTAssertThrowsAsync<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}
