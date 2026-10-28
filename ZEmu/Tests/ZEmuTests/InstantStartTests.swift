#if os(macOS)
import AppKit
import Foundation
import XCTest
import ZCore
@testable import ZEmu

/// The iPhone app's instant-start path, end to end on a Mac: fetches the published images-v1 `manifest.json`,
/// downloads and prepares Z Alpine Desktop (x86) with `EmuImagePreparer` (~118 MiB: disk image + v86 state, both
/// `.xz`; kept under `$RUNNER_TEMP` on CI), restores the state in a WKWebView exactly as the app's spec does, and
/// checks: the serial shell answers `echo ok` within 60 s, a non-blank 1024x768 screenshot, the guest's VMware
/// absolute pointer (and that a move lands on the X pointer), and that the guest clock was set from the host.
/// Skips when the release cannot be downloaded.
@MainActor
final class EmuInstantStartTests: XCTestCase {
    private var t0 = Date()
    private var artifacts: URL?

    private func log(_ message: String) {
        print(String(format: "ZEMU-IT instant [%6.1fs] ", Date().timeIntervalSince(t0)) + message)
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

    /// Network trouble (skip) as opposed to a broken image or emulator (fail).
    private static func isDownloadFailure(_ error: any Error) -> Bool {
        if error is URLError { return true }
        if let z = error as? ZError {
            switch z {
            case .http, .network: return true
            default: return false
            }
        }
        return (error as NSError).domain == NSURLErrorDomain
    }

    private static func seconds(_ value: TimeInterval) -> String { String(format: "%.1f s", value) }

    /// `x:699 y:499 screen:0 window:…` (xdotool getmouselocation) → 699 for "x".
    private static func field(_ name: String, in text: String) -> Int? {
        for part in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" }) where part.hasPrefix(name + ":") {
            return Int(part.dropFirst(name.count + 1))
        }
        return nil
    }

