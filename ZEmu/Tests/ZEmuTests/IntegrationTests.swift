#if os(macOS)
import AppKit
import Foundation
import XCTest
import ZCore
@testable import ZEmu

/// Boots the real Alpine Linux virt x86 ISO in v86 inside a WKWebView (the same path the iOS app uses), on a Mac.
/// Downloads the ISO (50 MB) once into the temporary directory; skips when it cannot be downloaded.
///
/// Hard checks: the page loads, v86 starts, a serial line (ISOLINUX's banner / `boot:` prompt) arrives within 120 s,
/// and a non-blank screenshot. When the guest reaches its serial login prompt (soft, within 300 s): the serial shell,
/// file transfer, and a save/restore round trip.
@MainActor
final class EmuIntegrationTests: XCTestCase {
    private var t0 = Date()
    private var artifacts: URL?

    private func log(_ message: String) {
        let line = String(format: "ZEMU-IT [%6.1fs] ", Date().timeIntervalSince(t0)) + message
        print(line)
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return await condition()
    }

    private func save(_ data: Data, _ name: String) {
        guard let artifacts else { return }
        try? FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        try? data.write(to: artifacts.appendingPathComponent(name))
    }

    func testBootsAlpineVirtISOInWebKit() async throws {
        t0 = Date()
        artifacts = ProcessInfo.processInfo.environment["ZEMU_ARTIFACTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("zemu-integration", isDirectory: true)
        let store = EmuStore(root: base.appendingPathComponent("Emu", isDirectory: true))
        try store.prepare()
        let image = try XCTUnwrap(try EmuImageCatalog.bundled().image(id: "alpine-virt-x86"))
        let preparer = EmuImagePreparer(store: store)
        let prepared: EmuPreparedImage
        do {
            prepared = try await preparer.prepare(image)
        } catch {
            throw XCTSkip("could not download \(image.name): \(error)")
        }
        log("image ready: \(prepared.cdrom?.path ?? "?")")

        var spec = try EmuImageCatalog.makeSpec(for: image, prepared: prepared, name: "CI Alpine", memoryMB: 256)
        spec.network = .none
        try? store.delete(id: spec.id)
        let machine = try store.create(spec)
        let controller = EmuController(spec: machine, store: store)
        controller.syncClockAfterRestore = false

        // WebKit throttles pages whose view is not in a visible window: give it one, like the app does.
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 1024, height: 768), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        let serial = EmuLocked<String>("")
        let stream = controller.console.output(replay: true)
        let reader = Task {
            for await chunk in stream { serial.update { $0 += String(decoding: chunk, as: UTF8.self) } }
        }
        defer { reader.cancel() }

        do {
            try await controller.start()
        } catch {
            log("start failed: \(error)\npage log:\n" + controller.host.recentLogs.joined(separator: "\n"))
            throw error
        }
        log("emulator started")
        if let ping = try? await controller.host.call("ping") { log("page: \(ping.jsonString())") }

        // 1. A serial boot line.
        let sawBootLine = await waitUntil(120) { serial.get().contains("ISOLINUX") || serial.get().contains("boot:") }
        log("serial boot line: \(sawBootLine) — \(serial.get().prefix(120).debugDescription)")
        if !sawBootLine {
            log("page log:\n" + controller.host.recentLogs.joined(separator: "\n"))
            if let text = try? await controller.textScreen() { log("screen:\n" + text.joined(separator: "\n")) }
        }
        XCTAssertTrue(sawBootLine, "no serial output within 120 s")

        // 2. A non-blank screenshot.
        let surface = controller.makeSurface()
        var shot: ImageData?
        let nonBlank = await waitUntil(60) {
            guard let s = try? await surface.screenshot() else { return false }
            shot = s
            return !EmuImageTools.isBlank(png: s.data)
        }
        if let shot {
            save(shot.data, "screen-boot.png")
            let method = await surface.lastScreenshotMethod
            log("screenshot \(shot.width ?? 0)x\(shot.height ?? 0), \(shot.data.count) bytes, non-blank: \(nonBlank), "
                + "method \(method), mode \(controller.screenMode)")
        }
        XCTAssertTrue(nonBlank, "the screenshot stayed blank")

        // 3. Soft: the serial login prompt (boot assist adds console=ttyS0), then shell, files and states.
        let sawLogin = await waitUntil(300) { serial.get().contains("login:") }
        log("boot assist: \(controller.bootAssistResult ?? "-"); login prompt: \(sawLogin)")
        if sawLogin {
            let r = try await surface.shell("uname -m; cat /etc/alpine-release", timeout: 120)
            log("shell (\(String(format: "%.1f", r.durationSeconds)) s): exit \(r.exitCode) \(r.stdout.debugDescription)")
            XCTAssertEqual(r.exitCode, 0)
            XCTAssertTrue(r.stdout.contains("i686"), r.stdout)

            let payload = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 * 7) })
            try await surface.writeFile(path: "/tmp/zemu/payload.bin", data: payload)
            let back = try await surface.readFile(path: "/tmp/zemu/payload.bin")
            XCTAssertEqual(back, payload, "file round trip")
            let sum = try await surface.shell("sha256sum /tmp/zemu/payload.bin", timeout: 60)
            XCTAssertTrue(sum.stdout.contains(EmuSHA256.hex(of: payload)), sum.stdout)
            log("file round trip ok")

            let info = await surface.info
            log("info: shell \(info.shellAvailable) desktop \(info.hasDesktop) — \(info.notes)")

            let saved = try await controller.saveState()
            let size = try emuFileSize(saved)
            log("saved state: \(size >> 20) MiB")
            XCTAssertGreaterThan(size, 1 << 20)
            _ = try await surface.shell("echo after-save > /tmp/marker", timeout: 30)
            try await controller.restoreState(saved)
            let afterRestore = try await surface.shell("cat /tmp/marker 2>/dev/null || echo no-marker", timeout: 60)
            log("after restore: \(afterRestore.stdout.debugDescription)")
            XCTAssertTrue(afterRestore.stdout.contains("no-marker"), "the restored state predates the marker")
        } else {
            log("no serial login prompt within the time limit (soft check); serial tail:\n\(serial.get().suffix(800))")
        }
        save(Data(serial.get().utf8), "serial.log")
        save(Data(controller.host.recentLogs.joined(separator: "\n").utf8), "page.log")
        log("total \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        await controller.stop()
        XCTAssertEqual(controller.state, .stopped)
    }
}
#endif
