# Z Computer — Virtualization.framework research brief (ZVM)

Date: 2026-10-27. Scope: Mac App Store (sandboxed) SwiftUI app, deployment target macOS 15, built on GitHub Actions.

**Legend.** Every claim cites a source. Anything marked **UNVERIFIED** was not confirmed from a primary
source or a working implementation and must be tested on real hardware before the code relies on it.
Availability versions come from the `availability` metadata in Apple's documentation (`developer.apple.com/documentation/<path>.md`),
fetched 2026-10-27.

---

## TL;DR: what constrains the design

1. **There is no public framebuffer or input API.** As of the macOS 27 SDK, `VZGraphicsDisplay` exposes only `sizeInPixels`,
   observers and `reconfigure(...)`. `VZVirtualMachineView` exposes only `virtualMachine`, `adaptor` (27), `capturesSystemKeys` and
   `automaticallyReconfiguresDisplay`. To let an agent see and drive the VM, the app must capture a `VZVirtualMachineView`
   it hosts (`cacheDisplay(in:to:)`, or the view's internal IOSurface) and inject synthetic `NSEvent`s into that view. Third
   parties ship or verify this approach (UTM, zyvor-fluxvm on macOS 27.2, vzautomation), but Apple doesn't document or
   guarantee it. The alternatives other tools use are **private** (`_VZVNCServer` in Tart and lume, `-[VZGraphicsDisplay _takeScreenshotWithCompletionHandler:]`
   in VirtualBuddy) and would get the app rejected under App Review guideline 2.5.1. `CGWindowListCreateImage` is **obsoleted at macOS 15**, so it can't
   be called with our deployment target.
2. **The guest CPU architecture must match the host.** On Apple silicon only **arm64, UEFI-bootable** Linux ISOs work. Apple says
   "The Virtualization framework doesn't support the bootstrapping or installation of Intel Linux distributions on Mac
   computers with Apple silicon". x86_64 *binaries* can run inside arm64 Linux through Rosetta or the binary translation built into macOS 27.
   **Windows isn't supported** (Apple engineer, forum 784051). **macOS guests** need Apple silicon, and at most **2 can run
   concurrently** (`VZError.Code.virtualMachineLimitExceeded`).
3. **Sandbox and App Store.** Required: `com.apple.security.app-sandbox`, `com.apple.security.virtualization`, `network.client`, and user-selected
   files plus bookmarks. NAT needs **no** extra entitlement. Bridged networking needs the **restricted** `com.apple.vm.networking`, which only
   Apple can grant, so leave it out. GitHub's **arm64 runners can't start VMs** (no nested virtualization). The **Intel
   runners (`macos-15-intel`) can**: Colima's CI boots VZ VMs on them. So: unit tests use mocks, with an optional smoke test on Intel.

---

## 0. Feature / OS availability matrix (verified from Apple doc metadata)

| Feature | API | macOS |
|---|---|---|
| Core VM, virtio block/net/entropy/balloon/vsock/serial | `VZVirtualMachine`, `VZVirtioBlockDeviceConfiguration`, `VZVirtioSocketDeviceConfiguration`, `VZVirtioConsoleDeviceSerialPortConfiguration`, `VZFileHandleSerialPortAttachment` | 11 |
| Direct kernel boot | `VZLinuxBootLoader` (only with `VZGenericPlatformConfiguration`) | 11 |
| NAT networking | `VZNATNetworkDeviceAttachment` | 11 |
| Generic platform | `VZGenericPlatformConfiguration` | 12 |
| macOS guest (Apple silicon) | `VZMacOSBootLoader`, `VZMacPlatformConfiguration`, `VZMacHardwareModel`, `VZMacAuxiliaryStorage`, `VZMacOSRestoreImage`, `VZMacOSInstaller`, `VZMacGraphicsDeviceConfiguration` | 12 |
| Sound, USB keyboard, absolute USB pointer, view | `VZVirtioSoundDeviceConfiguration`, `VZUSBKeyboardConfiguration`, `VZUSBScreenCoordinatePointingDeviceConfiguration`, `VZVirtualMachineView` | 12 |
| virtio-fs | `VZVirtioFileSystemDeviceConfiguration`, `VZSharedDirectory`, `VZSingleDirectoryShare`, `VZMultipleDirectoryShare` | 12 |
| **EFI boot (any UEFI ISO)** | `VZEFIBootLoader`, `VZEFIVariableStore`, `VZGenericMachineIdentifier` | **13** |
| **USB mass storage (ISO as USB stick)** | `VZUSBMassStorageDeviceConfiguration` | **13** |
| **virtio-gpu for Linux** | `VZVirtioGraphicsDeviceConfiguration`, `VZVirtioGraphicsScanoutConfiguration` | **13** |
| **Rosetta for Linux** | `VZLinuxRosettaDirectoryShare` | **13** (Apple silicon only) |
| Mac trackpad, Spice clipboard, multiport console | `VZMacTrackpadConfiguration`, `VZSpiceAgentPortAttachment`, `VZVirtioConsoleDeviceConfiguration`, `VZVirtioConsolePortConfiguration` | 13 |
| `start(options:)` (recovery boot) | `VZMacOSVirtualMachineStartOptions.startUpFromMacOSRecovery` | 13 |
| Display resize, save/restore, NVMe, NBD, raw block device, Mac keyboard | `automaticallyReconfiguresDisplay`, `VZGraphicsDisplay.reconfigure(sizeInPixels:)`, `saveMachineStateTo(url:completionHandler:)`, `validateSaveRestoreSupport()`, `VZNVMExpressControllerDeviceConfiguration`, `VZNetworkBlockDeviceStorageDeviceAttachment`, `VZDiskBlockDeviceStorageDeviceAttachment`, `VZMacKeyboardConfiguration` | 14 |
| Rosetta AOT cache options | `VZLinuxRosettaDirectoryShare.CachingOptions` | 14 |
| **Nested virtualization** | `VZGenericPlatformConfiguration.isNestedVirtualizationSupported` / `.isNestedVirtualizationEnabled` (requires **M3 or later**) | **15** |
| USB hot-plug | `VZXHCIControllerConfiguration`, `VZUSBController.attach(device:)/detach(device:)`, `VZUSBMassStorageDevice` | 15 |
| iCloud in macOS guests | (identity derived from host Secure Enclave, for VMs created on 15 from a 15 IPSW) | 15 |
| vmnet custom topologies | `VZVmnetNetworkDeviceAttachment(network:)` | 26 |
| ASIF sparse disk format | `diskutil image create blank --format ASIF` (documented on `VZDiskImageStorageDeviceAttachment`) | 26 (UNVERIFIED exact version) |
| Swift 6 view wrapper | `VZVirtualMachineViewAdaptor` / `VZVirtualMachineView.adaptor` | 27 |
| macOS guest auto-provisioning | `VZMacGuestProvisioningOptions`, `VZMacOSVirtualMachineStartOptions.setGuestProvisioning(_:)` (guest must be macOS 27+) | 27 |
| Custom virtio devices | `VZCustomVirtioDeviceConfiguration`, `VZVirtualMachineConfiguration.customVirtioDevices` | 27 |
| USB passthrough | `VZUSBPassthroughDeviceConfiguration(device: AAUSBAccessory)` (+ AccessoryAccess framework) | 27 |
| Stacked / copy-on-write disks | `VZDiskImageStorageDeviceAttachment(diskImage:cachingMode:synchronizationMode:)` + DiskImageKit | 27 |
| EFI Secure Boot for Linux | `VZEFIVariableStore.enableSecureBootUsingDefaultPlatformKey()`, `enrollDefaultSecureBootSignatures()` | 27 |
| Intel binary translation built into the OS | `VZLinuxRosettaDirectoryShare.availability` always `.installed` on 27 | 27 |

Host facts: macOS 26 Tahoe is the **last macOS for Intel Macs**. macOS 27 runs on Apple silicon only (Apple, WWDC25; e.g.
https://petapixel.com/2025/06/10/macos-26-tahoe-is-the-end-of-the-road-for-intel-macs/). With a macOS 15 deployment target,
everything up to the 15 row is usable without `#available` checks. The 26 and 27 rows need `if #available` checks **and** a build
with the right SDK (see §6).

---

## 1. Mac App Store eligibility and entitlements

**Can a sandboxed MAS app use Virtualization.framework?** Yes.
* Apple's guide "Adding the Virtualization Entitlement to Your Project" says to turn on App Sandbox and add
  `com.apple.security.virtualization = YES`.
  https://developer.apple.com/documentation/virtualization/adding-the-virtualization-entitlement-to-your-project
* `VZVirtualMachineConfiguration.validate()` fails ("A configuration object is invalid if your app doesn't have the
  com.apple.security.virtualization entitlement").
  https://developer.apple.com/documentation/virtualization/vzvirtualmachineconfiguration
* Shipping sandboxed Mac App Store apps that use the framework:
  * **virtualOS** (open source, https://github.com/yep/virtualOS, App Store https://apps.apple.com/us/app/virtualos/id1614659226):
    `ENABLE_APP_SANDBOX = YES`, deployment target 15.0. Its entitlements file contains `com.apple.security.virtualization`,
    `com.apple.vm.networking`, `com.apple.security.device.usb`, `com.apple.developer.accessory-access.usb` and
    `com.apple.security.device.audio-input`. Whether its App Store build is actually provisioned for `com.apple.vm.networking` is
    UNVERIFIED.
  * **UTM** (Mac App Store edition). The UTM docs say "The Mac App Store version is identical to the GitHub version"
    (https://docs.getutm.app/installation/macos/). UTM's `Platform/macOS/macOS.entitlements` has app-sandbox, virtualization,
    network client and server, user-selected read-write, audio-input, usb, `com.apple.vm.networking` and `com.apple.vm.device-access`.
    Its QEMU helpers are sandboxed with `com.apple.security.hypervisor` and `com.apple.security.cs.allow-jit`.
  * **VirtualProg** (https://apps.apple.com/us/app/virtualprog-virtual-machine/id6744131218), **VirtuOS** and **VMTek**
    (id6444082385) are App Store listings for Linux and macOS VM managers (from listing text; their use of VZ is UNVERIFIED).

**Entitlement table**

| Entitlement | Needed? | Restricted? | Evidence |
|---|---|---|---|
| `com.apple.security.app-sandbox` | yes (MAS requires it, guideline 2.4.5(i)) | no | App Review Guidelines |
| `com.apple.security.virtualization` | **yes** | **no**. Lima signs it **ad hoc** (`codesign -f -v --entitlements vz.entitlements -s -`), so no provisioning profile is needed. The App Store Connect API (v4.5.1 spec) `CapabilityType` enum has **no** virtualization capability, so there is nothing to enable on the portal. | lima `Makefile`, `vz.entitlements`. ASC OpenAPI 4.5.1 `CapabilityType` = ICLOUD … APPLE_ID_AUTH (28 values, none VM related). |
| `com.apple.vm.networking` | **no** (only for `VZBridgedNetworkDeviceAttachment` and vmnet) | **yes**: "This entitlement is restricted to developers of virtualization software. To request this entitlement, contact your Apple representative." If you include it without that grant, the configuration (for bridged) or the signature/profile is invalid. | https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.vm.networking, https://developer.apple.com/documentation/virtualization/vzbridgednetworkdeviceattachment |
| NAT | `VZNATNetworkDeviceAttachment`: "This attachment doesn't require your app to have the com.apple.vm.networking entitlement." | — | https://developer.apple.com/documentation/virtualization/vznatnetworkdeviceattachment |
| `com.apple.security.network.client` | yes for us (LLM APIs, Ollama on localhost, image downloads, SSH to the guest). Whether NAT *itself* needs it inside the sandbox is UNVERIFIED. Apple's (unsandboxed) GUI Linux sample has only the virtualization key. | no | sample entitlements (via github.com/cicorias/GUILinuxVirtualMachineSampleApp) |
| `com.apple.security.network.server` | only if the app listens on a socket (local REST/MCP). vsock and virtio-fs don't need it. | no | — |
| `com.apple.security.files.user-selected.read-write` + `com.apple.security.files.bookmarks.app-scope` | yes (ISOs, shared folders, persistent access) | no | — |
| `com.apple.security.device.audio-input` | only if the guest gets a microphone stream (`VZVirtioSoundDeviceInputStreamConfiguration` + `VZHostAudioInputStreamSource`). Also needs `NSMicrophoneUsageDescription`. | no | Apple macOS VM sample "includes entitlements to … access the VM's audio input" |
| `com.apple.security.hypervisor` | not for VZ. Allowed in the sandbox (UTM's sandboxed QEMU helpers use it). Needed only if we ever embed QEMU+HVF. | no (since macOS 11; `com.apple.vm.hypervisor` is the pre-11 key) | https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.hypervisor |
| `com.apple.developer.accessory-access.usb` ("Claim USB Accessory") | only for macOS 27 USB passthrough | portal capability (`com.apple.developer.*`). How it maps to the ASC API is UNVERIFIED. | WWDC26 session 224; virtualOS and UTM entitlements |

**Review pitfalls found** (full list in (h) below):
* Private API. Tart and lume use `Dynamic._VZVNCServer` / `_VZVNCAuthenticationSecurityConfiguration`. VirtualBuddy declares
  `_VZGraphicsDisplay _takeScreenshotWithCompletionHandler:`, `_VZFramebuffer`, `_VZVirtualMachineStartOptions`. All of these
  violate 2.5.1 ("Apps may only use public APIs").
* Process model. A sandboxed app that spawns a VM-hosting child with `posix_spawn` or a double fork hits sandbox-inheritance crashes
  (`Failed to issue USB HCI sandbox extension`, `SYSCALL_SET_USERLAND_PROFILE`). DTS's answer: host the VM in-process, or use an **XPC service**
  (lives and dies with the app) or a **launchd agent**. https://developer.apple.com/forums/thread/786363
* Licensing for macOS guests: 2 concurrent instances (see §3).

---

## 2. Booting any Linux ISO

### 2.1 The recipe (from Apple's "Running GUI Linux in a virtual machine on a Mac", sample deployment target macOS 14)
https://developer.apple.com/documentation/virtualization/running-gui-linux-in-a-virtual-machine-on-a-mac

* Platform: `VZGenericPlatformConfiguration()` with `machineIdentifier = VZGenericMachineIdentifier()`. Persist
  `dataRepresentation`, restore with `VZGenericMachineIdentifier(dataRepresentation:)`.
* Boot: `VZEFIBootLoader()` with `variableStore = try VZEFIVariableStore(creatingVariableStoreAt: url, options: [])` on first install,
  then `VZEFIVariableStore(url:)` later. Options: `.allowOverwrite`.
* ISO: `try VZDiskImageStorageDeviceAttachment(url: iso, readOnly: true)` wrapped in `VZUSBMassStorageDeviceConfiguration(attachment:)`
  ("to emulate a USB thumb drive"). Add it only while installing. The sample drops it on later boots, and the installed system's
  EFI boot entry lives in the NVRAM file.
* Main disk: a RAW file attached with `VZDiskImageStorageDeviceAttachment(url:readOnly:false[, cachingMode:, synchronizationMode:])` inside
  `VZVirtioBlockDeviceConfiguration(attachment:)`. Create the file **sparse** with `open` + `ftruncate`. This is Apple's own snippet on the
  `VZDiskImageStorageDeviceAttachment` page. APFS allocates blocks only as they are written. Alternative: `diskutil image create blank --fs none
  --format RAW|ASIF --size 64GiB path` ("You can execute diskutil commands under app control"; running `diskutil` from inside the
  sandbox is UNVERIFIED, so prefer `ftruncate`). https://developer.apple.com/documentation/virtualization/vzdiskimagestoragedeviceattachment
* **Disk caching**: Lima hard-codes `VZDiskImageCachingMode.cached` + `VZDiskImageSynchronizationMode.fsync` "so as to avoid disk
  corruption on ARM" (it cites utmapp/UTM#4840). See `pkg/driver/vz/vm_darwin.go`. Do the same.
* Graphics: `VZVirtioGraphicsDeviceConfiguration()` with `scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels:heightInPixels:)]`.
  The guest needs the `virtio_gpu` driver, which is standard in distro kernels. On macOS 14+ set `view.automaticallyReconfiguresDisplay = true` on **one** view
  only (if several views target the same display, the framework honours only one of them).
* Input: `keyboards = [VZUSBKeyboardConfiguration()]`, `pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]` (absolute
  coordinates). `VZMacTrackpadConfiguration` is for **macOS 13+ guests only**. For mixed or older macOS guests Apple says to set both.
* Audio: `VZVirtioSoundDeviceConfiguration` with `streams = [VZVirtioSoundDeviceOutputStreamConfiguration (sink = VZHostAudioOutputStreamSink())]`,
  plus an input stream (`VZHostAudioInputStreamSource`) only if you have the mic entitlement.
* Entropy: `VZVirtioEntropyDeviceConfiguration()`. Balloon: `VZVirtioTraditionalMemoryBalloonDeviceConfiguration()` (only one). Set the size at runtime via
  `(vm.memoryBalloonDevices.first as? VZVirtioTraditionalMemoryBalloonDevice)?.targetVirtualMachineMemorySize`.
* Network: `VZVirtioNetworkDeviceConfiguration()` with `attachment = VZNATNetworkDeviceAttachment()`. Persist a `macAddress`
  (`VZMACAddress.randomLocallyAdministered()`) so the DHCP lease stays stable.
* Clipboard (optional): a `VZVirtioConsoleDeviceConfiguration` port named `VZSpiceAgentPortAttachment.spiceAgentPortName` with
  `VZSpiceAgentPortAttachment()` (`sharesClipboard = true`). The guest needs `spice-vdagent`. This also gives the agent a way to paste Unicode text.

### 2.2 virtio-fs shared folders
* Host: `VZVirtioFileSystemDeviceConfiguration(tag:)` (validate with `VZVirtioFileSystemDeviceConfiguration.validateTag(_:)`) and
  `share = VZSingleDirectoryShare(directory: VZSharedDirectory(url:readOnly:))` or `VZMultipleDirectoryShare(directories: [name: VZSharedDirectory])`.
* Guest (Linux): `mount -t virtiofs <tag> <mountpoint>`, or in fstab: `<tag> /mnt/zshare virtiofs rw,nofail 0 0`. Apple says the mount
  must be done by the user or by a script inside the guest. Our guest agent or serial provisioning does it.
  macOS guests: `mount_virtiofs tag dir`, or automount via `VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag`, which mounts under
  `/Volumes/My Shared Files`. https://developer.apple.com/documentation/virtualization/vzvirtiofilesystemdeviceconfiguration
* Sandbox: the shared folder must be user-selected (security-scoped bookmark). Keep `startAccessingSecurityScopedResource()` active
  for the whole VM lifetime (UNVERIFIED whether the framework's XPC process needs it after configuration; keeping it open is safe).

### 2.3 Serial console
* `VZVirtioConsoleDeviceSerialPortConfiguration()` with `attachment = VZFileHandleSerialPortAttachment(fileHandleForReading:fileHandleForWriting:)`.
  Apple's semantics: "To send data to the guest operating system, write data to the file handle in the fileHandleForReading property.
  To receive data from the guest, read data from the file handle in the fileHandleForWriting property."
  https://developer.apple.com/documentation/virtualization/vzfilehandleserialportattachment
* The guest sees it as `/dev/hvc0`. Installers print to `tty0` unless `console=hvc0` is on the kernel command line. The agent can add it by
  typing `e` in the GRUB menu and appending `console=hvc0` with keyboard injection. After install, systemd's getty generator "will also instantiate serial-getty@.service
  instances for virtualizer consoles if execution in a virtualized environment is detected", so a login prompt appears on hvc0 with
  no configuration. https://www.freedesktop.org/software/systemd/man/latest/systemd-getty-generator.html
* A pipe is not a PTY, so window size changes are not propagated. Send `stty rows R cols C` when at a prompt.
* Named ports (macOS 13): `VZVirtioConsoleDeviceConfiguration` with `ports[i] = VZVirtioConsolePortConfiguration` (`name`, `isConsole`,
  `attachment`). These appear as `/dev/vportNpM` and `/dev/virtio-ports/<name>` in Linux. They are an alternative control channel to vsock
  (the device-node naming is standard virtio-console behaviour, UNVERIFIED on VZ).

### 2.4 Rosetta (Apple silicon, Linux arm64 guest)
* `VZLinuxRosettaDirectoryShare.availability` returns `.notSupported`, `.notInstalled` or `.installed`. Call `installRosetta(completionHandler:)` if it is not installed. On macOS 27 it is
  always `.installed`, because "macOS 27 directly integrates support for Intel binary translation".
* `let fs = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta"); fs.share = try VZLinuxRosettaDirectoryShare()`.
* Guest: `mount -t virtiofs rosetta /media/rosetta`, then
  `update-binfmts --install rosetta /media/rosetta/rosetta --magic "\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00" --mask "\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff" --credentials yes --preserve yes --fix-binary yes`
  (use `--preserve no` on macOS 13). Dynamically linked binaries need x86_64 shared libraries in the guest.
  https://developer.apple.com/documentation/virtualization/running-intel-binaries-in-linux-vms

### 2.5 Intel vs Apple silicon: the "any ISO" limitation
* Apple: "The Linux ISO image you download must support the CPU architecture of your Mac. For a Mac with Apple silicon, download
  a Linux ISO image for ARM (`aarch64`/`arm64`) … For an Intel-based Mac … `x86_64`/`amd64`." Also: "The Virtualization framework
  doesn't support the bootstrapping or installation of Intel Linux distributions on Mac computers with Apple silicon."
* So "any Linux ISO" really means **any UEFI-bootable ISO of the host's architecture**. On Apple silicon (the only platform from macOS 27 on)
  that means arm64 ISOs: Debian, Fedora and Ubuntu are listed in Apple's sample. Not supported: x86_64 ISOs, 32-bit ARM, and BIOS-only ISOs (VZ has no legacy BIOS).
  The UI must check the ISO architecture before booting. Read the El Torito EFI image / `EFI/BOOT/BOOTAA64.EFI` vs `BOOTX64.EFI` (heuristic, UNVERIFIED for every distro).

### 2.6 Windows
* "Windows 11 isn't supported by Virtualization Framework in macOS Sequoia. Other virtual machine software based on Hypervisor
  Framework do support Windows 11." When asked about macOS 27 in May 2026, Apple wouldn't comment and tracks it as FB17582343. https://developer.apple.com/forums/thread/784051
  The macOS 27 docs still say "macOS and Linux".
* What's missing (UNVERIFIED details): VZ has no TPM device and no Windows virtio-gpu driver. Community reports of Windows ARM booting under
  `VZEFIBootLoader` don't amount to a usable desktop.
* What would be needed: QEMU (HVF for Windows 11 ARM64 on Apple silicon, TCG for x86). UTM proves this ships on the Mac App Store:
  sandboxed helpers with `com.apple.security.hypervisor` + `com.apple.security.cs.allow-jit`. So a **JIT-based** QEMU is App Store
  viable on macOS, and a no-JIT (TCI) build is not required. Costs: GPLv2 licensing, binary size, and maintenance. Microsoft's
  authorization list for Windows 11 on Apple silicon names Parallels and VMware (UNVERIFIED current wording). Windows is **out of scope for v1**.

---

## 3. macOS guests (Apple silicon only)

Flow (https://developer.apple.com/documentation/virtualization/running-macos-in-a-virtual-machine-on-apple-silicon, `VZMacOSInstaller` doc):
1. `let image = try await VZMacOSRestoreImage.latestSupported`. Its `url` is a network URL. Download it with `URLSession` into the container. A
   user-supplied `.ipsw` can be loaded with `try await VZMacOSRestoreImage.image(from: localURL)`.
2. `guard let req = image.mostFeaturefulSupportedConfiguration, req.hardwareModel.isSupported`. Use
   `req.minimumSupportedCPUCount` and `req.minimumSupportedMemorySize` as minimums.
3. Create a sparse RAW disk, `VZMacAuxiliaryStorage(creatingStorageAt:hardwareModel:options:)` and `VZMacMachineIdentifier()`. Persist
   `hardwareModel.dataRepresentation` and `machineIdentifier.dataRepresentation`. On every boot, restore all three (hardware model, machine ID,
   aux storage via `VZMacAuxiliaryStorage(url:)`). Each clone needs its own aux storage and machine identifier.
4. Configuration: `bootLoader = VZMacOSBootLoader()` (valid only with `VZMacPlatformConfiguration`), `platform = VZMacPlatformConfiguration`
   (`hardwareModel`, `auxiliaryStorage`, `machineIdentifier`), `VZMacGraphicsDeviceConfiguration` with
   `VZMacGraphicsDisplayConfiguration(widthInPixels:heightInPixels:pixelsPerInch:)`, `keyboards = [VZMacKeyboardConfiguration()]` (14+;
   else USB), `pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]`, plus virtio block, NAT,
   sound, entropy, balloon, vsock, and virtio-fs with `macOSGuestAutomountTag`.
5. `let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: localIPSW)`, then `try await installer.install()`. Observe
   `installer.progress.fractionCompleted`.
6. First boot. On a **macOS 27 host with a macOS 27+ guest**: `VZMacGuestProvisioningOptions` (`fullName`, `username`, `password`,
   `logsInAutomatically`, `enablesRemoteLogin`) with `VZMacOSVirtualMachineStartOptions.setGuestProvisioning(_:)` and `start(options:)`. This skips
   Setup Assistant and enables SSH. It only takes effect on the first boot after restore (WWDC26 session 224). Older guests: the agent clicks through Setup
   Assistant using screenshots and input.
7. Limits:
   * **2 concurrent macOS VMs** per host. Starting a third fails with `VZError.Code.virtualMachineLimitExceeded` (VZErrorDomain code 6). This follows from the macOS
     SLA allowance of "up to two (2) additional copies or instances … within virtual operating system environments" (wording quoted via
     https://eclecticlight.co/2022/08/04/virtualisation-on-apple-silicon-macs-8-how-apple-limits-vms/ and forum 729580. Read the current SLA
     text at apple.com/legal/sla, UNVERIFIED for macOS 27). Linux guests aren't limited.
   * iCloud sign-in works in VMs created on 15+ from 15+ IPSWs. Moving a VM to another Mac re-keys its identity. Running two clones of one VM at once
     makes the framework construct a new identity for the second. https://developer.apple.com/documentation/virtualization/using-icloud-with-macos-virtual-machines
   * The guest version must be one the host supports (`VZMacOSRestoreImage.isSupported`).

---

## 4. Agent control of the VM (screenshots and input)

### 4.1 Public API surface (the hard fact)
* `VZVirtualMachineView` (12): `virtualMachine`, `capturesSystemKeys` (default `false`), `automaticallyReconfiguresDisplay` (14),
  `adaptor: VZVirtualMachineViewAdaptor?` (27). There is **no** snapshot API.
* `VZGraphicsDisplay` (14): `sizeInPixels`, `addObserver(_:)`/`removeObserver(_:)` (`VZGraphicsDisplayObserver`),
  `reconfigure(sizeInPixels:)`, `reconfigure(configuration:)`. There is **no** framebuffer access.
* The macOS 27 additions (WWDC26 224: provisioning, USB passthrough, custom virtio, DiskImageKit, Secure Boot, view adaptor) also include no
  screenshot or input API. A custom virtio device would need our own guest kernel driver, so it can't help during installers.
* Multiple views may show the same VM. Apple documents this for `automaticallyReconfiguresDisplay` ("If multiple VZVirtualMachineView
  views targeting the same VZGraphicsDisplay enable this property, only one view respects it"). So a hidden agent view and the visible UI view can coexist.

### 4.2 What other projects do

| Project | Screenshot | Input | Public API only? |
|---|---|---|---|
| **UTM** (MAS) | `bitmapImageRepForCachingDisplay(in:)` + `cacheDisplay(in:to:)` on the Apple-backend display view (`Platform/macOS/Display/VMDisplayAppleWindowController.swift`, `NSView.image()`) | user only | yes |
| **Lima** (`limactl screenshot`, PR #5098, merged 2026-07-02) | `CGWindowListCreateImage(CGRectNull, kCGWindowListOptionIncludingWindow, wid, BoundsIgnoreFraming\|ShouldBeOpaque)` on its own visible VM window. Built with `-mmacosx-version-min=11`. "Headless VZ instances are not supported." | — | yes, but the function is obsoleted at 15 |
| **zyvor-fluxvm** (`runner/AgentScreen.swift`, PR #214 merged 2026-10-10, Apache-2.0; "Verified (macOS 27.2, M4, Debian 13 guest)", "no Screen Recording/Accessibility permission") | hidden borderless opaque window at (-20000,-20000), `orderFrontRegardless()`, holding a `VZVirtualMachineView`. Tries `CGWindowListCreateImage` first, then `cacheDisplay`. Retries while blank for up to 6 s after view creation. | synthetic `NSEvent`s: `view.keyDown/keyUp/flagsChanged` called directly. Mouse events via `window.sendEvent`. Right/middle click via `CGEvent(.otherMouseDown, button)` → `NSEvent(cgEvent:)` → `view.otherMouseDown`. Scroll via `CGEvent(scrollWheelEvent2Source:)` → `window.sendEvent`. Positions checked with evdev in the guest. | yes |
| **vzautomation** (thecrypticace) | reads `view.subviews.first?.layer?.contents as? IOSurface`, then `CIImage(ioSurface:)`. Also does Vision OCR and feature-print waits. | `view.keyDown(with:)`/`keyUp(with:)` with synthetic `NSEvent.keyEvent` | public calls, but depends on an **undocumented view hierarchy** |
| **VirtualBuddy** | private SPI `-[VZGraphicsDisplay _takeScreenshotWithCompletionHandler:]` (14+), and before that `_VZFramebuffer takeScreenshot…`. On macOS 26 the captured thumbnails showed a **"DRM Protected Video" black frame** (discussion #533; the author added `NSImage+DRMProtected.swift` to detect it). | user only | **no** |
| **Tart** / **lume (trycua)** | private `_VZVNCServer` + `_VZVNCAuthenticationSecurityConfiguration` via `Dynamic`. lume then reads the framebuffer and sends input over its own VNC client (`captureFramebuffer`, `sendMouseClick`, `sendKeyPress`). | via VNC | **no** |

### 4.3 Screenshot methods and what is known to produce black or blank images
1. **`cacheDisplay(in:to:)` on a VZVirtualMachineView that is in an ordered-in window.** UTM ships it. zyvor uses it as a fallback. Known blank cases:
   * The view is not in a window. A forum report says on macOS Tahoe `cacheDisplayInRect:` returns a blank image unless the view is in a window
     (thread 800739, from search snippet; that report was a plain NSButton).
   * A freshly created view, before the guest's first frame. zyvor: an idle text console "may take a few seconds", so it retries for 6 s.
   * zyvor: "Captures come out blank whenever the hidden view's backing store is exactly the guest display's size (seen after a guest
     reboot or stop/start)". They size the hidden window so that backing pixels are 2× (displays narrower than 1920) or ½× (1920 and wider) the
     guest pixels, then resample.
   * A transparent window "captures as transparent". Keep the window opaque.
   * The guest has blanked its own screen (DPMS or screensaver). The image really is black. Send a harmless key (Shift) first.
2. **IOSurface of the view's first sublayer** (vzautomation). This is the fastest path and gives the raw guest pixels. It relies on undocumented internal structure,
   so guard with `as? IOSurface` and fall back. Behaviour on macOS 26/27 is UNVERIFIED (the code dates from Aug 2024).
3. **ScreenCaptureKit** (`SCShareableContent` → `SCContentFilter(desktopIndependentWindow:)` → `SCScreenshotManager.captureImage(contentFilter:configuration:)`).
   It requires the **Screen Recording TCC permission**. DTS (forum 849969) names two consent paths: Screen Recording permission or `SCContentSharingPicker`.
   `SCShareableContent.currentProcess` / `getCurrentProcessShareableContent(completionHandler:)` (macOS 14.4+) exists. Whether it avoids the
   prompt for the app's own windows is UNVERIFIED. Off-screen windows may not be listed. Whether VZ content capture is DRM-protected is UNVERIFIED.
   Use it only as a diagnostic fallback.
4. **`CGWindowListCreateImage`**: "'CGWindowListCreateImage' is unavailable: obsoleted in macOS 15.0 – Please use ScreenCaptureKit
   instead". It **won't compile** with our macOS 15 target (MacPorts tickets 70756/71136). On macOS 27 beta 4+ it "compiles but returns a gray
   image" for other processes' windows (forum 849969). **Don't use it.**
5. **Private SPI** (`_takeScreenshot…`, `_VZFramebuffer`, `_VZVNCServer`). Rejected under 2.5.1, and on macOS 26 it produced DRM-protected black frames (VirtualBuddy). **Never use.**
6. **Guest-side capture** (guest agent): X11 `import -window root`/`scrot`/`xwd`; wlroots `grim`; KDE `spectacle -b -n -f -o`;
   **GNOME on Wayland only allows screenshots through xdg-desktop-portal, which prompts interactively** (UNVERIFIED for current GNOME). Not
   available during installers. Use it as a fallback, not as the primary method.

### 4.4 Input injection
* Inject **in-process**: build `NSEvent`s and hand them to the view (`view.keyDown/keyUp/flagsChanged`, `view.otherMouseDown/Up`) or to its window
  (`window.sendEvent` for left-button, move, drag and scroll). The view forwards events through the configured USB keyboard and absolute pointer. This needs
  **no Accessibility permission**, because nothing is posted to the system event stream (zyvor). `CGEvent.post(tap:)` would need Accessibility and
  would move the user's real cursor. Avoid it.
* Caveats verified by zyvor:
  * Modifiers must arrive as `flagsChanged` events whose flags include the **device-dependent bit** (NX_DEVICELCTLKEYMASK 0x01,
    NX_DEVICELSHIFTKEYMASK 0x02, NX_DEVICELCMDKEYMASK 0x08, NX_DEVICELALTKEYMASK 0x20). Otherwise the view ignores them.
  * AppKit's synthesized mouse events have button number 0. For right or middle clicks, create `CGEvent(mouseEventSource:mouseType:.otherMouseDown,
    mouseCursorPosition:mouseButton:.right/.center)`, convert with `NSEvent(cgEvent:)` and call `view.otherMouseDown(with:)`.
  * Scroll: `CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: -dy*12, wheel2: -dx*12, wheel3: 0)` → `window.sendEvent`.
* Other caveats:
  * Key codes are **physical (kVK_*)**, converted to USB HID by the framework. Typed characters therefore depend on the **guest keyboard layout** (assume US). For
    non-ASCII text use the guest agent (`xdotool type` on X11; `wtype` only on wlroots-style compositors that support virtual-keyboard; `ydotool`
    needs `/dev/uinput`, root and `ydotoold`) or the Spice clipboard followed by Ctrl+V.
  * Coordinates: view points with a bottom-left origin. Keep the view's aspect ratio equal to the guest display's, or letterboxing will skew the mapping (UNVERIFIED whether VZ letterboxes or stretches).
  * `capturesSystemKeys = true` only affects real user keystrokes such as Cmd-Tab.
  * Pace events about 4 ms apart (zyvor uses `usleep(4000)`). Whether very fast typing drops keys in some installers is UNVERIFIED.
  * If the user types into the visible view at the same time, the inputs interleave. Take the `SurfaceLease` and show an "agent is controlling" overlay.
  * Synthetic mouse into **macOS** guests (trackpad device): zyvor says both Linux and macOS are supported, but its evidence is Debian only, so UNVERIFIED.

### 4.5 In-guest remote display as an alternative (installer-specific)
* Fedora 42+ Anaconda replaced VNC with **RDP**: `inst.rdp inst.rdp.username=… inst.rdp.password=…` (`inst.vnc` was dropped).
  https://docs.fedoraproject.org/en-US/fedora-server/installation/interactive-remote/
* Ubuntu live-server (subiquity) exposes SSH to the installer with a temporary `installer` password printed on the console
  (Launchpad 1933523 shows that printing once regressed; current behaviour UNVERIFIED). Debian-installer has a `network-console` SSH component
  (exact boot parameters UNVERIFIED).
* Verdict: every distro does it differently, and it needs NAT reachability plus the guest IP. The host-side view capture with input injection is universal. Keep remote display as an optional extra.

### 4.6 Structured route: guest agent over vsock
See implementation brief (f). The agent provides exec, files, sysinfo (reports the IP for SSH, because the sandbox can't read `/var/db/dhcpd_leases`),
and optionally screenshot and input inside graphical sessions.

### 4.7 Recommended layered design (`VMSurface: ComputerSurface`)
1. **Display (always available, including firmware, GRUB and installers):** a hidden agent `VZVirtualMachineView` in an off-screen ordered-in window.
   Capture with IOSurface → `cacheDisplay` → blank check → retry, then scale to guest pixels. Inject input as synthetic NSEvents into that view.
2. **Shell and files (when available):** the guest agent on vsock port 5555. Fallback: `SerialShell` on hvc0 (type the command, then read until a sentinel).
3. **Unicode text:** agent `xdotool/wtype` if present, else Spice clipboard + paste, else per-key injection (US layout).
4. **Fallback screenshot:** guest agent tools when host capture stays blank. ScreenCaptureKit only after an explicit user opt-in to Screen Recording.

---

## 5. Headless mode
* A `VZVirtualMachine` runs without any view (Tart, Lima and Colima run headless). The display only becomes capturable through a view, and Lima
  refuses headless screenshots.
* Working trick (zyvor, verified on macOS 27.2): `NSWindow(contentRect:, styleMask: [.borderless], backing: .buffered, defer: false)`,
  `contentView = VZVirtualMachineView`, `isReleasedWhenClosed = false`, `ignoresMouseEvents = true`, opaque,
  `setFrameOrigin(NSPoint(x: -20000, y: -20000))`, `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]`,
  `orderFrontRegardless()`. A window that is never ordered in, or a view without a window, is expected to capture blank (UNVERIFIED for VZ specifically).
* Leave `automaticallyReconfiguresDisplay = false` on the hidden view so it doesn't resize the guest display. Set `true` only on the visible view.
* While no view exists, the guest keeps running and rendering. The first capture after creating a view needs the warm-up retry.

---

## 6. Build, signing, CI and TestFlight facts

* **Runners (actions/runner-images, read 2026-10-27):**
  * `macos-15` (arm64, macOS 15.7.9, image 20260907): **Xcode 16.4 default**; 26.0.1, 26.1.1, 26.2, 26.3 installed.
  * `macos-26` = `macos-latest` (arm64 M1 "3 (M1)" vCPU class, macOS 26.6.2, image 20261013): **Xcode 26.6 default**; 26.0.1 through 26.6.
  * `xcode-27` / `xcode-27-xlarge` (**preview**, base OS macOS 27.0.1, image 20261022): Xcode **27.1 default**, 27.2 RC, 27.0. This is the only image with
    the **macOS 27 SDK** (issue actions/runner-images#14404; "Beta … Images are provided 'as-is' … excluded from the SLA").
  * Intel: `macos-15-intel`, `macos-26-intel`.
* **SDK gating:** with Xcode 26.x you can't compile the macOS 27 APIs (`VZVirtualMachineViewAdaptor`, provisioning, DiskImageKit). Wrap them in a
  compile-time check. zyvor uses `#if compiler(>=6.4)`. `#if canImport(DiskImageKit)` is an alternative SDK probe (UNVERIFIED module name).
  Since 2026-04-28 uploads must be built with **Xcode 26+** (https://developer.apple.com/news/upcoming-requirements/).
* SwiftTerm ≥1.99 declares `swift-tools-version:6.2`, so it needs Xcode 26+ (Swift 6.2). On `macos-15` you must `xcode-select` Xcode 26. SwiftTerm has a
  build-tool plugin (`SwiftTermBuildInfoPlugin`), so CI `xcodebuild` needs **`-skipPackagePluginValidation`** (and `-skipMacroValidation` if any
  macros are used).
* **XcodeGen** (2.46.0): `targets.<T>.entitlements: {path, properties}` generates the file and sets `CODE_SIGN_ENTITLEMENTS`.
  `info: {path, properties}` generates Info.plist. Packages take `url` + `from:` / `exactVersion:` / `majorVersion:`. `projectFormat` accepts `xcode26_3`/`xcode27_0`.
  https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md (sample yml in (g)).
* **Provisioning:** `com.apple.security.virtualization` isn't a portal capability (absent from ASC API `CapabilityType`, and ad-hoc signing works),
  so there's nothing to enable for the bundle ID. App Sandbox keys aren't profile-gated either.
* **Mac TestFlight:** available since macOS 12 Monterey. Testers install the TestFlight app from the Mac App Store. The upload must contain an **embedded
  provisioning profile** (Mac App Store distribution). Otherwise you get "ITMS-90889: Cannot be used with TestFlight because the bundle … is missing a provisioning
  profile" (forums 696566, 758859). Export with method `app-store-connect` and `-allowProvisioningUpdates` with the ASC API key.
* **VMs on GitHub runners:**
  * **arm64 runners can't run VMs:** "Nested-virtualization is not supported due to the limitation of Apple's Virtualization Framework" (GitHub docs,
    `macos-runner-limitations`). The runners are M1, and VZ nested virtualization requires M3+.
  * **Intel runners can.** Colima's CI runs on `macos-15-intel` and logs "Starting the instance `colima` with internal VM driver `vz`" … "vm state change:
    running" (run https://github.com/abiosoft/colima/actions/runs/37021368104, 2026-10-02, all 5 jobs green). setup-docker-macos-action
    also lists `macos-15-intel` as supported. These are x86_64 Linux guests only: no macOS guests, no arm64 ISOs, no macOS 27 host.
  * The test process needs the entitlement. A plain `swift test` xctest binary lacks it, so `validate()` fails. Use an app-hosted XCTest bundle (`TEST_HOST` = signed app) or
    an ad-hoc-signed CLI harness (`codesign -s - --entitlements vz.entitlements harness`), as Lima does.
  * Whether GUI capture works on a runner (a window server session) is UNVERIFIED.

---

## 7. Terminal inside the app

* **SwiftTerm**: `https://github.com/migueldeicaza/SwiftTerm`. Latest **v1.99.1** (2026-10-21). v1.99.0 (2026-10-08) is the pre-2.0 line ("changing
  some APIs … you can no longer hold on to the underlying terminal"). Last 1.x: v1.19.0 (2026-08-18); v1.20.0 is marked prerelease. Platforms:
  `.macOS(.v11)`, tools 6.2. AppKit class: `open class TerminalView: NSView` (`Sources/SwiftTerm/Mac/MacTerminalView.swift`) with
  `terminalDelegate: TerminalViewDelegate?`, `feed(byteArray: ArraySlice<UInt8>)`, `feed(text:)`. Delegate: `send(source:data:)`,
  `sizeChanged(source:newCols:newRows:)`, `setTerminalTitle`, `hostCurrentDirectoryUpdate`, `scrolled`, `requestOpenLink`, `bell`,
  `clipboardCopy`, `rangeChanged`, and others. Some have default implementations, so check the pinned version. **Pin `exactVersion: 1.99.1`.**
* Wiring to the serial console: see (b) `SerialConsole` and the controller in (b) step 6.
* **SSH:** **Citadel** `https://github.com/orlandos-nl/Citadel`, latest **0.12.1** (2026-04-04), `.macOS(.v14)`, tools 5.9.
  `SSHClient.connect(to: SSHClientSettings(host:authenticationMethod:hostKeyValidator:))`, `executeCommand(_:)`,
  `executeCommandStream`, `withPTY(SSHChannelRequestEvent.PseudoTerminalRequest(...)) { ttyOutput, ttyStdinWriter in }`.
  Supply-chain note: it depends on a **fork of a fork**, `https://github.com/Wellz26/swift-nio-ssh` 0.3.4..<0.4.0 (itself a fork of Joannis/swift-nio-ssh,
  described as "to be archived once Apple reviews and merges 2 year old PRs").
  Apple's **swift-nio-ssh** is `https://github.com/apple/swift-nio-ssh` **0.15.1** (2026-10-26). It is lower level (NIOSSH, with no ready-made client API).
  **swift-nio** is at 2.104.0.
* Recommendation: the serial console terminal comes first (works from first boot). An SSH terminal through Citadel is second, needing the guest IP from the agent and `network.client`.

---

## Implementation brief for the ZVM coder

### (a) Entitlements plist (sandboxed Mac App Store app)

`ZComputer/ZComputer.entitlements`. Generate it from `project.yml` (see (g)). The final file must be exactly:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<!-- Required for the Mac App Store -->
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<!-- Virtualization.framework (unrestricted; no portal capability) -->
	<key>com.apple.security.virtualization</key>
	<true/>
	<!-- LLM APIs, Ollama/LM Studio on localhost, image downloads, SSH to guest -->
	<key>com.apple.security.network.client</key>
	<true/>
	<!-- Only if the app listens (local REST/MCP). Remove otherwise: reviewers ask about unused entitlements -->
	<key>com.apple.security.network.server</key>
	<true/>
	<!-- ISOs, shared folders, imports -->
	<key>com.apple.security.files.user-selected.read-write</key>
	<true/>
	<!-- Persist access to ISOs / shared folders across launches -->
	<key>com.apple.security.files.bookmarks.app-scope</key>
	<true/>
	<!-- Optional: guest microphone. Requires NSMicrophoneUsageDescription in Info.plist -->
	<!-- <key>com.apple.security.device.audio-input</key><true/> -->
</dict>
</plist>
```
Do **not** add `com.apple.vm.networking` (restricted, bridged only), `com.apple.security.hypervisor` (not needed for VZ), private
entitlements, or `cs.*` exceptions. Xcode adds `com.apple.application-identifier` and the team identifier from the profile at signing time.

### (b) Worked Swift: Linux ISO install configuration

```swift
import AppKit
import Foundation
import Virtualization

enum ZVMError: Error {
    case posix(String, Int32)
    case corruptBundle(String)
    case unsupportedHost(String)
}

/// On-disk layout of one Linux VM (inside the app container's Application Support).
struct LinuxVMBundle: Sendable {
    let root: URL
    var disk: URL { root.appendingPathComponent("disk.img") }
    var efiVars: URL { root.appendingPathComponent("efi-vars") }
    var machineID: URL { root.appendingPathComponent("machine-id") }
    var macAddress: URL { root.appendingPathComponent("mac-address") }
}

struct LinuxVMOptions: Sendable {
    var cpuCount: Int = 4
    var memoryBytes: UInt64 = 4 << 30
    var diskBytes: UInt64 = 64 << 30
    var displayWidth: Int = 1280
    var displayHeight: Int = 800
    var installerISO: URL?          // security-scoped URL from NSOpenPanel / bookmark; nil after install
    var sharedFolders: [String: URL] = [:]  // name -> security-scoped URL
    var agentDirectory: URL?        // container copy of the guest-agent binaries (read-only share "zagent")
    var enableRosetta = true
    var enableNestedVirtualization = false
}

/// Sparse RAW disk: logical size `bytes`; APFS allocates blocks only when the guest writes them.
func createSparseRawDisk(at url: URL, bytes: UInt64) throws {
    let fd = open(url.path, O_RDWR | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
    guard fd >= 0 else { throw ZVMError.posix("open", errno) }
    defer { close(fd) }
    guard ftruncate(fd, off_t(bytes)) == 0 else { throw ZVMError.posix("ftruncate", errno) }
}

/// Serial console over two pipes. Guest side is /dev/hvc0.
final class SerialConsole: @unchecked Sendable {
    private let toGuest = Pipe()    // host writes -> guest reads
    private let fromGuest = Pipe()  // guest writes -> host reads

    /// Attachment per Apple's semantics: the guest *reads* fileHandleForReading, *writes* fileHandleForWriting.
    func makeAttachment() -> VZFileHandleSerialPortAttachment {
        VZFileHandleSerialPortAttachment(fileHandleForReading: toGuest.fileHandleForReading,
                                         fileHandleForWriting: fromGuest.fileHandleForWriting)
    }
    /// Pipe writes can block when the guest isn't reading: call off the main thread.
    func send(_ data: Data) { toGuest.fileHandleForWriting.write(data) }

    func onOutput(_ handler: @escaping @Sendable (Data) -> Void) {
        fromGuest.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { handler(d) }
        }
    }
}

@MainActor
enum LinuxVMBuilder {
    static func makeConfiguration(bundle: LinuxVMBundle, options o: LinuxVMOptions,
                                  console: SerialConsole) throws -> VZVirtualMachineConfiguration {
        let fm = FileManager.default
        let needsInstall = !fm.fileExists(atPath: bundle.disk.path)
        try fm.createDirectory(at: bundle.root, withIntermediateDirectories: true)

        let c = VZVirtualMachineConfiguration()
        c.cpuCount = min(max(o.cpuCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount),
                         VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        let mib: UInt64 = 1 << 20
        let mem = min(max(o.memoryBytes, VZVirtualMachineConfiguration.minimumAllowedMemorySize),
                      VZVirtualMachineConfiguration.maximumAllowedMemorySize)
        c.memorySize = mem / mib * mib   // keep it a whole number of MiB

        // Platform + EFI
        let platform = VZGenericPlatformConfiguration()
        let boot = VZEFIBootLoader()
        if needsInstall {
            let id = VZGenericMachineIdentifier()
            try id.dataRepresentation.write(to: bundle.machineID)
            platform.machineIdentifier = id
            boot.variableStore = try VZEFIVariableStore(creatingVariableStoreAt: bundle.efiVars, options: [.allowOverwrite])
            try createSparseRawDisk(at: bundle.disk, bytes: o.diskBytes)
        } else {
            guard let id = VZGenericMachineIdentifier(dataRepresentation: try Data(contentsOf: bundle.machineID)) else {
                throw ZVMError.corruptBundle("machine-id")
            }
            platform.machineIdentifier = id
            boot.variableStore = VZEFIVariableStore(url: bundle.efiVars)
        }
        if o.enableNestedVirtualization, VZGenericPlatformConfiguration.isNestedVirtualizationSupported { // macOS 15, M3+
            platform.isNestedVirtualizationEnabled = true
        }
        c.platform = platform
        c.bootLoader = boot

        // Storage: optional installer ISO as a USB stick (read-only) + virtio main disk.
        var storage: [VZStorageDeviceConfiguration] = []
        if let iso = o.installerISO {
            let isoAttachment = try VZDiskImageStorageDeviceAttachment(url: iso, readOnly: true)
            storage.append(VZUSBMassStorageDeviceConfiguration(attachment: isoAttachment))
        }
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(
            url: bundle.disk, readOnly: false,
            cachingMode: .cached, synchronizationMode: .fsync)   // Lima's anti-corruption choice
        storage.append(VZVirtioBlockDeviceConfiguration(attachment: diskAttachment))
        c.storageDevices = storage
        c.usbControllers = [VZXHCIControllerConfiguration()]    // macOS 15: enables hot attach/detach of the ISO

        // NAT network with a stable MAC.
        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = VZNATNetworkDeviceAttachment()
        if let s = try? String(contentsOf: bundle.macAddress, encoding: .utf8),
           let mac = VZMACAddress(string: s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            net.macAddress = mac
        } else {
            let mac = VZMACAddress.randomLocallyAdministered()
            try mac.string.write(to: bundle.macAddress, atomically: true, encoding: .utf8)
            net.macAddress = mac
        }
        c.networkDevices = [net]

        // Display + input.
        let gpu = VZVirtioGraphicsDeviceConfiguration()
        gpu.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: o.displayWidth, heightInPixels: o.displayHeight)]
        c.graphicsDevices = [gpu]
        c.keyboards = [VZUSBKeyboardConfiguration()]
        c.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        // Sound (output only; input needs the audio-input entitlement + NSMicrophoneUsageDescription).
        let sound = VZVirtioSoundDeviceConfiguration()
        let out = VZVirtioSoundDeviceOutputStreamConfiguration()
        out.sink = VZHostAudioOutputStreamSink()
        sound.streams = [out]
        c.audioDevices = [sound]

        c.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        c.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        // virtio-fs: user folders, guest-agent binaries, Rosetta.
        var shares: [VZDirectorySharingDeviceConfiguration] = []
        if !o.sharedFolders.isEmpty {
            let fs = VZVirtioFileSystemDeviceConfiguration(tag: "zshare")      // guest: mount -t virtiofs zshare /mnt/zshare
            fs.share = VZMultipleDirectoryShare(directories: o.sharedFolders.mapValues { VZSharedDirectory(url: $0, readOnly: false) })
            shares.append(fs)
        }
        if let agentDir = o.agentDirectory {
            let fs = VZVirtioFileSystemDeviceConfiguration(tag: "zagent")      // guest: mount -t virtiofs zagent /mnt/zagent
            fs.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: agentDir, readOnly: true))
            shares.append(fs)
        }
        #if arch(arm64)
        if o.enableRosetta, VZLinuxRosettaDirectoryShare.availability == .installed {
            let fs = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")     // guest: mount -t virtiofs rosetta /media/rosetta
            fs.share = try VZLinuxRosettaDirectoryShare()
            shares.append(fs)
        }
        #endif
        c.directorySharingDevices = shares

        // Serial console (hvc0) over pipes.
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = console.makeAttachment()
        c.serialPorts = [serial]

        // Spice clipboard (needs spice-vdagent in the guest).
        let consoleDevice = VZVirtioConsoleDeviceConfiguration()
        let spicePort = VZVirtioConsolePortConfiguration()
        spicePort.name = VZSpiceAgentPortAttachment.spiceAgentPortName
        let spice = VZSpiceAgentPortAttachment()
        spice.sharesClipboard = true
        spicePort.attachment = spice
        consoleDevice.ports[0] = spicePort
        c.consoleDevices = [consoleDevice]

        // vsock for the guest agent.
        c.socketDevices = [VZVirtioSocketDeviceConfiguration()]

        try c.validate()
        return c
    }
}

/// Owns the VM on the main queue (required for VZVirtualMachineView use; see Risks).
@MainActor
final class LinuxVMController: NSObject {
    let vm: VZVirtualMachine
    let console: SerialConsole
    let displayView = VZVirtualMachineView()   // the visible view

    init(configuration: VZVirtualMachineConfiguration, console: SerialConsole) {
        self.vm = VZVirtualMachine(configuration: configuration)   // main queue
        self.console = console
        super.init()
        vm.delegate = self
        displayView.virtualMachine = vm
        displayView.automaticallyReconfiguresDisplay = true        // only on this view
        displayView.capturesSystemKeys = true
    }

    func start() async throws { try await vm.start() }
    func requestStop() throws { if vm.canRequestStop { try vm.requestStop() } }

    /// After install: unplug the ISO without a reboot (macOS 15+). Also drop it from the saved spec.
    func detachInstallerISO() {
        guard let usb = vm.usbControllers.first else { return }
        for device in usb.usbDevices where device is VZUSBMassStorageDevice {
            usb.detach(device: device) { error in if let error { print("detach failed: \(error)") } }
        }
    }
}

extension LinuxVMController: @preconcurrency VZVirtualMachineDelegate {
    func guestDidStop(_ virtualMachine: VZVirtualMachine) { /* publish .stopped */ }
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) { /* publish .error */ }
}
```

Step 6, SwiftTerm bound to the serial console:

```swift
import SwiftTerm

// TerminalViewDelegate is declared @MainActor in SwiftTerm 1.99; TerminalView has no init(frame:) of its own.
@MainActor
final class SerialTerminalController: NSObject, TerminalViewDelegate {
    let terminal = TerminalView(frame: .zero, font: nil)
    private let console: SerialConsole
    private let writeQueue = DispatchQueue(label: "zvm.serial.write")

    init(console: SerialConsole) {
        self.console = console
        super.init()
        terminal.terminalDelegate = self
        console.onOutput { [weak self] data in
            Task { @MainActor in self?.terminal.feed(byteArray: ArraySlice([UInt8](data))) }
        }
    }
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Data(data)
        writeQueue.async { [console] in console.send(bytes) }
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { /* serial has no SIGWINCH: optionally send `stty rows/cols` */ }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    // Add any remaining requirements the pinned SwiftTerm version doesn't default.
}
```

Notes:
* Keep `startAccessingSecurityScopedResource()` open on the ISO and shared-folder URLs until the VM stops.
* Before saving state, call `try? configuration.validateSaveRestoreSupport()` (macOS 14) and only offer suspend if it succeeds.
* Guest agent provisioning through serial (after the installer creates a user): log in, then
  `sudo mkdir -p /mnt/zagent && sudo mount -t virtiofs zagent /mnt/zagent && sudo install -m755 /mnt/zagent/zguest-$(uname -m) /usr/local/bin/zguest`,
  write `/etc/systemd/system/zguest.service`, then `systemctl enable --now zguest`. Send a sentinel `echo __ZDONE_$?__` and wait for it.

### (c) macOS-guest flow on Apple silicon (code skeleton)

```swift
@MainActor
func installMacOSGuest(bundle root: URL, ipsw localIPSW: URL?, diskBytes: UInt64 = 80 << 30) async throws -> VZVirtualMachine {
    #if !arch(arm64)
    throw ZVMError.unsupportedHost("macOS guests require Apple silicon")
    #else
    let ipswURL: URL
    if let localIPSW { ipswURL = localIPSW } else {
        let latest = try await VZMacOSRestoreImage.latestSupported            // network catalog
        let (tmp, _) = try await URLSession.shared.download(from: latest.url) // ~GBs: show progress via delegate
        ipswURL = root.appendingPathComponent("RestoreImage.ipsw")
        try FileManager.default.moveItem(at: tmp, to: ipswURL)
    }
    let image = try await VZMacOSRestoreImage.image(from: ipswURL)
    guard let req = image.mostFeaturefulSupportedConfiguration, req.hardwareModel.isSupported else {
        throw ZVMError.unsupportedHost("restore image not supported on this Mac")
    }
    try createSparseRawDisk(at: root.appendingPathComponent("disk.img"), bytes: diskBytes)
    try req.hardwareModel.dataRepresentation.write(to: root.appendingPathComponent("hardware-model"))
    let machineID = VZMacMachineIdentifier()
    try machineID.dataRepresentation.write(to: root.appendingPathComponent("machine-id"))
    let aux = try VZMacAuxiliaryStorage(creatingStorageAt: root.appendingPathComponent("aux"),
                                        hardwareModel: req.hardwareModel, options: [])

    let platform = VZMacPlatformConfiguration()
    platform.hardwareModel = req.hardwareModel
    platform.machineIdentifier = machineID
    platform.auxiliaryStorage = aux

    let c = VZVirtualMachineConfiguration()
    c.platform = platform
    c.bootLoader = VZMacOSBootLoader()
    c.cpuCount = max(req.minimumSupportedCPUCount, 4)
    c.memorySize = max(req.minimumSupportedMemorySize, 8 << 30)
    let gfx = VZMacGraphicsDeviceConfiguration()
    gfx.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 80)]
    c.graphicsDevices = [gfx]
    c.keyboards = [VZMacKeyboardConfiguration()]                                   // macOS 14+
    c.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]
    c.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment:
        try VZDiskImageStorageDeviceAttachment(url: root.appendingPathComponent("disk.img"), readOnly: false))]
    let net = VZVirtioNetworkDeviceConfiguration(); net.attachment = VZNATNetworkDeviceAttachment()
    c.networkDevices = [net]
    c.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    c.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
    c.socketDevices = [VZVirtioSocketDeviceConfiguration()]
    try c.validate()

    let vm = VZVirtualMachine(configuration: c)
    let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipswURL)
    // observe installer.progress.fractionCompleted
    try await installer.install()
    return vm
    #endif
}

