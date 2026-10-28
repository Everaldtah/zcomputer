#if canImport(ZEmu)
import Foundation
import UIKit
import ZCore
import ZEmu

/// One machine on ZEmu: an `EmuController` (v86 in a WKWebView) behind the app's `MachineRuntime`.
///
/// * **Saving.** Autosave every 2 minutes while running (`EmuController.enableAutosave`), and on `enterBackground`
///   (the app's `didEnterBackground`): pause, then save to the autosave slot, so a machine survives iOS ending the
///   app; `start()` resumes the autosave. "Save state" writes the same slot (the phone UI has no list of states).
///   Power off with `saveState: false` discards it: the next start is a fresh boot / the image's saved state.
/// * **Pointer.** `makeSurface()` is ZEmu's `EmuSurface` on its automatic route: the VMware absolute pointer
///   (`mouse-absolute` followed by `mouse-click` with the current buttons) whenever the guest enabled it — Z Alpine
///   Desktop's saved state has it on, and v86 reports it again on restore — else relative PS/2 tracking. The route
///   is decided per move from `EmuController.absoluteMouseActive`, so it follows the guest without a race.
/// * **Clock.** After resuming a saved state ZEmu sets the guest clock over the serial shell (`date -s @now`, else
///   `sudo -n date -s`; `EmuController.syncClockAfterRestore`).
@MainActor
final class ZEmuMachineRuntime: MachineRuntime {
    static let autosaveInterval: TimeInterval = 120

    let controller: EmuController
    let guestNetworkEnabled: Bool
    private var inBackground = false
    private var pausedForBackground = false

    init(spec: EmuSpec, store: EmuStore, guestNetwork: Bool, notificationCenter: NotificationCenter) {
        controller = EmuController(spec: spec, store: store)
        guestNetworkEnabled = guestNetwork
        controller.syncClockAfterRestore = true
        // Background saves are ordered (pause, save) by `enterBackground`, which MachinesModel calls inside a
        // background task when the scene enters the background; no notification-triggered save races with it.
        controller.enableAutosave(interval: Self.autosaveInterval, saveOn: [], center: notificationCenter)
    }

    var state: MachineRunState { Self.map(controller.state) }

    var screenView: UIView { controller.view }

    var screenSize: PixelSize { controller.displaySize }

    func stateStream() -> AsyncStream<MachineRunState> {
        let source = controller.stateUpdates
        let (stream, continuation) = AsyncStream<MachineRunState>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let task = Task {
            for await state in source { continuation.yield(Self.map(state)) }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func screenSizeStream() -> AsyncStream<PixelSize> {
        let events = controller.events()
        let emu = controller
        let (stream, continuation) = AsyncStream<PixelSize>.makeStream(bufferingPolicy: .bufferingNewest(8))
        continuation.yield(emu.displaySize)
        let task = Task { [weak emu] in
            for await event in events {
                guard case .screenSize = event, let emu else { continue }
                continuation.yield(emu.displaySize)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    // MARK: Lifecycle

    func start() async throws {
        pausedForBackground = false
        try await controller.start()
    }

    func stop(saveState: Bool) async throws {
        pausedForBackground = false
        await waitWhileSaving(seconds: 30)
        await controller.stop(saveState: saveState)
    }

    func pause() async throws {
        pausedForBackground = false
        try await controller.pause()
    }

    func resume() async throws {
        pausedForBackground = false
        try await controller.resume()
    }

    func saveState() async throws {
        await waitWhileSaving(seconds: 30)
        try await controller.saveState(to: autosaveURL)
    }

    func enterBackground() async {
        inBackground = true
        await waitWhileSaving(seconds: 20)
        guard inBackground else { return }
        if controller.state == .running {
            do {
                try await controller.pause()
                pausedForBackground = true
            } catch {
                // Saving a running machine works too.
            }
        }
        guard controller.state == .running || controller.state == .paused else { return }
        _ = try? await controller.saveState(to: autosaveURL)
        if !inBackground { await resumeAfterBackground() }
    }

    func enterForeground() async {
        inBackground = false
        await resumeAfterBackground()
    }

    private func resumeAfterBackground() async {
        guard pausedForBackground else { return }
        await waitWhileSaving(seconds: 30)
        guard !inBackground, pausedForBackground else { return }
        pausedForBackground = false
        if controller.state == .paused { try? await controller.resume() }
    }

    private var autosaveURL: URL { controller.store.autosaveStateURL(controller.spec.id) }

    /// Waits for a save in progress (the autosave timer's) to finish.
    private func waitWhileSaving(seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        while controller.state == .saving, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: Console and surface

    func consoleOutput() -> AsyncStream<Data> { controller.console.output(replay: true) }

    func writeConsole(_ data: Data) { controller.console.write(data) }

    func makeSurface() -> any ComputerSurface { controller.makeSurface() }

    nonisolated static func map(_ state: EmuRunState) -> MachineRunState {
        switch state {
        case .stopped: return .stopped
        case .starting: return .starting
        case .running: return .running
        case .paused: return .paused
        case .saving: return .saving
        case .error(let message): return .error(message)
        }
    }
}
#endif
