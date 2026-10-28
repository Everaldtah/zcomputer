# ZEmu: x86 PCs in WebKit

ZEmu (`ZEmu/`, a SwiftPM package for **iOS 17+ and macOS 15+**) runs real 32-bit x86 Linux ISOs and disk images
with the [v86](https://github.com/copy/v86) emulator inside a `WKWebView`, and exposes the machine as a ZCore
`ComputerSurface`. ZAgent drives an emulated PC exactly like a ZVM (Virtualization.framework) machine: screenshots,
mouse, keyboard, shell, files.

Why WebKit: v86 translates x86 code to WebAssembly at run time and WebKit JIT-compiles that WebAssembly. Only WebKit
may JIT on iOS, so this is the App Store-legal way to run a PC emulator at usable speed on iPhone and iPad. No
hypervisor, no private API, no third-party Swift packages.

## Layout

| piece | file | what |
|---|---|---|
| `EmuSpec` | `EmuSpec.swift` | one machine: RAM, VGA memory, screen, boot media (`.iso` / `.disk` / `.state(_, disk:)`), extra CD/disk, 9p share, serial, network, NIC, ACPI, boot assist, serial login |
| `EmuStore` | `EmuStore.swift` | `Application Support/ZComputer/Emu`: `Machines/<id>/{spec.json,states/,disk.img}`, `Images/<image>/`, `ISOs/`; excluded from backup; paths in `spec.json` are `zemu-store:` / `zemu-documents:` URLs because iOS moves app containers |
| `EmuHost` | `EmuHost.swift` | the `WKWebView`, the JS bridge (`WKScriptMessageHandler` in, `callAsyncJavaScript` out), web-content crash events |
| `EmuSchemeHandler` | `EmuSchemeHandler.swift` | `zemu://app/...`: the page and v86 from the bundle, registered files with HTTP `Range`, the fetch-network CORS proxy |
| host page | `Resources/host/emu.{html,js}` | creates `new V86({...})`, batches serial bytes, screenshots, input, states, 9p |
| `EmuController` | `EmuController.swift` | lifecycle, saved states, autosave, CD-ROM, crash recovery, serial console |
| `EmuSurface` | `EmuSurface.swift` | the `ComputerSurface` (actor) |
| `ScanCodes`, `CursorTracker` | | PS/2 set-1 table and combos; absolute pointing on a relative mouse |
| `EmuSerialShell`, `EmuConsole` | | sentinel shell over COM1; console stream + input |
| `EmuImageCatalog`, `EmuImagePreparer` | `Resources/images-x86.json` | the image list, manifest resolution, resumable downloads, sha256, `.xz` |
| v86 | `Resources/v86/` | `libv86.js`, `v86.wasm`, `v86-fallback.wasm`, SeaBIOS + VGABIOS; release `latest` @ `cc37f35` (see `VERSION`) |

## How a machine runs

```swift
let store = try EmuStore.standard()
let catalog = try EmuImageCatalog.bundled()
let preparer = EmuImagePreparer(store: store)
let image = catalog.image(id: "alpine-virt-x86")!
let prepared = try await preparer.prepare(image) { print($0.detail) }       // download, sha256, unpack
let spec = try store.create(EmuImageCatalog.makeSpec(for: image, prepared: prepared, name: "Alpine"))
let machine = EmuController(spec: spec, store: store)
someView.addSubview(machine.view)                     // keep it in a window while it runs
machine.enableAutosave(interval: 300, saveOn: [UIApplication.willResignActiveNotification])
try await machine.start()                             // resumes the autosave of an earlier session, if any
let surface = machine.makeSurface()                   // hand to ZAgent
```

1. `EmuHost` loads `zemu://app/host/emu.html`. The page, `libv86.js`, `v86.wasm` and the BIOS come from the package
   bundle through `EmuSchemeHandler`. Everything is one origin, so there is no CORS (WebKit refuses cross-origin
   requests between custom-scheme origins).
2. `EmuController.start()` registers the ISO / disk / state files with the scheme handler (`zemu://app/files/<token>/…`)
   and calls `zemu.call("start", config)`. The page builds `new V86({ wasm_path, bios, vga_bios, memory_size,
   vga_memory_size, screen_container, boot_order, cdrom: {url, async: true, size}, hda: {url, async: true, size},
   initial_state: {url}, filesystem: {}, net_device: {type, relay_url: "fetch", cors_proxy}, acpi, fastboot,
   preserve_mac_from_state_image, autostart: true })`.
3. `async: true` disks are read lazily: v86 asks for byte ranges with XHR (`Range: bytes=a-b`); the scheme handler
   answers `206` with `Content-Range`, reading the file off the main thread in 1 MiB pieces. Multi-GB images never
   load into memory.
4. **Guest writes stay in memory and are persisted only in saved states.** The image file is never modified, which is
   what keeps a saved state restorable (a state only restores with the pristine image it was taken with). Use
   autosave or `stop(saveState: true)` to keep a machine's changes; `stop()` without saving discards the autosave so
   the next start boots afresh (or from the spec's own state).
5. Events come back through `window.webkit.messageHandlers.zemu`: `ready`, `loaded`, `started`, `stopped`, serial bytes
   (batched, base64, every 15 ms or 16 KiB), `screen` (`screen-set-size`), `absolute-mouse` (`vmware-absolute-mouse`),
   download progress, boot-assist results, warnings and errors.

### v86 API used (all checked against the vendored build)

`new V86(options)`; `add_listener` for `emulator-ready`, `emulator-loaded`, `emulator-started`, `emulator-stopped`,
`serial0-output-byte`, `screen-set-size`, `vmware-absolute-mouse`, `download-progress`, `download-error`; `run`,
`stop`, `restart`, `destroy`, `is_running`; `save_state` / `restore_state`; `serial0_send` / `serial_send_bytes`;
`keyboard_send_scancodes`; `bus.send("mouse-delta" | "mouse-click" | "mouse-wheel" | "mouse-absolute")`;
`screen_make_screenshot`, `screen_set_scale`, `screen_adapter.get_text_screen()` (there is no
`screen_get_text_screen` method on `V86`; the text rows come from the screen adapter);
`wait_until_vga_screen_contains`; `set_cdrom` / `eject_cdrom`; `create_file` / `read_file` and `fs9p`
(`SearchPath`, `CreateDirectory`, `DeleteNode`). The page uses `use_graphical_text: true`, so text modes are drawn
into the same canvas as graphics modes.

### Keeping it running when nobody looks

WebKit throttles timers and stops `requestAnimationFrame` for views outside a window or hidden, and iOS may suspend
the page. Keep the web view in the view hierarchy; when no screen shows it, park it behind other views or at
`alpha = 0.01` (not `isHidden`, not alpha 0); the iOS app's `MachineViewParking` does that. v86's main loop runs on a
Worker message channel, not on animation frames. Screenshots do not depend on display either: before
`screen_make_screenshot` the page calls the screen adapter's `update_graphical` / `update_graphical_text`, which copy
v86's framebuffer into the canvas. iOS still suspends WebKit when the app is in the background: pause or save then
(`enableAutosave(saveOn:)` with `willResignActiveNotification`, and request background time in the app).

When WebKit kills the web-content process (memory), `EmuController` reloads the page and resumes the last autosave
(or the spec's starting point) and reports it in `lastError`.

## How the agent drives it (`EmuSurface`)

| ComputerSurface | ZEmu |
|---|---|
| `screenshot()` | PNG of v86's framebuffer (`screen_make_screenshot` after a canvas refresh); text modes come out at 9x16 px per character; a blank text-mode capture falls back to rendering the text rows with CoreText. `screenText()` returns the VGA text. |
| `typeText` | PS/2 scan code set 1 for a US layout (`ScanCodes.typing`), 8 ms between keys. Characters a US keyboard cannot type go through `xdotool type` on the serial shell when the guest has a desktop. (`keyboard_send_text` is not used: it drops Tab and needs v86's browser keyboard adapter.) |
| `pressKeys("ctrl+alt+t")`, `keyDown`/`keyUp` | xdotool-style names → make codes, key make + break, modifiers released in reverse; Shift added for shifted characters (`ctrl+T`, `ctrl++`); extended keys with `0xE0`; Print Screen and Pause sequences. |
| mouse | **VMware absolute pointer** when the guest enabled it (kernel vmmouse / xf86-input-vmmouse; v86 reports `vmware-absolute-mouse`): `mouse-absolute [x, y, w, h]` followed by `mouse-click` with the current buttons, which raises the PS/2 interrupt the guest driver reads the backdoor on (alone, `mouse-absolute` does not move the pointer). Otherwise the **relative PS/2 mouse with cursor tracking**: home to (0, 0) with large negative movements, then move by the distance in small packets (`CursorTracker`; `setMouseSensitivity` for pointer acceleration; re-homing before every move unless a button is held). `setMouseRoute(.guestXdotool)` uses `xdotool` on the serial shell instead. `setAbsoluteMouse(false)` forces relative tracking. |
| click / double click / drag / scroll | button events 40 ms apart; drags in 12 steps; wheel notches with `mouse-wheel` (horizontal = Shift + wheel). |
| `shell` | the sentinel serial shell on COM1 (`ttyS0`): each command is base64-encoded into one typed line that prints `__ZB_<n>__`, runs it, and prints `__ZE_<n>_$?__`; long commands are staged in acknowledged chunks. It logs in with `EmuSpec.serialLogin` at a getty when no shell answers. stdout and stderr arrive merged. |
| `readFile` / `writeFile` | **9p fast path** when the guest can mount v86's 9p filesystem (`mount -t 9p -o trans=virtio,version=9p2000.L host9p /mnt/host`, done on demand): the host puts/gets the bytes with `create_file`/`read_file` and the guest copies them; else base64 over the serial line. |
| `info` | linux / x86, `shellAvailable` (a shell answers or a login is configured), `hasDesktop` (`pgrep -x Xorg`, else whether the display is in a graphics mode). |

The 9p mount tag is always `host9p` (fixed in v86). `EmuSpec.shareDirectory` copies a host folder's files into the
9p filesystem when the machine starts (at most 256 MB; files that already exist, e.g. from a restored state, are
kept). It is a copy, not a live share; the guest sees it under `/mnt/host` and writes there stay in the emulator
(and in saved states).

## Limits

* **32-bit x86 only** (i686 with SSE2/SSE3; no x86-64, no KVM/hardware virtualisation, no GPU acceleration, no
  OpenGL). Guests: Linux 32-bit (Alpine x86, Debian ≤ 12 i386, Tiny Core), older Windows/DOS/BSD.
* **Speed:** v86's JIT runs roughly at a few hundred MIPS on Apple silicon (a Pentium-class PC). Measured with the
  vendored build: the Alpine virt ISO reaches its serial login prompt in about 55 s under Node on a desktop PC; the
  Z Alpine Desktop disk cold-boots to XFCE in 90–170 s on a GitHub runner and restores from its state to a working
  shell in about one second. Phones are slower, and big programs (browsers) are slow.
* **Memory:** guest RAM lives in the WebAssembly memory of WebKit's web-content process, next to VGA memory, the JIT
  cache and every disk block the guest wrote. iOS kills a web-content process at roughly 1–1.5 GB of footprint
  (lower on 3–4 GB iPhones, more on 8 GB iPads), and restoring a state briefly holds the state file in memory too.
  `EmuSpec.recommendedMaxMemoryMBOnPhone` is 512 MB; `maxMemoryMBOnPhone` (1024 MB) is the hard ceiling
  `validate(isPhone:)` accepts.
* **Saved states** are tied to the v86 build (`Resources/v86/VERSION`) and to the machine options (RAM, VGA memory,
  devices, disks). They store RAM (non-zero pages only) and the guest's disk writes; a long-running machine's states
  grow with what it wrote. Saving transfers the state from the page in 4 MiB base64 pieces.
* **Network:** `.fetch` emulates DHCP/DNS and forwards the guest's plain-HTTP (port 80) requests through the page's
  `fetch()`, proxied by the scheme handler with `URLSession` (no CORS). No raw TCP/UDP, no TLS to port 443 from the
  guest (`https://` downloads inside the guest do not work); use `http://` mirrors (Alpine's work). On iOS, plain-HTTP
  loads need an App Transport Security exception in the app (`NSAllowsArbitraryLoads`, or per-domain exceptions).
* **Serial console:** COM1 at "115200" (v86's UART is not rate-limited). ISOs need `console=ttyS0` on the kernel
  command line for a serial shell; the catalogue's boot assists type it at the boot prompt.
* **Keyboard layout:** US only. Typing at the BIOS/bootloader level is paced at 40 ms per key (the BIOS keyboard
  buffer holds 15 keys).

## Images

`Resources/images-x86.json` (decoded by `EmuImageCatalog.bundled()`):

| id | what | size | notes |
|---|---|---|---|
| `z-alpine-desktop-x86` | Z Alpine Desktop (x86), **instant start** | ~118 MiB download (1.5 GiB sparse disk + 133 MiB state) | files from `manifest.json` of the `images-v1` release (built by `.github/workflows/images.yml`, see [IMAGES-X86.md](IMAGES-X86.md)); available once the release is published |
| `alpine-virt-x86` | Alpine Linux 3.22.7 virt ISO | 50 MiB | boot assist adds `console=ttyS0`; root without password on the serial console |
| `alpine-standard-x86` | Alpine Linux 3.22.7 standard ISO | 213 MiB | boot assist at the one-second `boot:` prompt |
| `debian-12-i386-netinst` | Debian 12.15 i386 netinst | 656 MiB | the last Debian i386 installer; VGA only |
| `tinycore-x86` | Tiny Core Linux 17.1 (FLWM desktop) | 26 MiB | boot assist presses Return at the menu |
| `tinycore-core-x86` | Tiny Core 17.1 Core (text) | 20 MiB | |

sha256s were taken from Alpine's `.sha256` files / `latest-releases.yaml` and Debian's `SHA256SUMS`; Tiny Core
publishes only md5, so its sha256s were computed from the ibiblio mirror after checking the official md5.

### Adding an image

1. Add an entry to `ZEmu/Sources/ZEmu/Resources/images-x86.json`: `id`, `name`, `summary`, `kind` (`iso`, `disk` or
   `instantStart`), `defaultMemoryMB`, and `files` with `role` (`cdrom`, `hda`, `state`), `url` (https), `sizeBytes`,
   `sha256`, and `compression` (`none` or `xz`, with `decompressedBytes` / `decompressedSha256`). Or point
   `manifestURL` at a manifest in the `tools/images/x86/manifest.mjs` format and leave `files` empty.
2. Optional: `serialLogin` (`{"user", "password"}`), `bootAssist` (`waitForScreenText` / `waitForSerialText`,
   `delaySeconds`, `typeText`, `keys`, `serialText`, `timeoutSeconds`; only used on cold boots), `network`
   (`none`/`fetch`), `nic` (`virtio`/`ne2k`), `enable9p`, `acpi`, `vgaMemoryMB`, `screen`.
3. Run `swift test --package-path ZEmu`: `CatalogTests` validates the file (unique ids, https, sha256, sizes, roles)
   and that boot-assist text is typable.

`EmuImagePreparer.prepare(_:progress:)` downloads into `Images/<id>/downloads/` (resumable with `Range` + `If-Range`),
checks the sha256, unpacks `.xz` with Apple's Compression framework (`COMPRESSION_LZMA` decodes the xz container,
including multi-block streams from `xz -T0`; tested with CRC32 and CRC64 fixtures) writing all-zero blocks as holes,
checks the unpacked size and sha256, and writes `ready.json`. A catalogue or manifest with other sha256s makes the
image "not ready" again.

## Tests

`swift test --package-path ZEmu` on a Mac (CI job `zemu`, `macos-15`): spec coding, store layout and portable paths,
scan codes (shifted characters, combos, extended keys), cursor maths, the serial shell against a fake console (with a
getty login), Range parsing and serving through the scheme handler, the catalogue and manifest mapping, `.xz`
fixtures, text rendering, and **an integration test** that downloads the Alpine virt ISO, boots it in a
`WKWebView`, and checks a serial boot line within 120 s and a non-blank screenshot; when the guest reaches its serial
login it also runs shell commands, a file round trip and a save/restore. The job also compiles the package for iOS
(`xcodebuild -scheme ZEmu -destination 'generic/platform=iOS Simulator'`). Logs, the serial log and the boot
screenshot are uploaded as the `zemu-logs` artifact.
