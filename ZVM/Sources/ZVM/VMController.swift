import Darwin
import Foundation
@preconcurrency import Virtualization
import ZCore

/// Lifecycle state of a VM, published by `VMController.stateUpdates`.
public enum VMRunState: Sendable, Hashable, CustomStringConvertible {
    case stopped
    case starting
    case running
    case pausing
    case paused
    case resuming
    case stopping
    case error(String)

    public var description: String {
        switch self {
        case .stopped: return "stopped"
        case .starting: return "starting"
        case .running: return "running"
        case .pausing: return "pausing"
        case .paused: return "paused"
        case .resuming: return "resuming"
        case .stopping: return "stopping"
        case .error(let message): return "error: \(message)"
        }
    }

    /// True while the guest exists in memory (running, paused or transitioning).
    public var isActive: Bool {
        switch self {
        case .stopped, .error: return false
        default: return true
        }
    }
}

/// Owns one VM: builds the `VZVirtualMachine` (on the main queue, as `VZVirtualMachineView` requires), runs it,
/// and exposes the serial console, the guest agent, the display host (hidden agent view + user views) and a
/// `ComputerSurface` for agents.
@MainActor
public final class VMController: NSObject {
    public private(set) var spec: VMSpec
    public let bundle: VMBundle
    /// Folder with the `zguest` binaries, shared read-only into Linux guests under the tag `zguest`.
    public let guestAgentDirectory: URL?
    /// The guest's serial console (hvc0); bind a terminal view to `console.output(replay:)` / `console.write(_:)`.
    public let console: SerialConsole
    public let serialShell: SerialShell
    public let displayHost: VMDisplayHost
    /// The framework VM (nil until built). Bind UI views through `displayHost.makeUserView()`.
    public private(set) var virtualMachine: VZVirtualMachine?
    public private(set) var state: VMRunState = .stopped

    private let states = Broadcaster<VMRunState>(replaysLatest: true)
    private let access = SecurityScopedAccess()
    private var usesUSBController = true
    private var needsRebuild = false

    /// Client for the in-guest agent over vsock port 5555.
    public lazy var guestAgent: GuestAgentClient = GuestAgentClient(connector: makeAgentConnector())

    /// - Parameters:
    ///   - spec: the VM (load it with `VMStore.load(id:)` and `VMSpec.resolvingBookmarks()`).
    ///   - guestAgentDirectory: folder holding `zguest-linux-arm64` / `zguest-linux-amd64` (the app bundles them).
    public init(spec: VMSpec, bundle: VMBundle, guestAgentDirectory: URL? = nil) {
        let console = SerialConsole()
        self.spec = spec
        self.bundle = bundle
        self.guestAgentDirectory = guestAgentDirectory
        self.console = console
        self.serialShell = SerialShell(transport: console)
        self.displayHost = VMDisplayHost(displaySize: spec.display.pixelSize)
        super.init()
        states.yield(.stopped)
    }

    /// Loads a VM from the store, resolving its security-scoped bookmarks (and saving refreshed ones).
    public static func load(id: UUID, store: VMStore, guestAgentDirectory: URL? = nil) throws -> VMController {
        let stored = try store.load(id: id)
        let resolution = stored.resolvingBookmarks()
        if resolution.changed { try? store.save(resolution.spec) }
        return VMController(spec: resolution.spec, bundle: store.bundle(for: id), guestAgentDirectory: guestAgentDirectory)
    }

    /// True when this Mac can run VMs at all.
    public static var isSupported: Bool { VZVirtualMachine.isSupported }

    /// State changes (the current state is replayed to new subscribers).
    public var stateUpdates: AsyncStream<VMRunState> { states.stream() }

    /// Replaces the spec; takes effect at the next start (the VM must be stopped).
    public func update(spec newSpec: VMSpec) throws {
        guard !state.isActive else { throw ZError.vm("stop the VM before changing its configuration") }
        spec = newSpec
        needsRebuild = true
    }

    /// Stops attaching the installer ISO from the next start on (call after the guest is installed, then save `spec`).
    public func finishInstallation() throws {
        var s = spec
        s.attachInstallMedia = false
        try update(spec: s)
    }

