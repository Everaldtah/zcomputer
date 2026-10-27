import Foundation
import Virtualization
import XCTest
import ZCore
@testable import ZVM

/// Tests that touch Virtualization.framework objects. Building or validating a configuration needs the
/// `com.apple.security.virtualization` entitlement (a plain `swift test` binary lacks it) and hardware support
/// (GitHub's arm64 runners have no nested virtualization), so those parts skip instead of failing.
final class VirtualizationTests: XCTestCase {
    @MainActor
    func testIdentityFilesArePersisted() throws {
        let dir = try makeTemporaryDirectory("zvm-identity")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = VMBundle(root: dir)

        let mac1 = try VMIdentity.macAddress(bundle: bundle)
        let mac2 = try VMIdentity.macAddress(bundle: bundle)
        XCTAssertEqual(mac1.string, mac2.string)
        XCTAssertTrue(mac1.isLocallyAdministeredAddress)

        let id1 = try VMIdentity.genericMachineIdentifier(bundle: bundle)
        let id2 = try VMIdentity.genericMachineIdentifier(bundle: bundle)
        XCTAssertEqual(id1.dataRepresentation, id2.dataRepresentation)
    }

    @MainActor
    func testLinuxConfigurationValidates() throws {
        guard VZVirtualMachine.isSupported else {
            throw XCTSkip("Virtualization is not supported on this machine (e.g. a GitHub arm64 runner)")
        }
        let root = try makeTemporaryDirectory("zvm-config")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VMStore(root: root)
        var spec = VMSpec(name: "config", diskBytes: 1 << 30)
        spec.sharedFolders = [SharedFolder(hostURL: root, tag: "work", readOnly: true)]
        let bundle = try store.create(spec)
        try CloudInitSeed.write(CloudInitConfig(password: "pw"), to: bundle.seedImageURL)
        let configuration: VZVirtualMachineConfiguration
        do {
            configuration = try VMConfigurationBuilder.makeLinuxConfiguration(
                spec: spec, bundle: bundle, console: SerialConsole(), guestAgentDirectory: root, includeUSBController: true)
        } catch {
            throw XCTSkip("configuration needs the virtualization entitlement here: \(error)")
        }
        XCTAssertEqual(configuration.storageDevices.count, 2)              // disk + seed
        XCTAssertEqual(configuration.directorySharingDevices.count, 2)     // work + zguest
        XCTAssertEqual(configuration.socketDevices.count, 1)
        XCTAssertEqual(configuration.serialPorts.count, 1)
        XCTAssertTrue(configuration.bootLoader is VZEFIBootLoader)
    }

    @MainActor
    func testControllerStartsStopped() throws {
        let root = try makeTemporaryDirectory("zvm-controller")
        defer { try? FileManager.default.removeItem(at: root) }
        let spec = VMSpec(name: "ctl", diskBytes: 1 << 20)
        let controller = VMController(spec: spec, bundle: VMStore(root: root).bundle(for: spec.id))
        XCTAssertEqual(controller.state, .stopped)
        XCTAssertNil(controller.virtualMachine)
        XCTAssertEqual(controller.displayHost.displayPixels, PixelSize(width: 1280, height: 800))
        XCTAssertThrowsError(try controller.requestStop())
    }

    func testRunStateDescriptions() {
        XCTAssertEqual(VMRunState.running.description, "running")
        XCTAssertEqual(VMRunState.error("boom").description, "error: boom")
        XCTAssertTrue(VMRunState.paused.isActive)
        XCTAssertFalse(VMRunState.stopped.isActive)
        XCTAssertFalse(VMRunState.error("x").isActive)
    }
}
