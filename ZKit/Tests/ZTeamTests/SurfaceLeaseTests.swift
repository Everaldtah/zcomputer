import Foundation
import XCTest
import ZCore
import ZAgent
@testable import ZTeam

final class SurfaceLeaseTests: XCTestCase {
    /// Which agent made an input call in the lease tests ("a"/"b" from coordinates, text or key names).
    private func owner(_ call: MockSurface.Call) -> String {
        switch call {
        case .click(let x, _, _, _): return x == 1 ? "a" : "b"
        case .type(let text): return String(text.prefix(1))
        case .keys(let combo): return String(combo.suffix(1))
        default: return "?"
        }
    }

    func testLeaseSerialisesTwoWorkersInputSequences() async throws {
        let base = MockSurface(inputDelayMilliseconds: 5)
        let hub = TeamEventHub()
        let lease = SurfaceLease(maxHoldTime: 10, reporter: TeamReporter(hub: hub))
        let a = LeasedSurface(base: base, lease: lease, holder: "a")
        let b = LeasedSurface(base: base, lease: lease, holder: "b")

        let first = Task {
            try await a.withLease {
                try await a.click(x: 1, y: 1, button: .left, count: 1)
                try await Task.sleep(nanoseconds: 30_000_000)
                try await a.typeText("a1")
                try await a.pressKeys("ctrl+a")
                try await a.typeText("a2")
            }
        }
        await waitUntil { await lease.holder == "a" }
        let second = Task {
            try await b.withLease {
                try await b.click(x: 2, y: 2, button: .left, count: 1)
                try await b.typeText("b1")
                try await b.pressKeys("ctrl+b")
                try await b.typeText("b2")
            }
        }
        // b's sequence is queued behind a's.
        await waitUntil { await lease.waiting == ["b"] }
        try await first.value
        try await second.value

        let calls = await base.inputCalls
        XCTAssertEqual(calls.count, 8)
        XCTAssertEqual(runs(calls.map(owner)), ["a", "b"], "a's sequence ran whole, then b's: \(calls)")
        let waited = hub.history.contains { if case .lease(.waiting(let h, let o, _)) = $0 { return h == "b" && o == "a" } else { return false } }
        XCTAssertTrue(waited)
        let held = await lease.isHeld
        XCTAssertFalse(held, "withLease releases at the end")
    }

    func testScreenInputKeepsTheLeaseUntilTheAgentsScreenshot() async throws {
        let base = MockSurface()
        let lease = SurfaceLease(maxHoldTime: 10)
        let a = LeasedSurface(base: base, lease: lease, holder: "a")
        let b = LeasedSurface(base: base, lease: lease, holder: "b")

        try await a.click(x: 1, y: 1, button: .left, count: 1)
        let holder = await lease.holder
        XCTAssertEqual(holder, "a", "a keeps the lease until it has looked at the result")
        let typing = Task { try await b.typeText("b") }
        await waitUntil { await lease.waiting == ["b"] }
        try await a.typeText("a")          // a's group continues without waiting
        _ = try await a.screenshot()       // a looked: the lease moves on
        try await typing.value

        let calls = await base.calls
        XCTAssertEqual(calls, [.click(1, 1, .left, 1), .type("a"), .screenshot, .type("b")])
    }

    func testShellCallsTakeTheLeasePerCallOrSkipItWhenOutside() async throws {
        let base = MockSurface()
        let lease = SurfaceLease(maxHoldTime: 10)
        let inside = LeasedSurface(base: base, lease: lease, holder: "a")
        let outside = LeasedSurface(base: base, lease: lease, holder: "b", options: .init(shellOutsideLease: true))

        _ = try await inside.shell("ls", timeout: 5)
        let afterShell = await lease.isHeld
        XCTAssertFalse(afterShell, "shell releases right after the call")

        let grant = try await lease.acquire(holder: "c")
        _ = try await outside.shell("uptime", timeout: 5)   // does not wait for c
        let blocked = Task { _ = try await inside.shell("whoami", timeout: 5) }
        await waitUntil { await lease.waiting == ["a"] }
        await lease.release(grant)
        try await blocked.value
        let commands = await base.shellCommands
        XCTAssertEqual(commands, ["ls", "uptime", "whoami"])
    }