    // MARK: Building

    /// Builds (or rebuilds after `update(spec:)`) the `VZVirtualMachine`. Validation errors are thrown here.
    @discardableResult
    public func buildVirtualMachine() throws -> VZVirtualMachine {
        if let vm = virtualMachine, !needsRebuild { return vm }
        guard !state.isActive else { throw ZError.vm("the VM is \(state); stop it before rebuilding") }
        let configuration: VZVirtualMachineConfiguration
        do {
            configuration = try makeConfiguration(includeUSBController: usesUSBController)
        } catch {
            // The explicit XHCI controller next to the USB mass-storage ISO is UNVERIFIED; retry without it once.
            guard usesUSBController, let fallback = try? makeConfiguration(includeUSBController: false) else { throw error }
            usesUSBController = false
            configuration = fallback
        }
        let vm = VZVirtualMachine(configuration: configuration)   // main queue
        vm.delegate = self
        virtualMachine = vm
        needsRebuild = false
        displayHost.attach(vm)
        return vm
    }

    private func makeConfiguration(includeUSBController: Bool) throws -> VZVirtualMachineConfiguration {
        try VMConfigurationBuilder.makeConfiguration(spec: spec, bundle: bundle, console: console,
                                                     guestAgentDirectory: guestAgentDirectory,
                                                     includeUSBController: includeUSBController)
    }

    // MARK: Lifecycle

