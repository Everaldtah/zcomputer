# Z Computer for iPhone and iPad

`ZComputeriOS` is the iOS 17+ SwiftUI app (iPhone and iPad, Swift 6 language mode with complete concurrency
checking). It ships under the same bundle id as the Mac app, `com.everaldtah.zcomputer`: the App ID is universal, so
the iOS build lands in the same App Store Connect record (6827705945) and the two are one universal purchase.
Team `BXQW8UBNM2`, marketing version from `project.yml`, build number from CI.

## What runs on the iPhone, and how

| Piece | How it runs on iOS |
|---|---|
| **The machine** | 32-bit x86 Linux emulated by **v86** inside a `WKWebView` (ZEmu). v86 translates x86 to WebAssembly and WebKit JIT-compiles the WebAssembly: that is the App Store-legal way to run a PC emulator at usable speed, because only WebKit may JIT on iOS. No hypervisor, no private API. Expect a light desktop (Alpine + a small window manager), not a modern distro. |
| **The agent** | ZAgent's `AgentRunner`, unchanged. It sees the machine through ZEmu's `EmuSurface: ComputerSurface` (screenshots of the emulated display, mouse/keyboard events injected into v86, shell over the serial console). The Demo machine (`MockComputerSurface`) works without any emulator. |
| **Cloud models** | ZProviders, unchanged: the same providers.json catalogue, keys in the Keychain (`KeychainKeyStore`, default access group). |
| **Your own servers** | ZLocal's `LocalServerDiscovery` probes the addresses the user enters (Settings ▸ Local models), e.g. Ollama on their Mac over Tailscale (`100.x.y.z:11434`). Nothing on the network is scanned automatically. `NSAllowsArbitraryLoads` is on because these servers speak plain HTTP. |
| **On-device models (MLX)** | `ZC_MLX` builds link mlx-swift / mlx-swift-lm and run the curated catalogue on the Apple GPU (`MLXClient`, shared with the Mac). Small 4-bit models (1–4B) fit iPhones; the app asks iOS for more memory with `com.apple.developer.kernel.increased-memory-limit`, caps MLX's buffer cache (`MLXMemoryBudget`) and refuses to load a model that does not fit `os_proc_available_memory()`. |
| **Apple's model** | `FoundationModelsClient` (iOS 26+, Apple Intelligence; text only, 4K context). |
| **Library** | ZMemory's `SQLiteMemoryStore` (SDK SQLite) in Application Support, NaturalLanguage sentence embeddings, PDF import through PDFKit. |
| **Team** | ZTeam's `TeamRunner`, unchanged; members share the agent's machine through the input lease. |

### Memory

An iPhone app gets a fixed share of RAM before iOS ends it (jetsam). Everything heavy shares that budget: the
emulated PC's RAM (the WebKit content process holds it), an MLX model's weights and KV cache, and the screenshots the
agent keeps. With the increased-memory-limit entitlement, recent iPhones allow a few GB. Practical limits:

