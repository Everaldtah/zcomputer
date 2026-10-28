# The ZComputer app target

The macOS app (SwiftUI + AppKit, Swift 6 language mode with complete concurrency checking, macOS 15.0+) that sits on
top of ZKit (ZCore, ZProviders, ZAgent, ZMemory, ZTeam, ZLocal) and ZVM. See [ARCHITECTURE.md](ARCHITECTURE.md) for the
modules and [research/](research/) for the facts behind the choices.

## Building

The Xcode project is generated, never committed:

```sh
brew install xcodegen
xcodegen generate                 # app without MLX: fast, needs Xcode 26+
ZC_MLX=YES xcodegen generate      # + in-app MLX models: needs Xcode >= 26.4 (Swift 6.3), arm64-only build
xcodebuild build -project ZComputer.xcodeproj -scheme ZComputer -destination 'generic/platform=macOS' \
  -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

* **Scheme**: `ZComputer` (Debug for run, Release for archive).
* **Metal toolchain**: SwiftTerm and MLX compile Metal shaders. `xcodebuild -showComponent MetalToolchain` exits 0
  even when it prints `Status: uninstalled`; CI parses the status and runs `xcodebuild -downloadComponent MetalToolchain`.
* **`-skipPackagePluginValidation`**: SwiftTerm ships a build-tool plugin; `-skipMacroValidation` covers MLX's
  swift-syntax dependency.
* **`ZC_MLX`**: `project.yml` includes `ZComputer/Config/mlx.yml` only when the `ZC_MLX` environment variable is
  truthy. That file adds mlx-swift 0.32.3, mlx-swift-lm 3.32.3 (MLXLLM, MLXVLM, MLXLMCommon), swift-transformers 1.3.5
  (Tokenizers) and swift-huggingface 1.0.0, sets `SWIFT_ACTIVE_COMPILATION_CONDITIONS += ZC_MLX` and `ARCHS = arm64`.
  Without it, `MLXClient.swift` / `MLXTokenizerBridge.swift` compile out and the MLX catalogue still downloads.
* **Guest agent**: CI copies the `zguest-linux-arm64/amd64` binaries from the `guest` job into
  `ZComputer/Resources/zguest/` (a folder reference, so they land in `Contents/Resources/zguest`, non-executable on the
  host). `AppPaths.guestAgentDirectory` hands that folder to `VMController` (shared read-only into Linux guests).
  Locally, build them with the commands in `.github/workflows/ci.yml` (`guest` job) if you need them.
* **SQLite linkage (known issue, ZKit)**: `ZKit/Package.swift` declares `CSQLite` with `pkgConfig: "sqlite3"` and a
  `.brew(["sqlite3"])` provider. On a Mac with Homebrew's (keg-only) sqlite, SwiftPM then links
  `/opt/homebrew/opt/sqlite/lib/libsqlite3.dylib` instead of the SDK's libsqlite3: the x86_64 slice fails to link and an
  arm64 build would not launch on other Macs. CI deletes Homebrew's `sqlite3.pc` before building (and checks with
  `otool -L` that the app links no Homebrew library). Locally, remove that `.pc` file (or `brew uninstall sqlite`)
  until ZKit declares `pkgConfig` / `providers` for Linux only.
* **Signing**: hardened runtime + App Sandbox. `ZComputer/ZComputer.entitlements` is committed exactly as
  docs/research/virtualization.md (a) specifies (app-sandbox, virtualization, network client + server, user-selected
  read-write, app-scope bookmarks); XcodeGen only references it. `Resources/PrivacyInfo.xcprivacy` declares the
  required-reason APIs (UserDefaults, system boot time, disk space, file timestamps).

## CI and release

* `ci.yml` job **`app`** (`macos-26`, Xcode 26.6): runs on pushes to `main` and on `workflow_dispatch` with `mac=true`
  (`gh workflow run ci.yml --ref <branch> -f mac=true`). Matrix `mlx: [NO, YES]`: the NO leg is the quick check of the
  app code, the YES leg compiles MLX too.
* `testflight.yml` (`workflow_dispatch`, tags `v*`): builds the guest agent, `xcodegen`, archives Release with automatic
  signing through the App Store Connect API key (secrets `ASC_KEY_P8`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, team
  `BXQW8UBNM2`, `-allowProvisioningUpdates`), then `-exportArchive` with method `app-store-connect` and destination
  `upload`. Input `mlx` (default off) makes an Apple-silicon-only MLX build.

## Screens and the modules behind them

| Screen | App files | Engine |
|---|---|---|
| Machines | `Machines/MachinesModel.swift`, `Views/Machines/*` | ZVM: `VMStore.standard()`, `VMController` (start/stop/pause, `displayHost.makeUserView()`), ISO install with `ISOInspector` warnings, `MacOSInstaller` (Apple silicon), `provisionGuestAgent`, `makeSurface(credentials:)` |
| Machines ▸ Library | `Machines/ImageLibraryModel.swift`, `Views/Machines/ImageLibraryView.swift`, `TemplateCard.swift`, `ProvisioningPanel.swift`, `Views/Agent/AgentOnboardingCard.swift` | ZVM: `ImageCatalog` (bundled `images.json`), `MachineTemplate` + `HostProfile` (`fits(host:)`), `ImagePreparer.download`/`prepare`, `ImageCache`, `CloudInitConfig.forImage` with `DesktopPreset`/`DevPreset`, `ProvisionStatus` read through `GuestAgentClient.readFile` |
| Agent | `Agent/AgentSession.swift`, `Views/Agent/*` | ZAgent `AgentRunner` (id `main`) on the chosen machine (`VMSurface`, or the `MockComputerSurface` "Demo machine"); events from the shared ZCore `EventBus` feed the transcript and the Activity panel; approvals via `AgentRunner.approve`, `ask_user` answered through the composer (`send(userMessage:)`) |
| Team | `Team/TeamModel.swift`, `Views/Team/TeamView.swift` | ZTeam `TeamRunner` (one per goal), `TeamSpec` persisted as `team.json` in Application Support, board from `teamEvents()`, member lanes from the shared bus, approvals via `approve(id:decision:memberID:)` |
| Library | `Library/LibraryModel.swift`, `Views/Library/*` | ZMemory `SQLiteMemoryStore` at `Application Support/ZComputer/Library/library.sqlite` with `NLEmbedder` (hashing fallback); PDF text via PDFKit (`Platform/DocumentTextExtractor.swift`) |
| Terminal | `Terminal/*`, `Views/Terminal/TerminalScreen.swift` | SwiftTerm 1.99.1 `TerminalView`; host shell = `/bin/zsh -l` through Foundation `Process` on an `openpty` pair (sandboxed, no job control); VM tab = ZVM `SerialConsole` |
| Settings ▸ Providers | `Views/Settings/ProvidersSettingsView.swift` | ZProviders `ProviderCatalog` (+ `FileCustomProviderStore`), keys and base-URL overrides in `KeychainKeyStore`, `KeyTester`, `listModels` |
| Settings ▸ Local models | `Local/LocalModelsModel.swift`, `Local/ModelDownloader.swift`, `Views/Settings/LocalModelsSettingsView.swift` | ZLocal `LocalServerDiscovery`, `LocalModelCatalog`, `LocalModelStore` (`downloadPlan` → `prepareDirectory` → delegate-based `URLSessionDownloadTask`s → `markInstalled`), `HostCapabilities` fit warnings |
| Settings ▸ Agent | `Views/Settings/SettingsView.swift` | `AgentPolicy` fields in UserDefaults (`App/AppSettings.swift`), per-provider screenshot consents |

Model clients come from `App/ClientResolver.swift`: catalogue providers through `ProviderClientFactory`, local servers at
the address discovery found, `MLXClient` (`Local/MLXClient.swift`, `#if ZC_MLX`: `ModelContainer` + `ChatSession`,
MLXVLM for vision models, native tool calls through the chat template or ZAgent's text protocol), and
`FoundationModelsClient` (`#if canImport(FoundationModels)`, macOS 26+, text only).

`Platform/` holds the Apple-only implementations of ZKit contracts: `KeychainKeyStore: KeyStore` (service
`com.everaldtah.zcomputer`), `CoreGraphicsImageResizer: ImageResizer` (resize + crop for the computer tool's zoom).

## Image Library (Machines ▸ Library)

Multi-GB images cannot ship in the app bundle, so the app downloads them on demand. The catalogue is
`ZVM/Sources/ZVM/Resources/images.json`: the 71 entries of [research/images.md](research/images.md) (33 cloud images,
38 installer ISOs; URLs, sizes and checksums verified 2026-10-27), plus two fields the app adds: `experimental` (the
arm64 NixOS, Rocky 10 and Pop!_OS ISOs, which have no partition table) and `intelMinMacOS` (kernel 6.12+ images that need
macOS 15.5 on Intel Macs, or the `nopku` kernel argument, lima#3334).

**First launch.** The Agent view shows "Get a machine for your agents" while no VM exists: *Open the Image Library*,
*Get Agent Desktop (Debian 13 + XFCE)* in one click, or *Keep using the Demo machine* (it stays in the machine picker).
The Machines screen has a Machines | Library switch in the toolbar.

**Templates** (`MachineTemplate.all`, recommended first; sizes are arm64 / x86_64 downloads):

| Template | Image | Download | Then |
|---|---|---|---|
| Agent Desktop (Debian 13 + XFCE), **Recommended** | Debian 13 generic qcow2 | 432 / 439 MB | Xfce/X11 + LightDM auto-login, ≈ 200 MB of packages, ≈ 3–5 min (estimate) |
| Agent Desktop (Ubuntu 24.04 + XFCE) | Ubuntu 24.04 server | 617 / 621 MB | same desktop, Firefox from Mozilla's APT repo; kernel 6.8 (fine on Intel before macOS 15.5) |
| Terminal / Dev (Ubuntu 24.04 server) | Ubuntu 24.04 server | 617 / 621 MB | git, build-essential, Python 3, Node.js + npm, tmux, ripgrep |
| Smallest (Ubuntu 24.04 minimal) | Ubuntu 24.04 minimal | 224 / 260 MB | terminal only, ready ≈ 30–60 s after power-on |
| Kali Linux (installer ISO) | Kali 2026.3 installer | 4.05 / 5.05 GB | manual install |
| Fedora Xfce spin (ISO) | Fedora 44 Xfce live | 2.67 / 2.93 GB | live desktop, install from there |
| Ubuntu Desktop 24.04 (installer ISO) | Ubuntu 24.04.5 desktop | 3.97 / 6.25 GB | manual install; GNOME/Wayland by default (pick "Ubuntu on Xorg") |
| macOS (Apple silicon) | Apple's latest restore image | from Apple | `MacOSInstaller`, then Setup Assistant |

`fits(host:)` blocks a template when the architecture has no build (or macOS on Intel), when memory is below the
template's minimum + 2 GB, or when free disk is below download + 4 GB; it warns when memory is lowered, when the sparse
disk could outgrow the free space, for Wayland desktops, experimental ISOs, Alpine ("advanced": OpenRC) and the Intel
`nopku` case. `VZEFIBootLoader` takes no kernel command line and the seed runs after the kernel is up, so `nopku` is a
warning (with "use the Ubuntu 24.04 template" as the way out), not something the app can apply.

**Get & Boot** (`ImageLibraryModel.getAndBoot`), cloud templates:

1. The VM is created in the store (user `z`, a random password kept in the Keychain, shown under Guest login) and
   selected; its page shows the provisioning panel.
2. Download into `Application Support/ZComputer/Images` (shared between machines, resumable: Pause cancels the request
   and keeps `<file>.part`; Resume continues with `Range` + `If-Range`). Progress, speed and time left show on the card,
   the panel and the machine's job bar.
3. Checksum: the distribution's sums file is fetched at download time and parsed in its style (GNU, BSD inside a PGP
   clear-signed file, bare hash, Pop!_OS JSON, openSUSE `-Current` → `-Snapshot…-Media`); when it cannot be read or
   does not list the file, the value from `images.json` is used. The source is shown ("SHA-512 from SHA512SUMS"). A
   mismatch deletes the file.
4. Disk: qcow2 → sparse raw `disk.img` (`QCOW2.convertToRaw`), grown to the template's size; the NoCloud seed is written.
5. Boot, then the app polls the guest agent every 3 s: ping (agent online), then `read_file
   /var/lib/zguest/provision.status`. The seed's `runcmd` runs `zguest-install` first and then each preset step through
   `/usr/local/sbin/zc-provision` (`step/total/stage/state/label`), so the panel shows "Installing the Xfce desktop (X11)
   (2/3)" while the agent is already reachable. The guest log is `/var/log/zcomputer-provision.log`.
6. `state=done` → **Ready for agents**: the machine becomes the Agent view's target (`setAgentChoice(.vm(id))`).

Installer templates download and verify the ISO, create the VM with the ISO attached and boot the installer; the
panel shows the research notes (Wayland, experimental). Every catalogue image is also listed under "All images for this
Mac": cloud images open New Machine ▸ Ready-to-run Linux with that image (desktop / developer-tools toggles, the same
presets), ISOs open New Machine ▸ Install from ISO with the catalogue ISO selected. "Downloaded images" lists the cache
(verified, partial) with Resume and Delete; deleting an image does not affect machines made from it.

## App Review safeguards

* Consent sheet (`CloudConsentSheet`) before screenshots or files go to a cloud provider, per provider, revocable in
  Settings ▸ Agent (guideline 5.1.2(i)). Local providers (MLX, Apple, Ollama, LM Studio, ...) skip it.
* Visible "Agent is controlling <machine>" indicator: overlay with a pulsing dot and Stop in the Agent view, a red frame
  plus banner on the machine's screen, and a sidebar badge (2.5.14).
* Public API only; no downloaded host code (guest binaries are bundled and only run inside guests).

## Integration notes / open items

* All engine modules are wired; the only simulated piece is the **Demo machine** (`Agent/MockComputerSurface.swift`),
  kept as the default target and as the fallback when `VMController.isSupported` is false.
* The host shell has no controlling terminal (Foundation `Process` cannot `setsid`), so Ctrl-C reaches the shell as
  input rather than SIGINT. Switching to SwiftTerm's `LocalProcessTerminalView` (forkpty) would add job control.
* `ModelDownloader` uses a default `URLSessionConfiguration`; a background configuration works with the same delegate
  but needs relaunch handling (`handleEventsForBackgroundURLSession`) before it is useful.
* MLX: the loaded model stays in `MLXModelCache` until another model is used; memory limits are not tuned yet.
* Not verified on hardware: VM display capture and input (ZVM risks list), MLX generation, Apple on-device model, and
  the Image Library's first boots (the desktop recipes come from package indexes, not from a booted VM; the
  first-boot times are the research's estimates).
* Provisioning progress is followed while the app runs; after a relaunch the panel is gone (the guest keeps
  provisioning, and the status file stays in `/var/lib/zguest/provision.status`).