/// First boot. macOS 27 host + macOS 27 guest: skip Setup Assistant.
@MainActor
func firstBoot(_ vm: VZVirtualMachine, user: String, password: String) async throws {
    #if compiler(>=6.4)   // built with the macOS 27 SDK (xcode-27 runner); zyvor uses the same guard
    if #available(macOS 27.0, *) {
        let p = VZMacGuestProvisioningOptions()
        p.fullName = user; p.username = user; p.password = password   // read from Keychain, never hard-code
        p.logsInAutomatically = true
        p.enablesRemoteLogin = true
        let opts = VZMacOSVirtualMachineStartOptions()
        try opts.setGuestProvisioning(p)
        try await vm.start(options: opts)
        return
    }
    #endif
    try await vm.start()   // older: the agent drives Setup Assistant through screenshots + input
}
```
On later boots, rebuild the platform from `VZMacHardwareModel(dataRepresentation:)`, `VZMacMachineIdentifier(dataRepresentation:)` and
`VZMacAuxiliaryStorage(url:)`. Handle `VZError.Code.virtualMachineLimitExceeded` when a third macOS VM is started (show "macOS allows 2
running macOS VMs per Mac"). Connect to the macOS guest with Citadel SSH (Remote Login enabled by provisioning). We ship no macOS guest agent in v1.

### (d) Screenshot strategy (ranked) + code

| Rank | Method | When | Known black / blank cases |
|---|---|---|---|
| 1 | IOSurface of the hidden view's first sublayer (`view.subviews.first?.layer?.contents as? IOSurface`) | always (fast path) | undocumented hierarchy may change; behaviour on 26/27 UNVERIFIED; check with `isBlank` |
| 2 | `bitmapImageRepForCachingDisplay(in:)` + `cacheDisplay(in:to:)` on the hidden view | always (UTM ships it) | view not in an ordered-in window; first ~0–6 s after view creation; backing store exactly equal to guest pixel size (zyvor); transparent window; guest DPMS blank |
| 3 | Guest agent (`grim`/`scrot`/`import`/`spectacle`) | graphical session + agent running | GNOME Wayland portal prompt; nothing during installers |
| 4 | ScreenCaptureKit `SCScreenshotManager.captureImage` on our own window | user opted into Screen Recording | TCC prompt; off-screen window may not be listed; protected-content black UNVERIFIED |
| never | `CGWindowListCreateImage` | — | obsoleted at macOS 15 (compile error); gray on macOS 27 for foreign windows |
| never | private `_takeScreenshotWithCompletionHandler:` / `_VZFramebuffer` / `_VZVNCServer` | — | App Review 2.5.1; "DRM Protected Video" black frames on macOS 26 (VirtualBuddy #533) |

```swift
import AppKit
import CoreImage
import IOSurface
import Virtualization