* machine RAM 256–512 MB on iPhone (the create sheet defaults to the image's suggestion, max 2 GB);
* MLX models: Settings ▸ Local models warns when a model will not fit the memory the app can use right now;
* use a model server on another computer (or a cloud model) when the phone runs a machine *and* the agent.

## Screens

| Tab | Files | Engine |
|---|---|---|
| **Machines** | `Views/Machines/MachinesScreen.swift`, `ImageLibrarySheet.swift`, `MachineScreen.swift`, `ScreenHost.swift`; `Machines/*` | `MachineEngine` (ZEmu): machine list (Demo machine first), image library (recommended **Z Alpine Desktop** instant start, Alpine virt ISO, Debian 12 i386 netinst, Tiny Core; download progress / cancel / resume; your ISOs from Files), create (name, RAM), full-screen machine: pinch to zoom, tap = click, long press = right click, one-finger drag = drag, two-finger pan = scroll (pans the screen when zoomed), key row (keyboard toggle, send text, Ctrl / Alt one-shot, Esc, Tab, arrows, Return, Backspace; iPad hardware keyboard arrows / Esc / Tab / Ctrl-combos), pause / resume, save state, power. "Agent is controlling" red frame + banner with Stop. |
| **Agent** | `Views/Agent/AgentScreen.swift`, `ActivityViews.swift`, `AgentChrome.swift` | Shared `AgentSession` (ZAgent `AgentRunner` "main"): model picker, machine picker (no machine / Demo / emulated machines), Chat and Activity (segmented; switches to Activity when an approval arrives): events, tool calls with arguments, results, screenshot thumbnails (full-screen viewer), approval cards (Approve / Deny / Always), `ask_user` answered from the composer; pause / resume / stop / new conversation. Consent sheet before screenshots go to a cloud provider. |
| **Team** | `Views/Team/TeamScreen.swift` | Shared `TeamModel` (ZTeam): goal, parallel workers, use the agent's machine, run / pause / stop, message the team, task board (columns scroll sideways), member editor (name, role, model, instructions), per-member lanes. |
| **Library** | `Views/Library/LibraryScreen.swift`, `LibraryEditors.swift` | Shared `LibraryModel` (ZMemory): search (meaning + keywords), kind filter, new item, import txt / md / pdf (document picker, PDFKit), read / edit / delete, profile and preferences. |
| **Terminal** | `Views/Terminal/TerminalScreen.swift`, `Terminal/ConsoleTerminal.swift` | SwiftTerm 1.99.1 (iOS `TerminalView`, its accessory key bar) bound to a machine's serial console (`MachineRuntime.consoleOutput` / `writeConsole`), or the Demo machine's simulated shell. One terminal per machine for the session (scrollback survives tab switches). |
| **Settings** | `Views/Settings/*` | Providers (grid of cards with Free / Free tier / Paid / Local badges; key entry, Test, model picker, base-URL override, custom OpenAI-compatible providers), Local models (this device's memory / storage, your model servers, MLX catalogue with download / delete and fit warnings, Apple's model), Agent policy (approvals, steps, tool-call mode, screenshots, consents), About. |

The **agent-watching indicator** stays visible on every tab while the agent works on a machine (a capsule with a
pulsing dot and Stop, `RootView`), on the Agent tab, and as a red frame on the machine's screen (App Review 2.5.14).

## Code layout and sharing with the Mac app

* `ZComputeriOS/` holds the iOS app: `App/` (entry point, `AppModel`, `ClientResolver`, `DeviceInfo`), `Machines/`
  (`MachineEngine` protocol, `MachinesModel`, view parking, touch/keyboard input), `Local/` (iOS Foundation Models
  client, MLX memory budget), `Terminal/`, `Views/`, `Resources/` (asset catalog, privacy manifest),
  `Config/mlx-ios.yml` (MLX dependencies, included with `ZC_MLX`).
* Platform-neutral Mac app files are compiled into the iOS target as-is (listed in `project.yml`):
  `Agent/ActivityItem`, `Agent/AgentSession`, `Agent/DemoScreenRenderer`, `Agent/MockComputerSurface`,
  `App/AppSettings`, `Library/LibraryModel`, `Local/LocalModelsModel`, `Local/MLXClient`, `Local/MLXTokenizerBridge`,
  `Local/ModelDownloader`, `Platform/CoreGraphicsImageResizer`, `Platform/DocumentTextExtractor`,
  `Platform/FileCustomProviderStore`, `Platform/KeychainKeyStore`, `Team/TeamModel`. **Keep them free of AppKit and
  ZVM**: the iOS app provides the members they use (`MachinesModel.agentSurface()` / `agentMachineName` /
  `agentChoiceKey`, `ClientResolver`). Views are written per platform (iOS navigation, sheets and touch differ too
  much from the Mac's split views to share).
* ZVM (Virtualization.framework) is never linked on iOS. ZKit declares `.iOS(.v17)` and is otherwise unchanged
  (it still builds and tests on Linux).

### The machine layer

`Machines/MachineEngine.swift` defines what the app needs from an emulator: list / create / delete machines, the image
catalogue with resumable downloads, and per-machine runtimes (`start`, `stop`, `pause`, `resume`, `saveState`, state
stream, the live `screenView`, serial console, `makeSurface() -> ComputerSurface`). `ZEmuMachineEngine` adapts ZEmu's
`EmuStore` / `EmuController` / `EmuImageCatalog` / `EmuImagePreparer` to it; `UnavailableMachineEngine` stands in when
ZEmu is not linked (`#if canImport(ZEmu)` in `ZComputeriOSApp.makeEngine()`), so the app always builds.

**Keeping the emulator alive across tabs**: a running machine's `WKWebView` must stay in a window or WebKit throttles
and suspends its JavaScript. `MachineViewParking` keeps a full-size container *behind* the tab view (covered, not
hidden); a machine's view lives there whenever no full-screen screen shows it, and `MachineScreenHost` moves it in and
out. iOS still suspends WebKit when the whole app goes to the background, so running machines are paused on
background and resumed on return.

## Building

```sh
xcodegen generate                      # app without MLX
ZC_MLX=YES xcodegen generate           # + on-device MLX models (Xcode >= 26.4)
xcodebuild build -project ZComputer.xcodeproj -scheme ZComputeriOS -destination 'generic/platform=iOS' \
  -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

* CI: `ci.yml` job **`ios`** (`macos-26`, Xcode 26.6, matrix MLX NO / YES; YES is informational) runs on pushes to
  `main` and on `workflow_dispatch` (input `ios`, default on).
* TestFlight: `testflight.yml` input **`platform`** (`both` default, `mac`, `ios`). The `ios` job archives
  `ZComputeriOS` for `generic/platform=iOS` with the same App Store Connect key and automatic signing, exports with
  method `app-store-connect` and uploads. Automatic signing adds the *Increased Memory Limit* capability to the App ID
  the first time.
* Entitlements (`ZComputeriOS/ZComputeriOS.entitlements`): `com.apple.developer.kernel.increased-memory-limit`, the
  default Keychain access group. No App Sandbox key (iOS apps are always sandboxed; `ENABLE_APP_SANDBOX` is a Mac
  setting). `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO`: the Mac gets the native Mac app.
* Info.plist (generated from `project.yml`): local-network usage string, `UIFileSharingEnabled` +
  `LSSupportsOpeningDocumentsInPlace` (drop ISOs into Files ▸ On My iPhone ▸ Z Computer), no background modes,
  `ITSAppUsesNonExemptEncryption = NO`, portrait + landscape (all four on iPad), one scene.

## Known limits

* x86 emulation in WebAssembly is slow next to the Mac's virtual machines: boot from the saved state (Z Alpine
  Desktop) instead of installing; an installer ISO can take a long time.
* 32-bit x86 only (v86); no 64-bit guests, no GPU acceleration, networking only through what ZEmu provides.
* Background execution: iOS suspends the app (and the emulator) shortly after it leaves the screen; machines resume
  where they were, and a saved state survives the app being closed.
* MLX needs a real device (not the simulator) and enough free memory; a large model and a running machine compete
  for the same budget.
* The Terminal shows the serial console, not a host shell (iOS apps cannot spawn processes).
* Not verified on hardware yet: the emulator (ZEmu), MLX generation and the Apple on-device model on iPhone.
