# Z Computer — Architecture

Z Computer is a native macOS app (Swift 6, SwiftUI + AppKit, macOS 15+) for the Mac App Store. It embeds a
virtual machine (Apple Virtualization.framework), lets AI agents see and drive that machine, keeps a personal
memory library, shows a live activity panel of what each agent is doing, and runs several agents as a team.

```
┌──────────────────────────────── ZComputer.app (SwiftUI) ───────────────────────────────┐
│ Machines │ Agent chat + Activity panel │ Team board │ Library │ Terminal │ Settings     │
├───────────┬──────────────┬──────────────┬─────────────┬────────────┬───────────────────┤
│   ZVM     │   ZAgent     │    ZTeam     │  ZMemory    │  ZLocal    │   ZProviders      │
│ (macOS)   │ loop, tools, │ roles, board │ SQLite +    │ Ollama/LM  │ catalogue +       │
│ VZ VMs,   │ computer-use │ lease, bus   │ embeddings  │ Studio/    │ OpenAI/Anthropic/ │
│ shots,    │ adapters,    │              │ retrieval   │ llama.cpp, │ Gemini/Ollama     │
│ input,    │ approvals    │              │             │ MLX, Apple │ clients, keys     │
│ serial,   │              │              │             │ FM (app)   │                   │
│ vsock     │              │              │             │            │                   │
├───────────┴──────────────┴──────────────┴─────────────┴────────────┴───────────────────┤
│                                   ZCore (contracts)                                     │
└─────────────────────────────────────────────────────────────────────────────────────────┘
                 guest-agent/ (Go, static linux binary, vsock JSON-lines server)
```

## Repository layout

```
project.yml              xcodegen spec → ZComputer.xcodeproj (generated in CI, never committed)
ZComputer/               app target sources (SwiftUI, AppKit, Virtualization views, Keychain, MLX, FoundationModels)
ZKit/                    SwiftPM package: ZCore, ZProviders, ZAgent, ZMemory, ZTeam, ZLocal (+ tests) — builds on Linux
ZVM/                     SwiftPM package (macOS only): Virtualization.framework VM controller + ComputerSurface
guest-agent/             Go: `zguest` vsock server (exec, files, screenshot, input, sysinfo)
docs/                    this file, research/, PLAN.md
.github/workflows/       ci.yml (Linux tests + guest-agent build + macOS app build), testflight.yml (archive + upload)
```

Rule: everything in `ZKit` must compile and test on Linux (`swift:6.x` container). Apple-only code lives in `ZVM`
or the app target, or behind `#if canImport(AppKit)` / `#if canImport(NaturalLanguage)` with a Linux fallback.

## ZCore — the contracts (already written; do not change signatures without telling the orchestrator)

| Type | Purpose |
|---|---|
| `JSONValue` | Sendable JSON enum (tool args, schemas, metadata). Literals, subscripts, `parse`, `jsonString`. |
| `ProviderID`, `ModelRef`, `ModelInfo`, `ModelCapabilities` | Provider/model identity and capabilities (vision, tools, nativeComputerUse, context). |
| `Role`, `ContentPart`, `ImageData`, `ChatMessage` | Transcript model. Parts: text, image, toolUse, toolResult, reasoning. |
| `ToolSpec`, `ToolCall`, `ToolResult`, `NativeToolKind` | Tool declaration (JSON schema, optional native kind) and calls/results. |
| `GenerationOptions`, `StreamEvent`, `Usage`, `FinishReason` | Request options and streaming events. |
| `LLMClient` | `stream(messages:tools:options:)`, `listModels()`, `embed(texts:model:)`; default `complete(...)`. |
| `KeyStore` | API keys + base URL overrides (Keychain in app, `InMemoryKeyStore` in tests). |
| `ComputerSurface` | What an agent can do on a machine: screenshot, mouse, keys, type, shell, read/write file. |
| `AgentEvent`, `AgentEventEnvelope`, `EventBus`, `AgentEmitter` | The activity feed. |
| `ApprovalRequest`, `ApprovalDecision`, `AgentStatus`, `AgentOutcome` | Human-in-the-loop and run results. |
| `MemoryKind`, `MemoryItem`, `MemoryHit`, `MemoryStore`, `Embedder` | Personal library contracts. |
| `ZError` | One error enum for the whole stack. |

## ZProviders