@MainActor
final class VMScreenCapturer {
    private let vm: VZVirtualMachine
    private(set) var view: VZVirtualMachineView?
    private var window: NSWindow?
    private var createdAt = Date()
    private let ci = CIContext(options: [.cacheIntermediates: false])

    init(vm: VZVirtualMachine) { self.vm = vm }

    /// Guest display size in pixels (macOS 14+ runtime API; fall back to the configured scanout).
    var displayPixels: CGSize {
        vm.graphicsDevices.first?.displays.first?.sizeInPixels ?? CGSize(width: 1280, height: 800)
    }

    /// Hidden agent view in an off-screen, ordered-in, opaque borderless window (zyvor's verified trick).
    func ensureView() -> VZVirtualMachineView {
        if let view { return view }
        let px = displayPixels
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        // Avoid backing-store pixels == guest pixels (blank captures): use 2x for small displays, 1/2x for large.
        let factor: CGFloat = px.width >= 1920 ? 0.5 : 2.0
        let points = NSSize(width: px.width * factor / scale, height: px.height * factor / scale)
        let v = VZVirtualMachineView(frame: NSRect(origin: .zero, size: points))
        v.virtualMachine = vm                    // macOS 27 SDK: v.adaptor = VZVirtualMachineViewAdaptor(virtualMachine: vm)
        v.automaticallyReconfiguresDisplay = false
        v.capturesSystemKeys = true
        let w = NSWindow(contentRect: v.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = v
        w.isReleasedWhenClosed = false
        w.ignoresMouseEvents = true
        w.isOpaque = true
        w.backgroundColor = .black
        w.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.orderFrontRegardless()
        view = v; window = w; createdAt = Date()
        return v
    }

    /// PNG of the guest display at guest pixel resolution, so screenshot pixels == ComputerSurface coordinates.
    func screenshotPNG() async throws -> Data {
        let v = ensureView()
        for attempt in 0..<12 {
            if let image = captureOnce(v), !isBlank(image) || Date().timeIntervalSince(createdAt) > 6 {
                return try encodePNG(resample(image, to: displayPixels))
            }
            if attempt == 3 { /* optionally inject a harmless Shift press to wake a DPMS-blanked guest */ }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw ZVMError.unsupportedHost("display capture stayed blank")
    }

    private func captureOnce(_ v: VZVirtualMachineView) -> CGImage? {
        // 1. IOSurface fast path (undocumented; guarded).
        if let surface = v.subviews.first?.layer?.contents as? IOSurface {
            surface.lock(options: .readOnly, seed: nil)
            defer { surface.unlock(options: .readOnly, seed: nil) }
            let img = CIImage(ioSurface: surface)
            if let cg = ci.createCGImage(img, from: img.extent) { return cg }
        }
        // 2. cacheDisplay (what UTM ships).
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        return rep.cgImage
    }

    /// True when every sampled pixel has the same colour (zyvor's `fluxImageIsBlank`).
    func isBlank(_ image: CGImage) -> Bool {
        let w = 64, h = 40
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return true }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let first = Array(px[0..<4])
        return stride(from: 0, to: px.count, by: 4).allSatisfy { Array(px[$0..<$0 + 4]) == first }
    }

    private func resample(_ image: CGImage, to size: CGSize) -> CGImage {
        let w = Int(size.width), h = Int(size.height)
        guard image.width != w || image.height != h,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    private func encodePNG(_ image: CGImage) throws -> Data {
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ZVMError.unsupportedHost("PNG encode failed")
        }
        return png
    }
}
```
Report `method` (iosurface/cacheDisplay/agent) and `blank` with each screenshot in the activity feed. That makes regressions on new macOS
releases visible immediately.

### (e) Synthetic input strategy + code

Primary: in-process NSEvents into the hidden agent view (works in firmware, GRUB, installers and any desktop; no guest dependency; no Accessibility
permission). Secondary: guest-agent `xdotool`/`wtype`/`ydotool` for Unicode text and on-guest key-name semantics. Tertiary: Spice clipboard + paste.
The approach is adapted from zyvor-fluxvm `AgentScreen.swift` (Apache-2.0): keep their notice if you copy code.

```swift
import AppKit
import Virtualization

@MainActor
final class VMInputInjector {
    let view: VZVirtualMachineView
    let displayPixels: () -> CGSize
    init(view: VZVirtualMachineView, displayPixels: @escaping () -> CGSize) { self.view = view; self.displayPixels = displayPixels }

