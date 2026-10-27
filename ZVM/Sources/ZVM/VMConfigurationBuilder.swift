import Foundation
@preconcurrency import Virtualization
import ZCore

/// Persistent identity of a VM bundle (created on first use, reused afterwards).
@MainActor
public enum VMIdentity {
    /// `machine-id` for Linux guests (`VZGenericMachineIdentifier`).
    public static func genericMachineIdentifier(bundle: VMBundle) throws -> VZGenericMachineIdentifier {
        let url = bundle.machineIdentifierURL
        if let data = try? Data(contentsOf: url) {
            guard let id = VZGenericMachineIdentifier(dataRepresentation: data) else {
                throw ZError.vm("corrupt machine-id in \(bundle.root.lastPathComponent)")
            }
            return id
        }
        let id = VZGenericMachineIdentifier()
        try id.dataRepresentation.write(to: url, options: .atomic)
        return id
    }

    /// `efi-vars` (NVRAM) for Linux guests; the installed system's boot entry lives here.
    public static func efiVariableStore(bundle: VMBundle) throws -> VZEFIVariableStore {
        let url = bundle.efiVariablesURL
        if FileManager.default.fileExists(atPath: url.path) { return VZEFIVariableStore(url: url) }
        return try VZEFIVariableStore(creatingVariableStoreAt: url, options: [])
    }

    /// `mac-address`: a stable locally administered MAC so the NAT DHCP lease (and the guest IP) stays the same.
    public static func macAddress(bundle: VMBundle) throws -> VZMACAddress {
        let url = bundle.macAddressURL
        if let text = try? String(contentsOf: url, encoding: .utf8),
           let mac = VZMACAddress(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return mac
        }
        let mac = VZMACAddress.randomLocallyAdministered()
        try mac.string.write(to: url, atomically: true, encoding: .utf8)
        return mac
    }
}

/// Builds `VZVirtualMachineConfiguration`s following docs/research/virtualization.md (brief (b) and (c)).
@MainActor
public enum VMConfigurationBuilder {
    /// The virtio-fs tag of the Rosetta share (guest: `mount -t virtiofs rosetta /media/rosetta`).
    public static let rosettaTag = "rosetta"

    /// - Parameters:
    ///   - guestAgentDirectory: folder with the `zguest` binaries, shared read-only under the tag `zguest`.
    ///   - includeUSBController: add an XHCI controller (macOS 15, enables USB hot-plug). Combined with the USB
    ///     mass-storage ISO this is UNVERIFIED; `VMController` retries without it if validation fails.
    public static func makeConfiguration(spec: VMSpec, bundle: VMBundle, console: SerialConsole,
                                         guestAgentDirectory: URL?, includeUSBController: Bool = true) throws -> VZVirtualMachineConfiguration {
        switch spec.guest {
        case .linux:
            return try makeLinuxConfiguration(spec: spec, bundle: bundle, console: console,
                                              guestAgentDirectory: guestAgentDirectory, includeUSBController: includeUSBController)
        case .macOS:
            #if arch(arm64)
            return try makeMacOSConfiguration(spec: spec, bundle: bundle, console: console)
            #else
            throw ZError.unsupported("macOS guests need a Mac with Apple silicon")
            #endif
        }
    }

    // MARK: Linux

