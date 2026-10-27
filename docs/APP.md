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
| Machines | `Machines/MachinesModel.swift`, `Views/Machines/*` | ZVM: `VMStore.standard()`, `VMController` (start/stop/pause, `displayHost.makeUserView()`), `ImageCatalog.forHost` + `ImagePreparer.prepare` + `CloudInitConfig` (ready-to-run Linux), ISO install with `ISOInspector` warnings, `MacOSInstaller` (Apple silicon), `provisionGuestAgent`, `makeSurface(credentials:)` |
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
* Not verified on hardware: VM display capture and input (ZVM risks list), MLX generation, Apple on-device model.