    // kVK codes (US ANSI). true = needs Shift.
    private static let chars: [Character: (UInt16, Bool)] = {
        var m: [Character: (UInt16, Bool)] = [:]
        let letters: [(Character, UInt16)] = [("a",0),("s",1),("d",2),("f",3),("h",4),("g",5),("z",6),("x",7),("c",8),("v",9),
            ("b",11),("q",12),("w",13),("e",14),("r",15),("y",16),("t",17),("o",31),("u",32),("i",34),("p",35),("l",37),
            ("j",38),("k",40),("n",45),("m",46)]
        for (c, k) in letters { m[c] = (k, false); m[Character(c.uppercased())] = (k, true) }
        for (c, k) in [("1",18),("2",19),("3",20),("4",21),("6",22),("5",23),("=",24),("9",25),("7",26),("-",27),("8",28),
                       ("0",29),("]",30),("[",33),("'",39),(";",41),("\\",42),(",",43),("/",44),(".",47),("`",50),
                       (" ",49),("\n",36),("\t",48)] as [(Character, UInt16)] { m[c] = (k, false) }
        for (c, k) in [("!",18),("@",19),("#",20),("$",21),("^",22),("%",23),("+",24),("(",25),("&",26),("_",27),("*",28),
                       (")",29),("}",30),("{",33),("\"",39),(":",41),("|",42),("<",43),("?",44),(">",47),("~",50)]
                       as [(Character, UInt16)] { m[c] = (k, true) }
        return m
    }()
    private static let named: [String: UInt16] = ["return":36,"enter":36,"tab":48,"space":49,"backspace":51,"delete":117,
        "escape":53,"esc":53,"left":123,"right":124,"down":125,"up":126,"home":115,"end":119,"pageup":116,"page_up":116,
        "pagedown":121,"page_down":121,"f1":122,"f2":120,"f3":99,"f4":118,"f5":96,"f6":97,"f7":98,"f8":100,"f9":101,
        "f10":109,"f11":103,"f12":111]
    // (keyCode, flags incl. device-dependent left-hand bit; the view ignores modifiers without it)
    private static let mods: [String: (UInt16, NSEvent.ModifierFlags)] = [
        "shift": (56, .init(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x02)),
        "ctrl": (59, .init(rawValue: NSEvent.ModifierFlags.control.rawValue | 0x01)),
        "control": (59, .init(rawValue: NSEvent.ModifierFlags.control.rawValue | 0x01)),
        "alt": (58, .init(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x20)),
        "option": (58, .init(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x20)),
        "cmd": (55, .init(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x08)),
        "super": (55, .init(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x08)),  // Linux Super = HID GUI key
        "meta": (55, .init(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x08)),
    ]