    public static func makeLinuxConfiguration(spec: VMSpec, bundle: VMBundle, console: SerialConsole,
                                              guestAgentDirectory: URL?, includeUSBController: Bool) throws -> VZVirtualMachineConfiguration {
        let c = VZVirtualMachineConfiguration()
        applyResources(c, spec: spec)

        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = try VMIdentity.genericMachineIdentifier(bundle: bundle)
        if spec.nestedVirtualization && VZGenericPlatformConfiguration.isNestedVirtualizationSupported {
            platform.isNestedVirtualizationEnabled = true      // macOS 15, M3 or later
        }
        c.platform = platform

        let boot = VZEFIBootLoader()
        boot.variableStore = try VMIdentity.efiVariableStore(bundle: bundle)
        c.bootLoader = boot

        // Storage: main disk, installer ISO as a read-only USB stick while installing, cloud-init seed.
        let disk = try mainDisk(bundle: bundle)
        let network = try natNetwork(bundle: bundle)
        var storage: [VZStorageDeviceConfiguration] = [disk]
        if spec.attachInstallMedia, case .iso(let iso) = spec.install {
            let attachment = try VZDiskImageStorageDeviceAttachment(url: iso, readOnly: true)
            storage.append(VZUSBMassStorageDeviceConfiguration(attachment: attachment))
        }
        if FileManager.default.fileExists(atPath: bundle.seedImageURL.path) {
            let seed = try VZDiskImageStorageDeviceAttachment(url: bundle.seedImageURL, readOnly: true)
            storage.append(VZVirtioBlockDeviceConfiguration(attachment: seed))
        }
        c.storageDevices = storage
        if includeUSBController {
            c.usbControllers = [VZXHCIControllerConfiguration()]
        }

        c.networkDevices = [network]

        let gpu = VZVirtioGraphicsDeviceConfiguration()
        gpu.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: spec.display.width, heightInPixels: spec.display.height)]
        c.graphicsDevices = [gpu]
        c.keyboards = [VZUSBKeyboardConfiguration()]
        c.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        applyCommonDevices(c, spec: spec, console: console)

        var shares: [VZDirectorySharingDeviceConfiguration] = []
        for folder in spec.sharedFolders {
            try VZVirtioFileSystemDeviceConfiguration.validateTag(folder.tag)
            let fs = VZVirtioFileSystemDeviceConfiguration(tag: folder.tag)
            fs.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: folder.hostURL, readOnly: folder.readOnly))
            shares.append(fs)
        }
        if let agentDirectory = guestAgentDirectory {
            let fs = VZVirtioFileSystemDeviceConfiguration(tag: GuestAgentInstall.shareTag)
            fs.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: agentDirectory, readOnly: true))
            shares.append(fs)
        }
        #if arch(arm64)
        if spec.rosetta, VZLinuxRosettaDirectoryShare.availability == .installed {
            let fs = VZVirtioFileSystemDeviceConfiguration(tag: rosettaTag)
            fs.share = try VZLinuxRosettaDirectoryShare()
            shares.append(fs)
        }
        #endif
        c.directorySharingDevices = shares

        try c.validate()
        return c
    }

    // MARK: macOS (Apple silicon)

    #if arch(arm64)
    /// Rebuilds the platform from the bundle's `hardware-model`, `machine-id` and `aux` (see `MacOSInstaller`).
    public static func macPlatform(bundle: VMBundle) throws -> VZMacPlatformConfiguration {
        guard let modelData = try? Data(contentsOf: bundle.hardwareModelURL),
              let model = VZMacHardwareModel(dataRepresentation: modelData) else {
            throw ZError.vm("this macOS VM has no hardware model yet; install macOS first")
        }
        guard model.isSupported else { throw ZError.unsupported("this Mac cannot run the VM's macOS hardware model") }
        guard let idData = try? Data(contentsOf: bundle.machineIdentifierURL),
              let machineID = VZMacMachineIdentifier(dataRepresentation: idData) else {
            throw ZError.vm("missing or corrupt machine-id")
        }
        guard FileManager.default.fileExists(atPath: bundle.auxiliaryStorageURL.path) else {
            throw ZError.vm("missing auxiliary storage (aux)")
        }
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = model
        platform.machineIdentifier = machineID
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: bundle.auxiliaryStorageURL)
        return platform
    }

    public static func makeMacOSConfiguration(spec: VMSpec, bundle: VMBundle, console: SerialConsole) throws -> VZVirtualMachineConfiguration {
        let c = VZVirtualMachineConfiguration()
        applyResources(c, spec: spec)
        c.platform = try macPlatform(bundle: bundle)
        c.bootLoader = VZMacOSBootLoader()

        let disk = try mainDisk(bundle: bundle)
        let network = try natNetwork(bundle: bundle)
        c.storageDevices = [disk]
        c.networkDevices = [network]

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: spec.display.width,
                                                               heightInPixels: spec.display.height,
                                                               pixelsPerInch: spec.display.ppi)]
        c.graphicsDevices = [graphics]
        c.keyboards = [VZMacKeyboardConfiguration()]
        // Trackpad for macOS 13+ guests, absolute USB pointer for older ones (Apple sets both).
        c.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]

        applyCommonDevices(c, spec: spec, console: console)

        // macOS guests automount one virtio-fs device under /Volumes/My Shared Files/<tag>.
        if !spec.sharedFolders.isEmpty {
            var directories: [String: VZSharedDirectory] = [:]
            for folder in spec.sharedFolders {
                directories[folder.tag] = VZSharedDirectory(url: folder.hostURL, readOnly: folder.readOnly)
            }
            let fs = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
            fs.share = VZMultipleDirectoryShare(directories: directories)
            c.directorySharingDevices = [fs]
        }

        try c.validate()
        return c
    }
    #endif

    // MARK: Shared pieces

    static func applyResources(_ c: VZVirtualMachineConfiguration, spec: VMSpec) {
        let minCPU = VZVirtualMachineConfiguration.minimumAllowedCPUCount
        let maxCPU = min(VZVirtualMachineConfiguration.maximumAllowedCPUCount, ProcessInfo.processInfo.activeProcessorCount)
        c.cpuCount = min(max(spec.cpuCount, minCPU), max(minCPU, maxCPU))
        let mib: UInt64 = 1 << 20
        let memory = min(max(spec.memoryBytes, VZVirtualMachineConfiguration.minimumAllowedMemorySize),
                         VZVirtualMachineConfiguration.maximumAllowedMemorySize)
        c.memorySize = memory / mib * mib
    }

    /// The RAW boot disk. Cached + fsync, as Lima does to avoid corruption on ARM (utmapp/UTM#4840).
    static func mainDisk(bundle: VMBundle) throws -> VZStorageDeviceConfiguration {
        guard FileManager.default.fileExists(atPath: bundle.diskURL.path) else {
            throw ZError.vm("disk.img is missing in \(bundle.root.lastPathComponent)")
        }
        let attachment = try VZDiskImageStorageDeviceAttachment(url: bundle.diskURL, readOnly: false,
                                                                cachingMode: .cached, synchronizationMode: .fsync)
        return VZVirtioBlockDeviceConfiguration(attachment: attachment)
    }

    /// NAT networking (no `com.apple.vm.networking` entitlement needed) with the persisted MAC.
    static func natNetwork(bundle: VMBundle) throws -> VZNetworkDeviceConfiguration {
        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = VZNATNetworkDeviceAttachment()
        net.macAddress = try VMIdentity.macAddress(bundle: bundle)
        return net
    }

    /// Sound, entropy, balloon, serial console, Spice clipboard and vsock.
    static func applyCommonDevices(_ c: VZVirtualMachineConfiguration, spec: VMSpec, console: SerialConsole) {
        if spec.audio {
            let sound = VZVirtioSoundDeviceConfiguration()
            let output = VZVirtioSoundDeviceOutputStreamConfiguration()
            output.sink = VZHostAudioOutputStreamSink()
            sound.streams = [output]
            c.audioDevices = [sound]
        }
        c.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        c.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        // Serial console (/dev/hvc0 in Linux) over pipes; the guest reads `fileHandleForReading`.
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: console.guestInputHandle,
                                                             fileHandleForWriting: console.guestOutputHandle)
        c.serialPorts = [serial]

        if spec.clipboardSharing {
            let consoleDevice = VZVirtioConsoleDeviceConfiguration()
            let port = VZVirtioConsolePortConfiguration()
            port.name = VZSpiceAgentPortAttachment.spiceAgentPortName
            let spice = VZSpiceAgentPortAttachment()
            spice.sharesClipboard = true
            port.attachment = spice
            consoleDevice.ports[0] = port
            c.consoleDevices = [consoleDevice]
        }

        c.socketDevices = [VZVirtioSocketDeviceConfiguration()]
    }
}