* `ProviderDescriptor` (Codable mirror of `Resources/providers.json`: id, name, kind free/freemium/paid/local,
  baseURL, apiStyle openai/anthropic/gemini/ollama/custom, authHeader, keyURL, docsURL, modelsEndpoint, freeTier,
  models[], quirks[]).
* `ProviderCatalog` — loads the bundled JSON (`Bundle.module`), exposes `all`, `byID`, `free`, `defaultModel(for:)`,
  and merges user-added custom providers (any OpenAI-compatible base URL).
* `ProviderClientFactory.makeClient(provider:model:keyStore:session:) async throws -> any LLMClient`.
* Clients (all `Sendable`, `URLSession`-based, SSE streaming, retries on 429/5xx with backoff, honest errors):
  * `OpenAIChatClient` — `/chat/completions`; covers OpenAI, Groq, Cerebras, OpenRouter, Mistral, DeepSeek, xAI,
    Together, Fireworks, DeepInfra, NVIDIA NIM, SambaNova, GitHub Models, Cloudflare, Hugging Face, LM Studio,
    llama.cpp, Z.ai, Moonshot, Qwen, MiniMax, Perplexity, custom. Quirk flags from the descriptor (no tools, no
    json mode, `max_completion_tokens` vs `max_tokens`, no system role, image detail).
  * `OpenAIResponsesClient` — `/responses`, used when the model has `nativeComputerUse == .openAIComputer`.
  * `AnthropicClient` — Messages API, `x-api-key`, `anthropic-version`, beta headers for computer use; maps
    `NativeToolKind.anthropicComputer/Bash/TextEditor` to native tool blocks; thinking deltas → `.reasoningDelta`.
  * `GeminiClient` — `generateContent` / `streamGenerateContent`, `x-goog-api-key`, function declarations,
    inline image parts, `computer_use` tool when native.
  * `OllamaClient` — native `/api/chat` (tools + images), `/api/tags`.
* `SSEParser` (line-based, handles `data:`/`event:`/comments/CRLF), `HTTPClient` (headers, timeouts, body logging
  hooks), `ToolCallAssembler` (merges streamed argument deltas into `ToolCall`s).
* Tests: JSON fixtures for every client (request body shape + stream parsing), catalogue validity (every provider
  has baseURL, every model has an id, free flags consistent).

## ZAgent

* `Tool` protocol: `spec: ToolSpec`, `invoke(_ call: ToolCall, ctx: ToolContext) async throws -> ToolResult`.
* `ToolContext`: agentID, `surface: ComputerSurface?`, `memory: MemoryStore?`, emitter, `approval: ApprovalGate`,
  `scratchDirectory`.
* Built-in tools:
  * `ComputerTool` — vendor-neutral `computer` function (actions: screenshot, click, double_click, right_click,
    mouse_move, drag, scroll, type, key, wait) over `ComputerSurface`; returns a screenshot after each action.
  * `ShellTool` — `shell(command, timeout)` via `surface.shell`; marks destructive commands for approval
    (rm -rf, mkfs, dd, shutdown, reboot, :(){ ... }, curl|sh, chmod -R 777, passwd, etc.).
  * `FileTool` — read_file / write_file / list_dir (through the surface).
  * `MemoryTool` — memory_search / memory_save / memory_list over `MemoryStore`.
  * `TaskTool` — `task_complete(summary, success)` so the model ends a run explicitly, and `ask_user(question)`.
* `NativeComputerBridge` — when the client's capabilities say the model has a native computer-use tool, declares
  the native tool instead and translates native actions (Anthropic `computer_20250124`+, OpenAI
  `computer_use_preview`, Gemini `computer_use`) into `ComputerSurface` calls, including coordinate scaling.
* `ScreenshotScaler` — downscales PNG/JPEG to a max long edge (default 1366) and scales coordinates back
  (pure-Swift, no CoreGraphics on Linux: scale factor only; actual resizing is done by a `ImageResizer` protocol
  implemented in the app with CoreGraphics, with a pass-through default).
* `TextToolCallParser` — fallback for models without tool calling: system prompt asks for one fenced
  ```json {"tool": "...", "arguments": {...}} ``` block per turn; parser is lenient.
* `ContextManager` — keeps the last N screenshots as images (default 3) and replaces older ones with
  "[screenshot omitted]"; summarises the transcript when the estimated token count passes a budget.