    // The view must sit in an ordered-in window (see VMScreenCapturer.ensureView); events are dropped otherwise.
    private var window: NSWindow? { view.window }
    private var windowNumber: Int { window?.windowNumber ?? 0 }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }   // required-reason API: declare 35F9.1
    private func pause() { usleep(4_000) }

    /// Guest pixel (top-left origin) -> window coordinates of the view.
    private func point(_ x: Int, _ y: Int) -> NSPoint {
        let px = displayPixels(), b = view.bounds
        let local = NSPoint(x: CGFloat(x) * b.width / px.width, y: b.height - CGFloat(y) * b.height / px.height)
        return view.convert(local, to: nil)
    }

    func typeText(_ text: String) throws {
        for ch in text {
            guard let (code, shift) = Self.chars[ch] else { throw ZVMError.unsupportedHost("cannot type \(ch) without guest agent") }
            key(code: code, chars: String(ch), modifiers: shift ? ["shift"] : [])
        }
    }

    /// xdotool-style combo: "ctrl+alt+t", "Return", "super".
    func pressKeys(_ combo: String) throws {
        let parts = combo.lowercased().split(separator: "+").map(String.init)
        guard let last = parts.last else { return }
        let modifiers = Array(parts.dropLast())
        if parts.count == 1, Self.mods[last] != nil { press([last]); release([last]); return }
        if let code = Self.named[last] { key(code: code, chars: "", modifiers: modifiers) }
        else if last.count == 1, let (code, _) = Self.chars[Character(last)] { key(code: code, chars: last, modifiers: modifiers) }
        else { throw ZVMError.unsupportedHost("unknown key \(last)") }
    }