    func testScreenshotsDoNotWaitForTheLease() async throws {
        let base = MockSurface()
        let lease = SurfaceLease(maxHoldTime: 10)
        let b = LeasedSurface(base: base, lease: lease, holder: "b")
        let grant = try await lease.acquire(holder: "a")

        let shot = try await b.screenshot()
        XCTAssertFalse(shot.data.isEmpty)
        let info = await b.info
        XCTAssertEqual(info.name, "Mock VM")
        let size = await b.displaySize
        XCTAssertEqual(size, PixelSize(width: 1024, height: 768))

        let typing = Task { try await b.typeText("b") }
        await waitUntil { await lease.waiting == ["b"] }
        _ = try await b.screenshot()       // still fine while b's input waits
        let before = await base.typedTexts
        XCTAssertEqual(before, [], "input waits for the lease")
        await lease.release(grant)
        try await typing.value
        let after = await base.typedTexts
        XCTAssertEqual(after, ["b"])
        let shots = await base.calls.filter(\.isScreenshot).count
        XCTAssertEqual(shots, 2)
    }

    func testHeldKeysKeepTheLeaseUntilReleased() async throws {
        let base = MockSurface()
        let lease = SurfaceLease(maxHoldTime: 10)
        let a = LeasedSurface(base: base, lease: lease, holder: "a", options: .init(holdUntilScreenshot: false))
        let b = LeasedSurface(base: base, lease: lease, holder: "b")

        try await a.keyDown("shift")
        let typing = Task { try await b.typeText("b") }
        await waitUntil { await lease.waiting == ["b"] }
        try await a.click(x: 1, y: 1, button: .left, count: 1)
        try await a.keyUp("shift")         // nothing held any more: released (no screenshot hold for a)
        try await typing.value

        let calls = await base.inputCalls
        XCTAssertEqual(calls, [.keyDown("shift"), .click(1, 1, .left, 1), .keyUp("shift"), .type("b")])
    }

    func testMaxHoldTimeTakesTheLeaseBackAndReleasesHeldKeys() async throws {
        let base = MockSurface()
        let hub = TeamEventHub()
        let lease = SurfaceLease(maxHoldTime: 0.2, reporter: TeamReporter(hub: hub))
        let a = LeasedSurface(base: base, lease: lease, holder: "a")
        let b = LeasedSurface(base: base, lease: lease, holder: "b")

        try await a.keyDown("shift")       // a never lets go
        let holder = await lease.holder
        XCTAssertEqual(holder, "a")
        let started = Date()
        try await b.typeText("hello")      // gets the lease when a's hold expires
        let waited = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(waited, 0.1)

        let calls = await base.inputCalls
        XCTAssertEqual(calls, [.keyDown("shift"), .keyUp("shift"), .type("hello")], "a's shift is released before b types")
        let expired = hub.history.contains { if case .lease(.expired(let h, _)) = $0 { return h == "a" } else { return false } }
        XCTAssertTrue(expired)
        let keys = await a.keysHeld
        XCTAssertEqual(keys, [])
    }

    func testWaitingIsFIFOReentrantAndCancellable() async throws {
        let lease = SurfaceLease(maxHoldTime: 0)
        let g = try await lease.acquire(holder: "a")
        let again = try await lease.acquire(holder: "a")
        XCTAssertEqual(again.token, g.token, "re-entrant for the holder")

        let order = OrderLog()
        let b = Task {
            let grant = try await lease.acquire(holder: "b")
            await order.add("b")
            await lease.release(grant)
        }
        await waitUntil { await lease.waiting == ["b"] }
        let c = Task {
            let grant = try await lease.acquire(holder: "c")
            await order.add("c")
            await lease.release(grant)
        }
        await waitUntil { await lease.waiting == ["b", "c"] }
        let d = Task { try await lease.acquire(holder: "d") }
        await waitUntil { await lease.waiting.count == 3 }
        d.cancel()
        await waitUntil { await lease.waiting == ["b", "c"] }
        do {
            _ = try await d.value
            XCTFail("a cancelled wait throws")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected \(error)")
        }

        await lease.release(again)
        let stillA = await lease.holder
        XCTAssertEqual(stillA, "a", "one reference is left")
        await lease.release(g)
        try await b.value
        try await c.value
        let seen = await order.items
        XCTAssertEqual(seen, ["b", "c"])
        let held = await lease.isHeld
        XCTAssertFalse(held)
    }
}

actor OrderLog {
    private(set) var items: [String] = []
    func add(_ s: String) { items.append(s) }
}