* `AgentRunner` (actor) — the loop: build system prompt (surface info + memory context + tool guidance) →
  stream completion (emit text/reasoning deltas) → execute tool calls (approval gate, emit call/result/screenshot)
  → repeat until `task_complete`, max steps, stop, or error. Supports `send(userMessage:)` mid-run, `pause()`,
  `resume()`, `stop()`, `approve(id:decision:)`. Records an `episode` into memory at the end.
* `AgentPolicy`: maxSteps, approvalMode (`never` / `destructiveOnly` / `always`), screenshotMaxEdge,
  stepDelay, tokenBudget.
* Tests with a `MockSurface` and a scripted `MockLLMClient` (sequence of canned stream events).

## ZMemory

* `SQLiteDatabase` — minimal wrapper over the C API (`CSQLite`): open, exec, prepared statements, bind/step,
  transactions. No third-party dependency.
* `SQLiteMemoryStore: MemoryStore` — tables `items`, `embeddings` (BLOB float32), `items_fts` (FTS5 if available,
  otherwise LIKE fallback). Hybrid search = cosine over embeddings ∪ keyword hits, reciprocal-rank fused.
* Embedders: `HashingEmbedder` (deterministic n-gram hashing, 256-d, always available), `ProviderEmbedder`
  (any `LLMClient.embed`), and in the app `NLEmbedder` (NaturalLanguage sentence embedding, macOS).
* `Chunker` — ~800-token chunks with overlap; `MemoryContextBuilder.contextBlock(for task:, store:, limit:)`
  returns the text block injected into the system prompt (profile + preferences + top hits).
* `EpisodeRecorder.record(task:transcript:outcome:)` — asks the model for a 5-line summary, stores an `episode`.

## ZTeam

* `TeamRole`: lead, worker, reviewer, custom(String). `TeamMember`: id, name, role, `ModelRef`, instructions.
* `TaskBoard` (actor): tasks {id, title, detail, status todo/doing/blocked/done, assignee, result}; change events
  go to the bus as `.note` + a `TeamEvent` stream for the UI.
* `SurfaceLease` (actor) — exclusive lock for *input* on a shared `ComputerSurface` (screenshots never block);
  `LeasedSurface: ComputerSurface` wrapper acquires the lease around each input/shell call with a queue.
* `MessageBus` — agent-to-agent messages (`team_send`, `team_inbox` tools) + broadcast.
* `TeamRunner` (actor) — lead plans the goal into tasks → assigns to workers (each an `AgentRunner` with its own
  client and a `LeasedSurface`) → runs workers concurrently (bounded) → reviewer checks results → lead writes the
  final report. Exposes pause/stop/approve pass-through and the per-member status.
* Tests: a 3-member team on `MockSurface` with scripted clients finishes a goal and the lease serialises inputs.

## ZLocal

* `LocalServerDiscovery.scan()` — probes Ollama (11434 `/api/tags`), LM Studio (1234 `/v1/models`,
  `/api/v0/models`), llama.cpp (8080 `/v1/models`), Jan (1337), vLLM (8000); returns `ProviderDescriptor`s with
  the discovered models so they appear like any other provider.
* `LocalModelCatalog` — curated small models for in-app MLX (ids, sizes, vision yes/no) from the research.
* The MLX runner (`MLXClient: LLMClient`) and Apple `FoundationModelsClient` live in the **app target**
  (`ZComputer/Local/`) because the MLX packages are Apple-only; ZLocal only holds the catalogue and discovery.

## ZVM (macOS only, Virtualization.framework)

* `VMSpec` (Codable): id, name, guest `.linux` / `.macOS`, cpuCount, memoryBytes, diskBytes, display size,
  `install` source (`.iso(URL)` / `.diskImage(URL)` / `.macOSRestoreImage(URL?)`), shared folders, headless flag.
* `VMStore` — `~/Library/Application Support/ZComputer/VMs/<id>/` with `spec.json`, `disk.img`, `efi-vars`,
  `aux`, `machine-id`; creates sparse raw disks.
* `VMController` (MainActor-isolated where VZ requires it; exposes async API) — builds `VZVirtualMachineConfiguration`
  per the research brief (EFI boot + USB mass storage ISO, virtio block/net(NAT)/gpu/sound/entropy/balloon/
  keyboard/pointing, virtio-fs shares, serial console via `VZVirtioConsoleDeviceSerialPortConfiguration`
  with pipes, vsock device), start/stop/pause/resume, state stream, `VZVirtualMachineView` for the UI.