    public func start() async throws {
        let vm = try buildVirtualMachine()
        guard vm.canStart else { throw ZError.vm("the VM cannot start while it is \(vm.state.name)") }
        for url in spec.securityScopedURLs { access.start(url) }
        if let dir = guestAgentDirectory { access.start(dir) }
        console.startReading()
        await serialShell.start()
        publish(.starting)
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                vm.start(completionHandler: VZCompletion.handler(cont))
            }
        } catch {
            access.stopAll()
            let message = Self.describe(error)
            publish(.error(message))
            throw ZError.vm("start failed: \(message)")
        }
        publish(.running)
        await guestAgent.resetReachability()
    }

    /// Forced stop (like pulling the power cord). Prefer `requestStop()` for a clean shutdown.
    public func stop() async throws {
        guard let vm = virtualMachine, vm.state != .stopped else { return }
        guard vm.canStop else { throw ZError.vm("the VM cannot be stopped while it is \(vm.state.name)") }
        publish(.stopping)
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                vm.stop(completionHandler: VZCompletion.handler(cont))
            }
        } catch {
            publish(Self.runState(vm.state))
            throw ZError.vm("stop failed: \(Self.describe(error))")
        }
        didStop(error: nil)
    }

    /// Asks the guest to shut down (ACPI power button). The state changes to `.stopped` when it has.
    public func requestStop() throws {
        guard let vm = virtualMachine, vm.canRequestStop else { throw ZError.vm("the VM cannot be asked to stop now") }
        try vm.requestStop()
    }

    public func pause() async throws {
        guard let vm = virtualMachine, vm.canPause else { throw ZError.vm("the VM cannot be paused now") }
        publish(.pausing)
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                vm.pause(completionHandler: VZCompletion.handler(cont))
            }
        } catch {
            publish(Self.runState(vm.state))
            throw ZError.vm("pause failed: \(Self.describe(error))")
        }
        publish(.paused)
    }

    public func resume() async throws {
        guard let vm = virtualMachine, vm.canResume else { throw ZError.vm("the VM cannot be resumed now") }
        publish(.resuming)
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                vm.resume(completionHandler: VZCompletion.handler(cont))
            }
        } catch {
            publish(Self.runState(vm.state))
            throw ZError.vm("resume failed: \(Self.describe(error))")
        }
        publish(.running)
    }

    /// Re-reads the framework's state (e.g. after a delegate callback was missed).
    public func refreshState() {
        guard let vm = virtualMachine else { return }
        publish(Self.runState(vm.state))
    }

    private func publish(_ newState: VMRunState) {
        state = newState
        states.yield(newState)
    }

    private func didStop(error: (any Error)?) {
        access.stopAll()
        if let error {
            publish(.error(Self.describe(error)))
        } else {
            publish(.stopped)
        }
        let agent = guestAgent
        Task { await agent.closeAll() }
    }

    static func runState(_ s: VZVirtualMachine.State) -> VMRunState {
        switch s {
        case .stopped: return .stopped
        case .running: return .running
        case .paused: return .paused
        case .error: return .error("the virtual machine reported an error")
        case .starting, .restoring: return .starting
        case .pausing, .saving: return .pausing
        case .resuming: return .resuming
        case .stopping: return .stopping
        @unknown default: return .error("unknown state")
        }
    }

    /// Error text with the domain/code, plus a hint for the macOS 2-instance licence limit.
    static func describe(_ error: any Error) -> String {
        let ns = error as NSError
        if ns.domain == VZError.errorDomain && ns.code == 6 {   // VZError.Code.virtualMachineLimitExceeded
            return "macOS allows only 2 macOS virtual machines to run at the same time on one Mac (\(ns.localizedDescription))"
        }
        return "\(ns.localizedDescription) (\(ns.domain) \(ns.code))"
    }

    // MARK: Guest agent

    /// Opens a vsock connection to the guest agent. `connect(toPort:)` may never call back when nothing listens,
    /// so it races a timeout. The descriptor is duplicated so our `FileDescriptorConnection` owns its own fd.
    public func connectGuestAgent(port: UInt32 = GuestAgentClient.port, timeout: TimeInterval = 3) async throws -> any GuestAgentConnection {
        guard let vm = virtualMachine, vm.state == .running else {
            throw GuestAgentError(code: .transport, message: "the VM is not running")
        }
        guard let device = vm.socketDevices.first as? VZVirtioSocketDevice else {
            throw GuestAgentError(code: .transport, message: "the VM has no vsock device")
        }
        let once = OneShot()
        let opened: OpenedVsock = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<OpenedVsock, any Error>) in
            device.connect(toPort: port, completionHandler: VsockCompletion.handler(cont, once: once))
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                guard once.fire() else { return }
                cont.resume(throwing: GuestAgentError(code: .transport,
                                                      message: "the guest agent is not listening on vsock port \(port)"))
            }
        }
        let box = opened.box
        return FileDescriptorConnection(fileDescriptor: opened.fileDescriptor, onClose: { box.closeOnMain() })
    }

    private func makeAgentConnector() -> GuestAgentConnector {
        { [weak self] in
            guard let self else { throw GuestAgentError(code: .transport, message: "the VM controller is gone") }
            return try await self.connectGuestAgent()
        }
    }

    /// Installs `zguest` through the serial console (fresh Linux guests). Needs `guestAgentDirectory`.
    @discardableResult
    public func provisionGuestAgent(user: String, password: String?, binaryName: String? = nil) async throws -> ShellResult {
        guard let dir = guestAgentDirectory else {
            throw ZError.invalidArgument("no guest agent directory was given to the VM controller")
        }
        let name = binaryName ?? "zguest-linux-\(GuestArchitecture.host.debianName)"
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) else {
            throw ZError.notFound("\(name) in \(dir.path)")
        }
        let provisioner = AutoProvisioner(user: user, password: password, binaryName: name)
        let result = try await provisioner.provision(shell: serialShell)
        await guestAgent.resetReachability()
        return result
    }

    // MARK: Surface

    /// A `ComputerSurface` over this VM for agents. `credentials` enable the serial-console shell fallback.
    public func makeSurface(credentials: VMSurface.Credentials? = nil) -> VMSurface {
        VMSurface(controller: self, agent: guestAgent, serial: serialShell, name: spec.name, guest: spec.guest,
                  credentials: credentials)
    }

    // MARK: macOS installation support

    /// Builds the VM for `VZMacOSInstaller` (the VM must be stopped).
    public func virtualMachineForInstallation() throws -> VZVirtualMachine {
        guard !state.isActive else { throw ZError.vm("stop the VM before installing") }
        return try buildVirtualMachine()
    }

    func noteInstallation(running: Bool) {
        publish(running ? .starting : .stopped)
    }
}

extension VMController: @preconcurrency VZVirtualMachineDelegate {
    public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        didStop(error: nil)
    }

    public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        didStop(error: error)
    }
}