    private func key(code: UInt16, chars: String, modifiers: [String]) {
        let flags = press(modifiers)
        defer { release(modifiers) }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: now,
                                           windowNumber: windowNumber, context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars.lowercased(), isARepeat: false, keyCode: code)
            else { continue }
            type == .keyDown ? view.keyDown(with: e) : view.keyUp(with: e)
            pause()
        }
    }

    @discardableResult private func press(_ names: [String]) -> NSEvent.ModifierFlags {
        var held = NSEvent.ModifierFlags()
        for n in names { guard let (code, f) = Self.mods[n] else { continue }; held.formUnion(f); flagsChanged(code, held) }
        return held
    }
    private func release(_ names: [String]) {
        var held = names.reduce(into: NSEvent.ModifierFlags()) { $0.formUnion(Self.mods[$1]?.1 ?? []) }
        for n in names.reversed() { guard let (code, f) = Self.mods[n] else { continue }; held.subtract(f); flagsChanged(code, held) }
    }
    private func flagsChanged(_ code: UInt16, _ held: NSEvent.ModifierFlags) {
        guard let e = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: held, timestamp: now,
                                       windowNumber: windowNumber, context: nil, characters: "",
                                       charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) else { return }
        view.flagsChanged(with: e); pause()
    }

    private func mouse(_ type: NSEvent.EventType, _ p: NSPoint, clicks: Int = 1) {
        guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: now,
                                         windowNumber: windowNumber, context: nil, eventNumber: 0,
                                         clickCount: clicks, pressure: type == .leftMouseDown ? 1 : 0) else { return }
        window?.sendEvent(e); pause()
    }

    func mouseMove(x: Int, y: Int) { mouse(.mouseMoved, point(x, y)) }

    func click(x: Int, y: Int, button: String = "left", count: Int = 1) {
        let p = point(x, y)
        mouse(.mouseMoved, p)
        switch button {
        case "left":
            for n in 1...max(1, count) { mouse(.leftMouseDown, p, clicks: n); mouse(.leftMouseUp, p, clicks: n) }
        default:   // right/middle: NSEvent can't carry the button number; go through CGEvent (zyvor)
            let b: CGMouseButton = button == "right" ? .right : .center
            for type in [CGEventType.otherMouseDown, .otherMouseUp] {
                guard let cg = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: b),
                      let e = NSEvent(cgEvent: cg) else { continue }
                type == .otherMouseDown ? view.otherMouseDown(with: e) : view.otherMouseUp(with: e); pause()
            }
        }
    }

    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, steps: Int = 12) {
        let a = point(fromX, fromY), b = point(toX, toY)
        mouse(.mouseMoved, a); mouse(.leftMouseDown, a)
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            mouse(.leftMouseDragged, NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        mouse(.leftMouseUp, b)
    }

    /// dy > 0 scrolls down. One unit ≈ one wheel notch in the guest (zyvor's ×12 line scaling).
    func scroll(x: Int, y: Int, dx: Int, dy: Int) {
        mouse(.mouseMoved, point(x, y))
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                               wheel1: Int32(-dy * 12), wheel2: Int32(-dx * 12), wheel3: 0),
              let e = NSEvent(cgEvent: cg) else { return }
        window?.sendEvent(e)
    }
}
```
Caveats: US guest layout; ASCII only (route everything else to the agent or clipboard); keep the agent view's aspect ratio equal to the display's;
serialise through `SurfaceLease`; show the "agent is controlling" overlay; and the macOS guest pointer path is UNVERIFIED.

### (f) vsock guest-agent wiring

Host (Swift, on the VM's queue, which is main here):

```swift
import Foundation
import Virtualization