* `VMSurface: ComputerSurface` — screenshot via the display view capture (or guest agent when connected),
  input via synthetic NSEvents into `VZVirtualMachineView`, shell/files via `GuestAgentClient` (vsock) with a
  serial-console fallback (`SerialShell`: writes command + sentinel, collects output).
* `GuestAgentClient` — JSON-lines over `VZVirtioSocketConnection` (port 5555): ping, exec, read_file, write_file,
  screenshot, input, sysinfo. Auto-provisions the agent into a fresh Linux guest through the serial console
  (binary shared via virtio-fs, copied to /usr/local/bin, systemd unit).
* `ImageCatalog` — downloadable ready-to-run images (Debian/Ubuntu cloud raw images for arm64 + x86_64) plus
  "Install from ISO" and "macOS" (Apple silicon) flows; `MacOSInstaller` wraps `VZMacOSInstaller`.

## guest-agent (Go)

`zguest`: `AF_VSOCK` listener on port 5555, newline-delimited JSON requests `{id, op, ...}` → responses
`{id, ok, ...}`. Ops: `ping`, `sysinfo`, `exec {cmd, timeout}` (bash -lc, captures stdout/stderr/exit, kills on
timeout), `read_file {path}`, `write_file {path, data_b64, mode}`, `screenshot` (tries `grim`, `spectacle`,
`gnome-screenshot`, `scrot`, `import`, `xwd`; returns PNG base64), `input` (xdotool/ydotool/wtype if present).
Static builds for linux/arm64 and linux/amd64; the CI copies them into the app's Resources.

## The app (ZComputer target)

* `AppModel` (@Observable, MainActor): catalogue, key store (Keychain), VM list + active controller, agent/team
  runners, event bus, memory store, settings.
* Windows: main `NavigationSplitView` — sidebar sections Machines / Agent / Team / Library / Terminal / Settings.
  * **Machine view**: `VMDisplayView` (NSViewRepresentable around `VZVirtualMachineView`), toolbar (start/stop/
    pause, attach ISO, snapshot-less), "agent is controlling" overlay with a Stop button.
  * **Agent view**: chat composer + transcript on the left, **Activity panel** on the right: timeline of
    events (thinking text, tool calls with arguments, results, screenshot thumbnails, approvals with
    Approve/Deny/Always buttons), filters per agent, Pause/Resume/Stop.
  * **Team view**: member editor (name, role, provider+model, instructions), goal input, task board columns,
    per-member lanes in the activity panel.
  * **Library view**: search, kind filter, import files (txt/md/pdf via PDFKit), edit/delete, profile editor.
  * **Terminal view**: SwiftTerm `TerminalView` bound to the VM serial console (and a host-side Process shell
    tab inside the sandbox).
  * **Settings**: Providers (grid of catalogue entries with Free badges, key field, Test button, model picker from
    `listModels`, base URL override, add custom provider), Local models (MLX downloads with progress, Ollama/LM
    Studio detection), Agent policy, About.
* Entitlements: app-sandbox, virtualization, network client + server, user-selected files read/write, bookmarks.

## CI / release

* `ci.yml`: (1) `swift test --package-path ZKit` on `ubuntu-latest` in `swift:6.1-noble` (apt libsqlite3-dev);
  (2) `go build` guest agent for arm64 + amd64, upload artifact; (3) macOS job: xcodegen, download guest agent,
  `xcodebuild build` for `generic/platform=macOS` unsigned.
* `testflight.yml`: archive with the App Store Connect API key (secrets `ASC_KEY_P8`, `ASC_KEY_ID`,
  `ASC_ISSUER_ID`, team `BXQW8UBNM2`), export `app-store-connect`, upload. Bundle id `com.everaldtah.zcomputer`,
  App Store Connect app id 6827705945.

## Coding conventions

* Swift 6 language mode, strict concurrency: value types `Sendable`, actors for mutable state, `@MainActor` for UI/VZ.
* No force unwraps in library code; errors are `ZError` or wrapped.
* Every module ships XCTest coverage that runs on Linux; mocks live in the test targets.
* Keep provider/model strings in `providers.json`, never hard-code them in Swift except for test fixtures.