    func testRestoresZAlpineDesktopFromItsSavedState() async throws {
        t0 = Date()
        let env = ProcessInfo.processInfo.environment
        artifacts = env["ZEMU_ARTIFACTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let cacheBase = env["RUNNER_TEMP"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let store = EmuStore(root: cacheBase.appendingPathComponent("zemu-instant-start/Emu", isDirectory: true))
        try store.prepare()

        // 1. The manifest, as the app resolves it.
        let bundled = try XCTUnwrap(try EmuImageCatalog.bundled().image(id: "z-alpine-desktop-x86"))
        let image: EmuImage
        do {
            image = try await EmuImageCatalog.resolve(bundled)
        } catch {
            if Self.isDownloadFailure(error) { throw XCTSkip("manifest.json is not reachable: \(error)") }
            throw error
        }
        log("manifest \(image.version ?? "?"): "
            + image.files.map { "\($0.role.rawValue) \($0.name) \($0.sizeBytes ?? 0) B" }.joined(separator: ", "))
        XCTAssertEqual(image.kind, .instantStart, "the published state needs another v86 build: \(image.notes)")
        XCTAssertEqual(image.emulatorCommit, EmuResources.v86Commit)

        // 2. Download, sha256, unpack (resumes / reuses a finished preparation).
        let preparer = EmuImagePreparer(store: store)
        let prepareStart = Date()
        let start = t0
        let lastStep = EmuLocked<String>("")
        let prepared: EmuPreparedImage
        do {
            prepared = try await preparer.prepare(image) { p in
                // One line per step and file ("Downloading x.img.xz", "Checking x.img.xz", "Unpacking …").
                let step = p.detail.split(separator: ":").first.map(String.init) ?? p.detail
                guard step != lastStep.get() else { return }
                lastStep.set(step)
                print(String(format: "ZEMU-IT instant [%6.1fs] ", Date().timeIntervalSince(start)) + step)
            }
        } catch {
            if Self.isDownloadFailure(error) { throw XCTSkip("could not download \(image.name): \(error)") }
            throw error
        }
        let prepareSeconds = Date().timeIntervalSince(prepareStart)
        let disk = try XCTUnwrap(prepared.hda)
        let state = try XCTUnwrap(prepared.state)
        let diskBytes = (try? emuFileSize(disk)) ?? 0
        let stateBytes = (try? emuFileSize(state)) ?? 0
        log("prepared in \(Self.seconds(prepareSeconds)): \(disk.lastPathComponent) (\(diskBytes) B), "
            + "\(state.lastPathComponent) (\(stateBytes) B)")

        // 3. The machine the app creates (no guest network by default), restored in a visible WKWebView.
        var spec = try EmuImageCatalog.makeSpec(for: image, prepared: prepared, name: "CI Z Alpine Desktop", memoryMB: 256)
        spec.network = .none
        XCTAssertEqual(spec.memoryMB, 512, "instant start must keep the state's memory size")
        XCTAssertEqual(spec.initialState, state)
        let machine = try store.create(spec)
        defer { try? store.delete(id: machine.id) }
        let controller = EmuController(spec: machine, store: store)
        XCTAssertTrue(controller.syncClockAfterRestore)

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

        let restoreStart = Date()
        do {
            try await controller.start()
        } catch {
            log("start failed: \(error)\npage log:\n" + controller.host.recentLogs.joined(separator: "\n"))
            throw error
        }
        let restoreSeconds = Date().timeIntervalSince(restoreStart)
        log("restored in \(Self.seconds(restoreSeconds)) (from \(controller.startedFromState?.lastPathComponent ?? "no state"))")
        XCTAssertEqual(controller.startedFromState, state)

        // 4. The serial shell (a logged-in bash of z in the saved state).
        let surface = controller.makeSurface()
        let shellStart = Date()
        let echo: ShellResult
        do {
            echo = try await surface.shell("echo ok", timeout: 60)
        } catch {
            log("serial shell failed: \(error)\nserial tail:\n\(serial.get().suffix(1500))\npage log:\n"
                + controller.host.recentLogs.joined(separator: "\n"))
            throw error
        }
        let echoSeconds = Date().timeIntervalSince(shellStart)
        log("echo ok round trip: \(Self.seconds(echoSeconds)), exit \(echo.exitCode), \(echo.stdout.debugDescription)")
        XCTAssertEqual(echo.exitCode, 0)
        XCTAssertEqual(echo.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "ok")
        XCTAssertLessThan(echoSeconds, 60)

        // 5. The desktop: 1024x768 graphics, non-blank.
        let graphical = await waitUntil(30) {
            controller.screenMode.isGraphical && controller.displaySize == PixelSize(width: 1024, height: 768)
        }
        let shotStart = Date()
        let shot = try await surface.screenshot()
        let shotSeconds = Date().timeIntervalSince(shotStart)
        save(shot.data, "instant-start-screen.png")
        let blank = EmuImageTools.isBlank(png: shot.data)
        log("screen \(controller.screenMode); screenshot \(shot.width ?? 0)x\(shot.height ?? 0), \(shot.data.count) bytes, "
            + "\(Self.seconds(shotSeconds)), blank: \(blank)")
        XCTAssertTrue(graphical, "the restored display is \(controller.screenMode), expected 1024x768 graphics")
        XCTAssertEqual(shot.width, 1024)
        XCTAssertEqual(shot.height, 768)
        XCTAssertFalse(blank, "the restored desktop screenshot is a flat colour")

        // 6. The pointer the app's touch layer uses: VMware absolute, landing where it was sent.
        let absolute = await waitUntil(10) { controller.absoluteMouseActive }
        XCTAssertTrue(absolute, "v86 did not report the guest's VMware absolute pointer after the restore")
        try await surface.mouseMove(x: 700, y: 500)
        let method = await surface.lastMouseMethod
        XCTAssertEqual(method, "vmware-absolute")
        var location = ""
        let landed = await waitUntil(15) {
            let query = "export DISPLAY=:0; [ -f \"$HOME/.Xauthority\" ] && export XAUTHORITY=\"$HOME/.Xauthority\"; "
                + "xdotool getmouselocation 2>&1"
            guard let r = try? await surface.shell(query, timeout: 20) else { return false }
            location = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let x = Self.field("x", in: location), let y = Self.field("y", in: location) else { return false }
            return abs(x - 700) <= 3 && abs(y - 500) <= 3
        }
        log("absolute pointer: \(absolute) (\(method)); X pointer after a move to (700, 500): \(location)")
        if Self.field("x", in: location) != nil {
            XCTAssertTrue(landed, "the absolute move did not land on the X pointer: \(location)")
        }

        // 7. The guest clock: ZEmu sets it after a restore (the state's clock is the snapshot's).
        var guestOffset = Double.nan
        let clockSet = await waitUntil(60) {
            guard let r = try? await surface.shell("date +%s", timeout: 20),
                  let guest = Double(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
            guestOffset = guest - Date().timeIntervalSince1970
            return abs(guestOffset) < 120
        }
        log("guest clock offset after the restore: \(Self.seconds(guestOffset))")
        XCTAssertTrue(clockSet, "the guest clock was not set after the restore (offset \(guestOffset) s)")

        log("summary: prepare \(Self.seconds(prepareSeconds)), restore \(Self.seconds(restoreSeconds)), "
            + "echo ok \(Self.seconds(echoSeconds)), screenshot \(Self.seconds(shotSeconds)), "
            + "total \(Self.seconds(Date().timeIntervalSince(t0)))")
        save(Data(serial.get().utf8), "instant-start-serial.log")
        save(Data(controller.host.recentLogs.joined(separator: "\n").utf8), "instant-start-page.log")
        await controller.stop()
        XCTAssertEqual(controller.state, .stopped)
    }
}
#endif