/// Thread-safe "first caller wins" flag.
final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool { lock.lock(); defer { lock.unlock() }; if fired { return false }; fired = true; return true }
}

@MainActor
final class GuestAgentChannel: NSObject {
    static let agentPort: UInt32 = 5555      // guest listens; host connects
    static let callbackPort: UInt32 = 5556   // optional: guest connects to host (events, "I'm alive")
    private let vm: VZVirtualMachine
    private let listener = VZVirtioSocketListener()
    private var connections: [VZVirtioSocketConnection] = []   // keep alive: the fd belongs to the object

    init(vm: VZVirtualMachine) { self.vm = vm; super.init() }

    private var device: VZVirtioSocketDevice? { vm.socketDevices.first as? VZVirtioSocketDevice }

    func startListening() {
        listener.delegate = self
        device?.setSocketListener(listener, forPort: Self.callbackPort)
    }

    /// `connect(toPort:)` "does nothing" if the guest isn't listening, so race it against a timeout.
    func connect(timeout: TimeInterval = 3) async throws -> FileHandle {
        guard let device else { throw ZVMError.unsupportedHost("no vsock device") }
        let once = OneShot()   // a captured `var` would not compile under Swift 6 (@Sendable timer closure)
        let conn: VZVirtioSocketConnection = try await withCheckedThrowingContinuation { cont in
            device.connect(toPort: Self.agentPort) { result in
                guard once.fire() else { return }   // a late success after timeout is dropped (connection closes)
                cont.resume(with: result)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                guard once.fire() else { return }
                cont.resume(throwing: ZVMError.unsupportedHost("guest agent not listening on vsock \(GuestAgentChannel.agentPort)"))
            }
        }
        connections.append(conn)
        // Defensive dup so FileHandle owns its own descriptor (lifetime of conn.fileDescriptor tied to `conn`: UNVERIFIED).
        let fd = dup(conn.fileDescriptor)
        guard fd >= 0 else { throw ZVMError.posix("dup", errno) }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)   // newline-delimited JSON both ways
    }
}

extension GuestAgentChannel: @preconcurrency VZVirtioSocketListenerDelegate {
    func listener(_ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                  from socketDevice: VZVirtioSocketDevice) -> Bool {
        connections.append(connection)          // return quickly; hand the fd to a reader
        return true                             // not implementing this method == refuse everything
    }
}
```
API facts: `VZVirtioSocketDeviceConfiguration()` (add exactly one), `VZVirtualMachine.socketDevices`, `VZVirtioSocketDevice.setSocketListener(_:forPort:)`,
`removeSocketListener(forPort:)`, `connect(toPort:completionHandler:)` / `connect(toPort:) async throws`, and `VZVirtioSocketConnection.fileDescriptor/sourcePort/destinationPort/close()`.
`VZVirtioSocketListenerDelegate.listener(_:shouldAcceptNewConnection:from:)` is optional; without it "the virtual machine refuses all connection requests".
https://developer.apple.com/documentation/virtualization/vzvirtiosocketdevice

Guest (Go, `guest-agent/`), using `github.com/mdlayher/vsock`:
```go
// Listen on VMADDR_CID_ANY:5555 (host connects with connect(toPort: 5555)).
l, err := vsock.Listen(5555, nil)
if err != nil { log.Fatal(err) }          // missing vmw_vsock_virtio_transport module => error here
for { c, err := l.Accept(); if err == nil { go serve(c) } }   // serve: bufio.Scanner over newline-delimited JSON

// Optional: guest -> host on port 5556. The host's CID is 2 (VMADDR_CID_HOST, vsock.Host).
conn, err := vsock.Dial(vsock.Host, 5556, nil)
```
The C equivalent: `socket(AF_VSOCK, SOCK_STREAM, 0)`, then `bind` to `{.svm_family=AF_VSOCK, .svm_cid=VMADDR_CID_ANY, .svm_port=5555}` and `listen`. To reach the host,
`connect` to `svm_cid=VMADDR_CID_HOST (2)`. Guest kernel needs `CONFIG_VIRTIO_VSOCKETS` (module `vmw_vsock_virtio_transport`, standard in
Debian, Ubuntu and Fedora kernels; minimal or custom kernels UNVERIFIED). Build static: `CGO_ENABLED=0 GOOS=linux GOARCH=arm64|amd64 go build`.

### (g) GitHub Actions macOS runner facts

* Labels: `macos-15` (arm64; Xcode 16.4 default, 26.0.1–26.3 present), `macos-26`/`macos-latest` (arm64 M1; Xcode 26.6 default), `xcode-27`
  (preview, macOS 27.0.1, Xcode 27.1 default, 27.2 RC; the only macOS 27 SDK), `macos-15-intel`, `macos-26-intel`.
* Build job: `runs-on: macos-26`, `sudo xcode-select -s /Applications/Xcode_26.6.app`, `brew install xcodegen`, `xcodegen generate`,
  `xcodebuild -project ZComputer.xcodeproj -scheme ZComputer -destination 'generic/platform=macOS' -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build`.
  Add a separate `xcode-27` job (allowed to fail while it's a preview) to compile the macOS 27 paths.
* TestFlight job: archive and export with `method: app-store-connect`, `-allowProvisioningUpdates` plus `-authenticationKeyPath/-authenticationKeyID/-authenticationKeyIssuerID`.
  The embedded profile is mandatory (ITMS-90889).
* **VMs can't run on the arm64 runners** (GitHub docs; nested virtualization unsupported; M1). **VZ does run on `macos-15-intel`** (Colima CI run 37021368104)
  for x86_64 Linux guests. Policy: all `ZVM` logic sits behind protocols (`VirtualMachineDriver`, `DisplayCapturing`, `InputInjecting`,
  `GuestAgentTransport`) with mocks in unit tests. An optional, non-blocking nightly `macos-15-intel` smoke job boots a tiny x86_64 ISO headless and
  checks for the serial-console login prompt and a vsock ping. It must run as an entitlement-signed host (app-hosted XCTest or an ad-hoc-signed harness).
* `project.yml` excerpt (XcodeGen 2.46):
```yaml
name: ZComputer
options:
  bundleIdPrefix: com.everaldtah
  deploymentTarget: { macOS: "15.0" }
  xcodeVersion: "26.6"
packages:
  SwiftTerm: { url: https://github.com/migueldeicaza/SwiftTerm, exactVersion: 1.99.1 }
  Citadel:   { url: https://github.com/orlandos-nl/Citadel, exactVersion: 0.12.1 }
  ZKit:      { path: ZKit }
  ZVM:       { path: ZVM }
targets:
  ZComputer:
    type: application
    platform: macOS
    sources: [ZComputer]
    dependencies:
      - package: ZKit
        products: [ZCore, ZProviders, ZAgent, ZMemory, ZTeam, ZLocal]
      - package: ZVM
      - package: SwiftTerm
      - package: Citadel
      - sdk: Virtualization.framework
    info:
      path: ZComputer/Info.plist
      properties:
        LSApplicationCategoryType: public.app-category.developer-tools
        LSMinimumSystemVersion: "15.0"
        ITSAppUsesNonExemptEncryption: false   # confirm export-compliance answer for SSH/TLS use (UNVERIFIED legal)
        NSMicrophoneUsageDescription: "Lets the virtual machine use your microphone."   # only with audio-input
    entitlements:
      path: ZComputer/ZComputer.entitlements
      properties:
        com.apple.security.app-sandbox: true
        com.apple.security.virtualization: true
        com.apple.security.network.client: true
        com.apple.security.network.server: true
        com.apple.security.files.user-selected.read-write: true
        com.apple.security.files.bookmarks.app-scope: true
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.everaldtah.zcomputer
        DEVELOPMENT_TEAM: BXQW8UBNM2
        CODE_SIGN_STYLE: Automatic
        ENABLE_HARDENED_RUNTIME: YES
        SWIFT_VERSION: "6.0"
```
Also ship `ZComputer/PrivacyInfo.xcprivacy` declaring the required-reason APIs actually used: `NSPrivacyAccessedAPICategorySystemBootTime`
reason `35F9.1` (`ProcessInfo.systemUptime` event timestamps), `NSPrivacyAccessedAPICategoryDiskSpace` `E174.1` (free-space check before
creating disks), `NSPrivacyAccessedAPICategoryUserDefaults` `CA92.1`, `NSPrivacyAccessedAPICategoryFileTimestamp` `C617.1`. Whether App
Store Connect enforces this for macOS uploads is UNVERIFIED; include it anyway.

### (h) App Store review risks

1. **Private API (2.5.1).** No `_VZ*` classes or selectors (VNC server, screenshot SPI, `_setDelegate`, `_startWithOptions`). No `Dynamic`/`NSClassFromString` tricks. Reading
   `view.subviews.first?.layer?.contents` uses only public calls but depends on undocumented structure. It is low risk for review and high risk for breakage, so keep the `cacheDisplay` fallback.
2. **Sandbox (2.4.5(i)).** All VM bundles live in the container. ISOs and shared folders must come only from `NSOpenPanel` plus security-scoped bookmarks. Don't access paths
   like `/var/db/dhcpd_leases` (get the guest IP from the agent). Don't spawn VM-hosting child processes (forum 786363). Use in-process VMs, or an XPC service later.
3. **Downloaded code (2.4.5(iv), 2.5.2).** Downloading OS images (IPSW, ISOs, cloud images) for the VM is the core function, and UTM, virtualOS and VirtualProg ship
   it on the store. Never download code that runs **on the host** (plugins, scripts). Bundle the guest-agent binaries in the app; they only run inside the guest.
4. **Restricted entitlements.** Don't include `com.apple.vm.networking` unless Apple grants it. Request it through Apple if bridged networking becomes a requirement.
5. **Data sent to third-party AI (5.1.2(i)).** Screenshots of the VM and the user's files go to cloud LLMs, so show clear disclosure and get **explicit
   permission** per provider before sending ("including with third-party AI"). Local models (MLX, Ollama) avoid this.
6. **Recording user activity (2.5.14).** Agent screenshots of the VM display need explicit consent plus a visible indicator while the agent is watching
   (the "agent is controlling" overlay and a recording badge).
7. **Hidden features (2.5.19).** Document the agent, terminal and guest-agent features in the description and review notes.
8. **Review-ability.** Give App Review a small arm64 Linux ISO URL and steps (including Apple silicon requirements). Note that macOS guests need Apple silicon and
   that only 2 can run at once. A multi-GB download during review risks a "could not test" rejection. Consider a "Try with Alpine aarch64 virt ISO" button
   (exact ISO size and URL UNVERIFIED).
9. **macOS guest licensing.** Install only from Apple's restore images (`latestSupported` or a user IPSW). Surface the 2-instance limit. Don't offer
   macOS-in-VM for purposes the SLA disallows (read the SLA; UNVERIFIED for 27).
10. **Microphone/TCC.** Add audio-input and `NSMicrophoneUsageDescription` only if guest mic input ships. Don't require Screen Recording
    (the ScreenCaptureKit path is opt-in only) or Accessibility (input is in-process).
11. **Export compliance.** SSH (Citadel/NIOSSH) and TLS use encryption. Answer the ASC export questions or set `ITSAppUsesNonExemptEncryption`
    correctly (UNVERIFIED which answer applies to us).
12. **Licences of dependencies.** SwiftTerm (MIT), Citadel (MIT), and zyvor code (Apache-2.0) if copied. If QEMU (GPLv2) is ever bundled for Windows, the GPL and
    App Store terms conflict (risk, not a ruling).
13. **SDK requirement.** Uploads must be built with Xcode 26+ (since 2026-04-28). macOS 27 features need the Xcode 27 toolchain, which on GitHub is a preview image.

---

## Recommended architecture (ZVM)

```
VMController (@MainActor, VM on main queue)
 ├─ LinuxVMBuilder / MacVMBuilder  → VZVirtualMachineConfiguration (above)
 ├─ visibleView: VZVirtualMachineView  (automaticallyReconfiguresDisplay = true, user input)
 ├─ VMScreenCapturer                  (hidden off-screen agent view; IOSurface → cacheDisplay → blank retry)
 ├─ VMInputInjector                   (NSEvents into the agent view; US layout; lease-protected)
 ├─ SerialConsole (+ SerialShell, SwiftTerm terminal)   — always available
 ├─ GuestAgentChannel (vsock 5555 / 5556)               — after provisioning
 └─ state stream (delegate: guestDidStop / didStopWithError)
VMSurface: ComputerSurface
   screenshot → capturer (agent screenshot fallback)
   mouse/keys → injector (typeText non-ASCII → agent xdotool/wtype → Spice paste)
   shell/files → agent → SerialShell fallback
```
* Guests: Linux arm64 (Apple silicon) or x86_64 (Intel, macOS ≤26 hosts) from UEFI ISOs or cloud raw images. macOS guests on Apple silicon through
  `VZMacOSInstaller`, with provisioning on 27. No Windows.
* Persist per VM: `spec.json`, `disk.img` (sparse RAW; ASIF/DiskImageKit stacking later on 27), `efi-vars` or `aux`, `machine-id`,
  `hardware-model`, `mac-address`, plus bookmarks for the ISO and shares.
* Testing: protocols plus mocks everywhere. Optional Intel-runner smoke job. Real-hardware checklist before each release (see Risks).

## Risks / unknowns (verify on real Apple silicon hardware before relying on them)

1. UNVERIFIED: `cacheDisplay(in:to:)` and the IOSurface path produce non-blank images for **our** hidden-window setup on macOS 15, 26 and 27, for both Linux
   virtio-gpu and macOS guests (third-party evidence: UTM ships cacheDisplay; zyvor verified macOS 27.2/M4/Debian 13; vzautomation from 2024).
2. UNVERIFIED: synthetic NSEvent input into macOS guests (trackpad device). For Linux it was verified by zyvor with evdev.
3. UNVERIFIED: whether `VZVirtualMachineView` works with a VM created on a non-main queue before macOS 27 (`VZVirtualMachineViewAdaptor`). Use the main queue.
4. UNVERIFIED: whether NAT needs `network.client` inside the sandbox (moot, since we include it). Whether vmnet (`VZVmnetNetworkDeviceAttachment`) needs `com.apple.vm.networking`.
5. UNVERIFIED: the security-scoped access lifetime needed for ISOs and virtio-fs shares while the VM runs (keep access open).
6. UNVERIFIED: `SCShareableContent.currentProcess` avoiding the Screen Recording prompt; whether ScreenCaptureKit captures VZ content (DRM flags).
7. UNVERIFIED: hot-detaching the USB ISO via `VZUSBController.detach(device:)` when the device came from `storageDevices` and `VZXHCIControllerConfiguration`
   is also configured.
8. UNVERIFIED: VZ display letterboxing vs stretching when the view's aspect ratio differs from the guest's (keep them equal).
9. UNVERIFIED: `VZVirtioSocketConnection` deallocation closing its fd (we `dup` defensively); Ubuntu installer SSH password behaviour; Debian
   network-console parameters; GNOME Wayland screenshot restrictions.
10. UNVERIFIED: the current macOS SLA wording on VM instances for macOS 27; PrivacyInfo enforcement for macOS uploads; export-compliance answer.
11. Known: the macOS 27 APIs (view adaptor, provisioning, DiskImageKit) can only be compiled on the **preview** `xcode-27` runner image as of 2026-10-27.
12. Known: future macOS releases may change undocumented behaviour (view hierarchy, capture), as macOS 26 did for VirtualBuddy's SPI and macOS 27 did for
    `CGWindowListCreateImage`. Keep the blank detector and per-method telemetry.

## Sources

Apple documentation (fetched as `.md`, 2026-10-27): https://developer.apple.com/documentation/virtualization ·
…/adding-the-virtualization-entitlement-to-your-project · …/bundleresources/entitlements/com.apple.security.virtualization ·
…/com.apple.vm.networking · …/com.apple.security.hypervisor · …/com.apple.vm.hypervisor · …/virtualization/vznatnetworkdeviceattachment ·
…/vzbridgednetworkdeviceattachment · …/vzvmnetnetworkdeviceattachment · …/running-gui-linux-in-a-virtual-machine-on-a-mac ·
…/running-macos-in-a-virtual-machine-on-apple-silicon · …/running-intel-binaries-in-linux-vms · …/vzdiskimagestoragedeviceattachment ·
…/vzvirtiofilesystemdeviceconfiguration · …/vzfilehandleserialportattachment · …/vzvirtioconsoledeviceserialportconfiguration ·
…/vzvirtiosocketdevice · …/vzvirtiosocketdevice/connect(toport:completionhandler:) · …/vzvirtiosocketlistenerdelegate ·
…/vzvirtualmachineview · …/vzvirtualmachineview/automaticallyreconfiguresdisplay · …/vzvirtualmachineviewadaptor · …/vzgraphicsdisplay ·
…/vzgenericplatformconfiguration/isnestedvirtualizationsupported · …/vzmacguestprovisioningoptions · …/vzmacosinstaller ·
…/vzmacosrestoreimage · …/vzmacauxiliarystorage · …/vzmacplatformconfiguration · …/vzusbmassstoragedevice · …/vzusbcontroller ·
…/vzerror/code · …/using-icloud-with-macos-virtual-machines · …/vzvirtualmachine/init(configuration:) ·
https://developer.apple.com/documentation/screencapturekit/scshareablecontent · …/scscreenshotmanager ·
https://developer.apple.com/documentation/appkit/nsview/cachedisplay(in:to:)

WWDC / forums / policy: https://developer.apple.com/videos/play/wwdc2026/224/ · https://developer.apple.com/forums/thread/784051 (Windows) ·
https://developer.apple.com/forums/thread/849969 (CGWindowListCreateImage on macOS 27, SCK consent) · https://developer.apple.com/forums/thread/786363
(sandbox inheritance) · https://developer.apple.com/forums/thread/800739 (cacheDisplay needs window; search snippet) ·
https://developer.apple.com/forums/thread/729580 and https://eclecticlight.co/2022/08/04/virtualisation-on-apple-silicon-macs-8-how-apple-limits-vms/ (2-VM limit) ·
https://developer.apple.com/forums/thread/696566 (ITMS-90889) · https://developer.apple.com/app-store/review/guidelines/ (Last Updated Oct 16, 2026) ·
https://developer.apple.com/news/upcoming-requirements/ · MacPorts tickets https://trac.macports.org/ticket/70756, https://trac.macports.org/ticket/71136

Open source: zyvor-fluxvm https://github.com/zyvorai/zyvor-fluxvm/pull/214 (`crates/fluxvm-apple/runner/AgentScreen.swift`) ·
Lima https://github.com/lima-vm/lima/pull/5098, issue #5094, `pkg/driver/vz/screenshot_darwin.go`, `pkg/driver/vz/vm_darwin.go`, `vz.entitlements`, `Makefile` ·
UTM https://github.com/utmapp/UTM (`Platform/macOS/Display/VMDisplayAppleWindowController.swift`, `Platform/macOS/macOS.entitlements`,
`QEMUHelper/QEMUHelper.entitlements`, `QEMULauncher/QEMULauncher.entitlements`), https://docs.getutm.app/installation/macos/ ·
VirtualBuddy https://github.com/insidegui/VirtualBuddy (`VirtualCore/Source/Headers/VirtualizationPrivate.h`, discussion #533,
`VirtualCore/Source/Virtualization/Screenshot/NSImage+DRMProtected.swift`) · Tart https://github.com/cirruslabs/tart (`Sources/tart/VNC/FullFledgedVNC.swift`,
`Resources/tart-prod.entitlements`) · lume https://github.com/trycua/cua (`libs/lume/src/VNC/VNCService.swift`) ·
vzautomation https://github.com/thecrypticace/vzautomation · virtualOS https://github.com/yep/virtualOS · Apple GUI Linux sample mirror
https://github.com/cicorias/GUILinuxVirtualMachineSampleApp · Colima https://github.com/abiosoft/colima (`.github/workflows/macos-integration.yml`,
run 37021368104) · https://github.com/douglascamata/setup-docker-macos-action

Runners / tooling: https://github.com/actions/runner-images (`images/macos/macos-15-arm64-Readme.md`, `macos-26-arm64-Readme.md`,
`xcode-27-arm64-Readme.md`, issue #14404) · GitHub docs `content/actions/reference/runners/github-hosted-runners.md` and
`data/reusables/actions/macos-runner-limitations.md` · App Store Connect OpenAPI spec 4.5.1 (`CapabilityType`) ·
https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md · https://github.com/migueldeicaza/SwiftTerm (v1.99.1) ·
https://github.com/orlandos-nl/Citadel (0.12.1) · https://github.com/apple/swift-nio-ssh (0.15.1) · https://github.com/apple/swift-nio (2.104.0)

Guests: https://www.freedesktop.org/software/systemd/man/latest/systemd-getty-generator.html ·
https://docs.fedoraproject.org/en-US/fedora-server/installation/interactive-remote/ (inst.rdp) · Launchpad bug 1933523 (subiquity installer password) ·
Intel cutoff: https://petapixel.com/2025/06/10/macos-26-tahoe-is-the-end-of-the-road-for-intel-macs/
