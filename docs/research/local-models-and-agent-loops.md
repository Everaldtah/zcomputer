# Local models and agent loops: research for Z Computer

Scope: everything ZLocal (in-app MLX, Apple Foundation Models, local servers, embeddings) and ZAgent (native computer-use
tools for Anthropic, OpenAI and Gemini, the vendor-neutral fallback, screenshots, context, team mode, memory) need
before coding. Written 2026-10-27.

How to read this:

* Every fact carries a source tag `[S#]`. The full URL and the date each source was seen are in **Sources** at the
  end. Everything was fetched or re-checked on **2026-10-27** unless the source line says otherwise.
* **UNVERIFIED** marks anything not confirmed from a primary source today (inference, community lore, or a check
  that needs a real Mac / a live API key).
* Swift snippets were **not compiled** here (Windows host, no Mac). API names in them come from the package source or
  Apple's documentation JSON at the cited tag, but treat each snippet as a first draft for the macOS CI to check.
* The original brief named the file `local-models-and-agents.md`; the orchestrator renamed the deliverable to this file.

---

## TL;DR: decisions that change the plan

1. **MLX moved.** `MLXLLM` / `MLXVLM` / `MLXLMCommon` / `MLXEmbedders` now live in **`ml-explore/mlx-swift-lm`**, not
   `mlx-swift-examples` (whose last release is 2.29.1 from 2025-10-16) [S1][S3][S14]. Pin
   **`https://github.com/ml-explore/mlx-swift-lm` exact `3.32.3`** + **`https://github.com/ml-explore/mlx-swift` exact
   `0.32.3`** [S1][S2][S10]. That pair needs **Swift 6.3 / Xcode ≥ 26.4**, so the macOS CI job must run on
   **`macos-26`** (Xcode 26.4.1 / 26.5 / 26.6 installed; 26.6 is the default) and **not** `macos-15` (stops at
   Xcode 26.3) [S11][S15]. The CI must install the **Metal toolchain** by parsing `Status:` (the exit code lies) [S13].
   Fallback if CI must stay on Xcode 26.3: `mlx-swift-lm` exact `3.31.4` + `mlx-swift` exact `0.31.4` (the user's
   Synapse app ships that pair) [S18].
2. **Anthropic computer use is now a GA client toolset**: `{"type": "computer_toolset_20260801"}`, **no beta header**,
   17 member tools named directly (`left_click`, `screenshot`, …) with `"toolset_name": "computer"`, batches of several
   actions per turn, no display size in the tool (coordinates are in the pixel space of the screenshots you send).
   Claude 5.5-generation models on the Claude API **reject** the older `computer_20251124` / `computer_20250124`
   [S32][S33].
3. **OpenAI's `computer-use-preview` model was shut down on 2026-07-23** [S44]. The GA tool is
   `tools: [{"type": "computer"}]` on the Responses API with `gpt-6.1-sol` (and other current models); each
   `computer_call` now carries a batched `actions[]` array [S40][S41][S43].
4. **Gemini's `gemini-2.5-computer-use-preview-10-2025` was shut down on 2026-07-28** [S49]. Computer use now runs on
   `gemini-3.8-flash` (recommended), `gemini-4-argon`, `gemini-3.5-flash-lite`, `gemini-3-flash-preview`, with a
   desktop environment, new action names (`click`, `type`, `hotkey`, `take_screenshot`, …) and coordinates normalised
   to 0–999 [S46][S47].
5. **ZCore needs no signature change**, but the comments on `NativeToolKind` (`computer_YYYYMMDD`,
   `computer_use_preview`) are stale. The adapters must implement the new wire formats above (see the implementation brief).
6. **llama-server's default port is now 9931**, not 8080. Probe both [S27].
7. **Apple Foundation Models**: macOS 26 is text-only with a 4,096-token context. macOS 27 adds image `Attachment`,
   `PrivateCloudComputeLanguageModel` and custom `LanguageModel` providers, all of which need the macOS 27 SDK
   (Xcode 27, currently a preview runner image) [S24][S15].

---

# Part A: local small models on macOS

## 1. MLX Swift (`mlx-swift-lm`)

### 1.1 Where the libraries live now

| Fact | Value | Source |
|---|---|---|
| Repo for `MLXLLM`, `MLXVLM`, `MLXLMCommon`, `MLXEmbedders` | `https://github.com/ml-explore/mlx-swift-lm` | [S3] |
| `mlx-swift-examples` | Now example apps/tools only. Last tag `2.29.1` (2025-10-16), last push 2026-07-20 | [S14] |
| Latest `mlx-swift-lm` tag | **`3.32.3`** (2026-09-30). Earlier: `3.31.4` (2026-06-30), `3.31.3` (2026-04-15), `2.31.3` (2026-04-01) | [S1] |
| Latest `mlx-swift` tag | **`0.32.3`** (2026-09-30). Earlier: `0.32.2` (09-28), `0.31.6` (07-02), `0.31.5` (06-30), `0.31.4` (06-01) | [S10] |
| `mlx-swift-lm` 3.32.3 products | `MLXLLM`, `MLXVLM`, `MLXLMCommon`, `MLXEmbedders`, `MLXRerankers`, `MLXHuggingFace`, `MLXFoundationModels`, `MLXGuidedGeneration` (+ test helpers) | [S2] |
| 3.32.3 dependencies | `mlx-swift` `.upToNextMinor(from: "0.32.3")`, `swift-syntax` `602.0.0..<604.0.0` (for the `MLXHuggingFace` macros) | [S2] |
| 3.32.3 platforms / tools version | `.macOS(.v14)`, `.iOS(.v17)`; `swift-tools-version: 6.2` | [S2] |
| `mlx-swift` 0.32.3 tools version | `// swift-tools-version: 6.3;(experimentalCGen)` (also 0.31.5, 0.31.6, 0.32.2; 0.31.3 and 0.31.4 are `5.12`) | [S11] |
| Why 0.32.3, not 0.32.2 | 0.32.2 made apps that link mlx-swift **crash on launch on macOS/iOS earlier than 26.4** (SDK issue #491). 0.32.3 fixes it, and mlx-swift-lm 3.32.3 requires it. This matters for our macOS 15 deployment target | [S10][S1] |
| 3.x tokenizer/downloader split | 3.x "decouple[s] from tokenizer and downloader packages". You supply a `Downloader` and a `TokenizerLoader`, either your own adapters or the `MLXHuggingFace` macros backed by `huggingface/swift-huggingface` + `huggingface/swift-transformers` | [S3][S4] |
| HF Swift packages | `swift-huggingface` **1.0.0** (2026-10-09); `swift-transformers` **1.3.5** (2026-10-09) | [S19] |
| `MLXFoundationModels` | Wraps an MLX model as an Apple `FoundationModels.LanguageModel`. **Requires the macOS/iOS/visionOS 27 SDK**. The package trait `FoundationModelsIntegration` is on by default, and with an older SDK the code compiles out. We do not need this product | [S2][S3] |

Notable 3.32.3 changes for us [S1]: Qwen3-VL image memory fix (#455), Qwen3-VL default per-image budget of
**1,280 vision tokens** (#398), Qwen3-VL sRGB preprocessing (#411), tool-call parser hardening and cross-dialect recovery
(#531, #548), rejected tool calls surfaced as `Generation.rejectedToolCall` (#512), tool round-trip fix (#409),
`ChatSession` KV-cache reuse for append-only media turns (#515), cooperative cancellation in prefill (#423), and
Linux build fixes (#321, #483).

### 1.2 Build / CI gotchas (GitHub Actions, no local Mac)

1. **Toolchain.** `mlx-swift` ≥ 0.31.5 declares `swift-tools-version: 6.3`, so it needs **Xcode 26.4 or newer**
   [S11]. (Swift 6.3 ships in Xcode 26.4. The user's Synapse `project.yml` records the same finding: "mlx-swift
   0.31.5+ needs Xcode 26.4 (Swift 6.3); CI's macos-15 has 26.3" [S18].) Runner images [S15]:
   * `macos-15-arm64` (image 20260907): Xcode 26.3, 26.2, 26.1.1, 26.0.1, 16.x. Default is **16.4**. **Too old for 0.32.3.**
   * `macos-26-arm64` (image 20261013, macOS 26.6.2): Xcode **26.6 (default)**, 26.5, 26.4.1, 26.3, …
   * `xcode-27` preview label (macOS 27.0.1): Xcode 27.1 (default), 27.2 RC, 27.0. Needed only for macOS-27-SDK APIs.
2. **Metal shaders.** "SwiftPM (command line) cannot build the Metal shaders so the ultimate build has to be done via
   Xcode", i.e. `xcodebuild` [S12]. `swift build` / `swift test` on Linux cannot exercise MLX. That is why MLX stays
   in the app target, as ARCHITECTURE.md already says.
3. **Metal toolchain component.** The hosted image ships **without** the Metal toolchain. `xcodebuild -showComponent
   MetalToolchain` **exits 0 while printing `Status: uninstalled`**, and the build then dies at the first
   `CompileMetalFile` with "cannot execute tool 'metal'". mlx-swift-lm's own CI parses the status and runs
   `xcodebuild -downloadComponent MetalToolchain` (~839 MB) [S13]. Copy that step (see the implementation brief).
4. **Plugin / macro validation.** mlx-swift-lm's CI builds with `xcodebuild ... -skipPackagePluginValidation` (needed
   since mlx-swift ≥ 0.31.5) [S1][S13]. If we use the `MLXHuggingFace` **macros** (`#huggingFaceLoadModelContainer`,
   `#hubDownloader`, `#huggingFaceTokenizerLoader`) [S4], an unattended `xcodebuild` also needs
   `-skipMacroValidation` (standard Xcode behaviour for package macros, **UNVERIFIED** for this package). The
   recommended path avoids the macros: write the two small adapter structs (§1.4), as Synapse does [S18].
5. **Name collisions.** `MLXLMCommon` defines `ToolSpec` (`typealias ToolSpec = [String: any Sendable]`), `ToolCall`,
   `Tokenizer` and `TokenizerError` [S6]. ZCore also defines `ToolSpec` and `ToolCall`, and swift-transformers defines
   `Tokenizer`. Qualify names (`MLXLMCommon.ToolSpec`, `ZCore.ToolCall`) and keep the `import Tokenizers` in a single
   bridge file, which is Synapse's rule [S18].
6. **Tokenizer class names.** Newer repos name tokenizer classes that swift-transformers 1.3.5 does not list (Qwen3.5's
   `Qwen3_5Tokenizer`, mlx-community's `TokenizersBackend`). Load with `AutoTokenizer.from(modelFolder:strict: false)`
   so it falls back to the BPE described in `tokenizer.json` [S18].
7. **Two copies of MLX.** If the app links MLX **and** a framework that also links MLX, you get two copies in the
   process [S12]. Link MLX only from the app target.
8. `swift-format` and lint pins in mlx-swift-lm are internal to that repo and do not affect consumers [S3].

### 1.3 Sandbox / Mac App Store

* The official multiplatform example apps run **sandboxed**. `MLXChatExample.entitlements` has
  `com.apple.security.app-sandbox`, `com.apple.security.network.client`, `files.user-selected.read-only`,
  `files.downloads.read-write` and `com.apple.developer.kernel.increased-memory-limit`. `LLMEval` and
  `LoRATrainingExample` are similar [S14]. MLX loads its `default.metallib` from the SwiftPM resource bundle
  (`SWIFTPM_BUNDLE "mlx-swift_Cmlx"`, `METAL_PATH "default.metallib"`) [S11], so no special file access is needed.
* `com.apple.developer.kernel.increased-memory-limit` applies to **iOS 15+, iPadOS 15+ and visionOS 2.5 only**, not
  macOS [S17]. A macOS app needs no memory entitlement. (macOS has no per-app jetsam limit. The GPU wired-memory
  ceiling is a system setting that a sandboxed app cannot change, and that part is **UNVERIFIED** today.)
* Needed for Z Computer: `com.apple.security.network.client` (HF downloads and localhost probes, already planned).
  Store weights under Application Support in the container, use an explicit `HubCache(cacheDirectory:)` and set
  `isExcludedFromBackup` [S18].

### 1.4 Loading and generating (3.32.3 API)

API facts used below [S4][S5][S6]:

* Free functions `loadModelContainer(from: any Downloader, using: any TokenizerLoader, configuration:
  ModelConfiguration, useLatest:progressHandler:)` and `loadModel(...)`. They try the **MLXVLM factory first, then
  MLXLLM** (trampolines registered by class name), so linking both lets one call load either kind.
* `LLMModelFactory.shared.loadContainer(from:using:configuration:)` and `VLMModelFactory.shared.loadContainer(...)`.
* `ChatSession(_ model: ModelContainer, instructions:, speculativeDecoding:, generateParameters:, components:,
  processing: = .init(resize: CGSize(width: 512, height: 512)), additionalContext:, tools: [ToolSpec]?, toolDispatch:)`.
  **The default image resize is 512×512, too small for screenshots.** Override `processing`.
* `respond(to:images:videos:audios:)`, `streamResponse(to:...) -> AsyncThrowingStream<String, Error>`,
  `streamDetails(to:...) -> AsyncThrowingStream<Generation, Error>`, plus `streamDetails(to messages:
  [Chat.Message])` to append tool results while keeping the KV cache.
* `Generation` cases: `.chunk(String)`, `.info(GenerateCompletionInfo)`, `.toolCall(ToolCall)`,
  `.rejectedToolCall(RejectedToolCall)`. `ToolCall.function.name` is a `String` and `ToolCall.function.arguments` is
  `[String: JSONValue]`.
* `Chat.Message.system/.user(_:images:videos:audios:)/.assistant(_:toolCalls:)/.tool(_:id:name:)`.
* `UserInput.Image.ciImage(_:)`, `.url(URL)`, `.array(MLXArray)`. `UserInput.Processing(resize:video:audio:minPixels:maxPixels:)`
  (`minPixels`/`maxPixels` override the model's budget per call).
* `GenerateParameters(maxTokens:maxKVSize:kvCache:kvBits:…temperature: 0.6, topP: 1.0, topK: 0, minP: 0,
  repetitionPenalty:…, seed:)`.
* Tool-call dialects parsed natively (`ToolCallFormat`): `json` (Qwen/Hermes `<tool_call>{…}</tool_call>`), `lfm2`,
  `xml_function`, `qwen3_5`, `glm4`, `gemma`, `gemma4`, `kimi_k2`, `minimax_m2`, `atem`, `mistral`, `llama3`
  (`<|python_tag|>`), `gpt_oss` (Harmony). **No Phi-4 dialect**, so Phi-4-mini goes through the text fallback.

Downloader and tokenizer bridge (shape copied from Synapse `HFBridge.swift`, which ships on TestFlight with 3.31.4. The
protocols are the same in 3.32.3 [S4][S18]):

```swift
import Foundation
import HuggingFace      // swift-huggingface 1.0.0
import MLXLMCommon
import Tokenizers       // swift-transformers 1.3.5 — import it ONLY in this file

struct HubDownloader: MLXLMCommon.Downloader {
    let cacheRoot: URL   // e.g. Application Support/ZComputer/Models/hub
    func download(id: String, revision: String?, matching patterns: [String], useLatest: Bool,
                  progressHandler: @Sendable @escaping (Progress) -> Void) async throws -> URL {
        guard let repo = HuggingFace.Repo.ID(rawValue: id) else { throw URLError(.badURL) }
        let client = HubClient(cache: HubCache(cacheDirectory: cacheRoot))
        return try await client.downloadSnapshot(of: repo, revision: revision ?? "main", matching: patterns,
                                                 progressHandler: { @MainActor p in progressHandler(p) })
    }
}

struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        do { return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext) }
        catch Tokenizers.TokenizerError.missingChatTemplate { throw MLXLMCommon.TokenizerError.missingChatTemplate }
    }
}

struct TransformersLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(upstream: try await AutoTokenizer.from(modelFolder: directory, strict: false))
    }
}
```

Text model with tools (agent loop step):

```swift
import MLXLMCommon
import MLXLLM
import MLXVLM   // link both: loadModelContainer tries the VLM factory first

let container = try await loadModelContainer(
    from: HubDownloader(cacheRoot: modelsRoot), using: TransformersLoader(),
    configuration: ModelConfiguration(id: "mlx-community/Qwen3-4B-Instruct-2507-4bit")   // or LLMRegistry.qwen3_4b_4bit
) { progress in print(progress.fractionCompleted) }

// OpenAI-style function dicts. Build these from the neutral JSON schema in the implementation brief.
let tools: [MLXLMCommon.ToolSpec] = [computerToolSpec, shellToolSpec, taskCompleteToolSpec]

let session = ChatSession(
    container,
    instructions: systemPrompt,
    generateParameters: GenerateParameters(maxTokens: 1024, maxKVSize: 16_384, temperature: 0.2),
    tools: tools)

var calls: [MLXLMCommon.ToolCall] = []
for try await event in session.streamDetails(to: "Open a terminal and run uname -a") {
    switch event {
    case .chunk(let text): emitter.textDelta(text)
    case .toolCall(let call): calls.append(call)            // call.function.name / call.function.arguments
    case .rejectedToolCall(let rejected): emitter.note("rejected tool call: \(rejected)")
    case .info(let info): emitter.note("\(info)")
    default: break
    }
}
// Feed results back without re-prefilling the transcript (keeps the KV cache; keep history append-only).
for try await event in session.streamDetails(to: [.tool(#"{"exit_code":0,"stdout":"Linux ..."}"#, id: nil, name: "shell")]) {
    /* same switch */
}
```

Vision model with a screenshot:

```swift
import CoreImage
let vlm = try await VLMModelFactory.shared.loadContainer(
    from: HubDownloader(cacheRoot: modelsRoot), using: TransformersLoader(),
    configuration: ModelConfiguration(id: "mlx-community/Qwen3-VL-4B-Instruct-4bit"))
let vSession = ChatSession(
    vlm,
    instructions: systemPrompt,
    generateParameters: GenerateParameters(maxTokens: 512, temperature: 0.1),
    processing: .init(maxPixels: 1280 * 800),   // default resize is 512x512; screenshots need more
    tools: [computerToolSpec])
let shot = CIImage(data: pngData)!               // screenshot already scaled by ScreenshotScaler
for try await event in vSession.streamDetails(to: "Click the Files icon in the dock.", images: [.ciImage(shot)]) {
    /* .toolCall → translate coordinates (see coordinate conventions in the implementation brief) */
}
```

### 1.5 Small models for an agent (exact HF ids, sizes)

Sizes are the sum of all files in the repo, from the Hugging Face API (`/api/models/<id>?blobs=true`) [S16]. The
"MLX registry constant" column is the `static let` in `LLMRegistry` / `VLMRegistry` at 3.32.3 [S7][S8]. Any other
repo loads with `ModelConfiguration(id:)` if its `model_type` is supported.

| HF repo id | Size | `model_type` | Image input in MLXVLM? | Native tool dialect in MLX | Registry constant |
|---|---|---|---|---|---|
| `mlx-community/Qwen3-0.6B-4bit` | 0.35 GB | qwen3 | no | json | `LLMRegistry.qwen3_0_6b_4bit` |
| `mlx-community/Qwen3-1.7B-4bit` | 0.98 GB | qwen3 | no | json | `LLMRegistry.qwen3_1_7b_4bit` |
| `mlx-community/Qwen3-4B-4bit` (hybrid thinking) | 2.28 GB | qwen3 | no | json | `LLMRegistry.qwen3_4b_4bit` |
| `mlx-community/Qwen3-4B-Instruct-2507-4bit` (non-thinking) | 2.28 GB | qwen3 | no | json | (use `ModelConfiguration(id:)`) |
| `mlx-community/Qwen3.5-0.8B-4bit` | 0.65 GB | qwen3_5 | **yes** (`Qwen3_5ForConditionalGeneration`) | qwen3_5 | — |
| `mlx-community/Qwen3.5-2B-4bit` | 1.75 GB | qwen3_5 | **yes** | qwen3_5 | `LLMRegistry.qwen3_5_2b_4bit` (text path) |
| `mlx-community/Qwen3.5-4B-4bit` | 3.06 GB | qwen3_5 | **yes** | qwen3_5 | — |
| `mlx-community/Llama-3.2-1B-Instruct-4bit` | 0.71 GB | llama | no | llama3 | `LLMRegistry.llama3_2_1B_4bit` |
| `mlx-community/Llama-3.2-3B-Instruct-4bit` | 1.82 GB | llama | no | llama3 | `LLMRegistry.llama3_2_3B_4bit` |
| `mlx-community/Phi-4-mini-instruct-4bit` | 2.18 GB | phi3 (partial rotary supported in `Phi3.swift`) | no | **none** (text fallback) | — |
| `mlx-community/SmolLM3-3B-4bit` | 1.75 GB | smollm3 | no | json, **UNVERIFIED** | `LLMRegistry.smollm3_3b_4bit` |
| `mlx-community/gemma-3-1b-it-qat-4bit` | 0.77 GB | gemma3_text | no | none | `LLMRegistry.gemma3_1B_qat_4bit` |
| `mlx-community/gemma-3n-E2B-it-lm-4bit` | 2.55 GB | gemma3n | **no** (`gemma3n` is not in the VLM type list) | none | `LLMRegistry.gemma3n_E2B_it_lm_4bit` |
| `mlx-community/gemma-3n-E4B-it-lm-4bit` | 3.90 GB | gemma3n | no | none | `LLMRegistry.gemma3n_E4B_it_lm_4bit` |
| `mlx-community/LFM2-1.2B-4bit` | 0.66 GB | lfm2 | no | lfm2 | `LLMRegistry.lfm2_1_2b_4bit` |
| `mlx-community/Qwen3-VL-2B-Instruct-4bit` | 1.80 GB | qwen3_vl | **yes** | json | — |
| `mlx-community/Qwen3-VL-4B-Instruct-4bit` | 3.11 GB | qwen3_vl | **yes** | json | — |
| `lmstudio-community/Qwen3-VL-4B-Instruct-MLX-4bit` | 3.11 GB | qwen3_vl | **yes** | json | `VLMRegistry.qwen3VL4BInstruct4Bit` |
| `mlx-community/Qwen3-VL-8B-Instruct-4bit` | 5.78 GB | qwen3_vl | **yes** | json | — |
| `mlx-community/Qwen2.5-VL-3B-Instruct-4bit` | 3.09 GB | qwen2_5_vl | **yes** | json | `VLMRegistry.qwen2_5VL3BInstruct4Bit` |
| `mlx-community/Qwen2.5-VL-7B-Instruct-4bit` | 5.65 GB | qwen2_5_vl | **yes** | json | — |
| `mlx-community/gemma-3-4b-it-qat-4bit` | 3.03 GB | gemma3 | **yes** | none (gemma dialect exists, but Gemma 3 has no tool tokens: **UNVERIFIED**) | `VLMRegistry.gemma3_4B_qat_4bit` |
| `mlx-community/gemma-4-e2b-it-4bit` | 3.58 GB | gemma4 | **yes** | gemma4 | `VLMRegistry.gemma4_E2B_it_4bit` / `LLMRegistry.gemma4_e2b_it_4bit` |
| `mlx-community/gemma-4-e4b-it-4bit` | 5.18 GB | gemma4 | **yes** | gemma4 | `VLMRegistry.gemma4_E4B_it_4bit` |
| `mlx-community/LFM2.5-VL-1.6B-4bit` | 1.50 GB | lfm2_vl | **yes** | **UNVERIFIED** | `VLMRegistry.lfm2_5_vl_1_6B_4bit` |
| `mlx-community/UI-TARS-1.5-7B-4bit` (GUI-agent fine-tune) | 4.89 GB | qwen2_5_vl | **yes** | own action grammar, not tool calls | — |

VLM `model_type`s registered in MLXVLM 3.32.3 [S8]: `paligemma`, `qwen2_vl`, `qwen2_5_vl`, `qwen3_vl`, `qwen3_vl_moe`,
`qwen3_5`, `qwen3_5_moe`, `idefics3`, `gemma3`, `gemma4`, `gemma4_unified`, `smolvlm`, `fastvlm`, `llava_qwen2`,
`pixtral`, `mistral3`, `lfm2_vl`, `glm_ocr`, `muse_glimmer`.

**Answer to "does MLXVLM support image input for Qwen3-VL / Qwen2.5-VL / Gemma3?" Yes, yes and yes** [S8], with the
exact ids above. Gemma **3n** has no image path in Swift MLX (only the text-only `-lm` repos load).

Grounding coordinates differ by family, and ZAgent must know which applies:

* Qwen3-VL emits **relative coordinates on a 0–1000 grid**. Qwen's own computer-use cookbook declares the tool with
  `display_width_px: 1000, display_height_px: 1000` [S20].
* Qwen2.5-VL / UI-TARS emit absolute pixels in the **resized** image's space (**UNVERIFIED** today; it is the
  convention documented for Qwen2.5-VL in 2025).
* Gemma has no GUI-grounding training (**UNVERIFIED**), so expect poor click accuracy.

Honest expectation: 2–4 B local VLMs can follow simple one-screen instructions and act as a "find the click target"
helper. They are far weaker than cloud models at multi-step computer use. Default to the shell tool when the guest
agent is up.

## 2. llama.cpp in Swift

**Official XCFramework.** Each llama.cpp build publishes `llama-b<N>-xcframework.zip` (iOS, visionOS, tvOS, macOS),
used as a SwiftPM `binaryTarget(url:checksum:)` [S21]. As of 2026-10-27 the newest nightly is **`b11935`**
(`llama-b11935-xcframework.zip`, 68.2 MB, sha256
`814f6034b87d0e35e96d30cd8876187b24936fe6bf4a02d5d3903ce23fdeab36`). llama.cpp now also cuts semver releases:
**`v0.7.0`** (2026-10-15) points to build **`b11669`**, whose xcframework sha256 is
`937891f26734c29c80817cdf8bf59b139c84a9c6fb36a4ad6ce31cceea608e7c` [S21]. The nightly `b*` releases are marked
*prerelease*. You load a GGUF through the C API (`llama_model_load_from_file`, `llama_init_from_model`, …).

* **Tool calling.** The C++ `common/chat` machinery renders tools through each GGUF's Jinja template and parses the
  family's tool-call syntax. Grammar or JSON-schema constrained sampling can force a JSON envelope. llama-server
  enables Jinja by default (`--jinja` default enabled) and supports "OpenAI-style function calling" [S27].
* **Vision.** Needs the separate `mtmd` projector (`--mmproj`) [S27]. Doing vision through the raw C API in Swift is
  real work.

**`mattt/llama.swift`** (`https://github.com/mattt/llama.swift`): re-exports the llama.cpp C API from the official
XCFramework with SwiftPM semver (latest tag `2.10549.0`; `import LlamaSwift`; macOS 13+) [S22]. Same C API, nicer
pinning. No high-level chat or tool layer.

**`LLM.swift`** (`https://github.com/eastriverlee/LLM.swift`, tag **`v3.0.3`**, 2026-07-19, 882 stars):
`LLM(from: URL, template:)` or `LLM(from: HuggingFaceModel("unsloth/Qwen3-0.6B-GGUF", .Q4_K_M))`. It uses the GGUF's
embedded Jinja chat template by default, has `@Generatable` structured output, and has **function calling** via a
`Tool` protocol driven by llama.cpp's `common/chat` ("uses the model's native tool-call format") [S23]. Gotchas: it
pins its own XCFramework (`b10068`) and **depends on `swift-testing` `branch: "main"`** in `Package.swift`, which is
unstable for app CI. The README documents no image input [S23].

**Recommendation:** do not embed llama.cpp in v1. MLX covers in-app inference, and GGUF users already run
Ollama / LM Studio / llama-server, which ZLocal discovers (§4). If GGUF in-process becomes necessary, prefer
`mattt/llama.swift` pinned with `.exact(...)`.

## 3. Apple Foundation Models (`import FoundationModels`)

| API (exact name) | Availability | Notes | Source |
|---|---|---|---|
| `SystemLanguageModel.default` | macOS 26.0+ | On-device Apple Intelligence model | [S24] |
| `.availability` → `SystemLanguageModel.Availability.available` / `.unavailable(UnavailableReason)` | 26.0+ | Reasons: `.appleIntelligenceNotEnabled`, `.deviceNotEligible`, `.modelNotReady`. Also `isAvailable` | [S24] |
| `contextSize` | `@backDeployed(before: macOS 26.4)` | "maximum context size in tokens" | [S24] |
| `tokenCount(for:)` | **macOS 26.4+** | Token count for instructions/prompt | [S24] |
| Context window | 26.x | "Apple's on-device foundation model has a context window of **4096 tokens** per session" (prompts, instructions, tool schemas, tool I/O and responses all count) | [S24] |
| `LanguageModelSession(model:tools:instructions:)`, `init(model:tools:transcript:)` | 26.0+ | `respond(to:options:)`, `respond(to:generating:…)`, `streamResponse(to:…)`, `transcript`, `prewarm(promptPrefix:)`, `isResponding` | [S24] |
| `GenerationOptions(sampling:temperature:maximumResponseTokens:)` (+ `samplingMode`, `toolCallingMode` variants) | 26.0+ | | [S24] |
| `@Generable`, `@Guide(description:)`, `GenerationSchema`, `DynamicGenerationSchema` | 26.0+ | Guided generation | [S24] |
| `protocol Tool<Arguments, Output>: Sendable` with `name`, `description`, `call(arguments:)` | 26.0+ | `Arguments: ConvertibleFromGeneratedContent` (usually `@Generable`), `Output: PromptRepresentable` (usually `String`) | [S24] |
| Errors | 26.0+ | `LanguageModelSession.GenerationError.exceededContextWindowSize`, `.guardrailViolation`, `.rateLimited`, `.refusal`, `.concurrentRequests`, `.assetsUnavailable`, `.unsupportedLanguageOrLocale`, … | [S24] |
| **`Attachment<Content>`** (`init(_:orientation:)`, `init(imageURL:orientation:)`, `label(_:)`) | **macOS 27.0+** | Image input (CGImage, CIImage, CVPixelBuffer, image URLs) | [S24] |
| **`PrivateCloudComputeLanguageModel`** | **macOS 27.0+** | Server model with privacy guarantees; `quotaUsage`; entitlement `com.apple.developer.private-cloud-compute` | [S24] |
| **`protocol LanguageModel`**, `LanguageModelExecutor` | **macOS 27.0+** | Custom providers (`MLXFoundationModels` implements this) | [S24][S3] |

Summary for Z Computer (macOS 15+ deployment, Xcode 26 SDK): FoundationModels is **optional, text-only, 4k-context**,
on-device only, and gated by `#if canImport(FoundationModels)` + `if #available(macOS 26, *)`. It is good for short
tool-using utility tasks (title a task, summarise an episode, classify a shell command). It **cannot drive the screen**
until we build with the macOS 27 SDK and require macOS 27 at runtime for `Attachment`.

```swift
#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, *)
struct GuestShellTool: Tool {
    let name = "shell"
    let description = "Run one bash command inside the user's virtual machine and return its output."
    @Generable
    struct Arguments {
        @Guide(description: "A single bash command line")
        var command: String
    }
    let run: @Sendable (String) async throws -> String
    func call(arguments: Arguments) async throws -> String { try await run(arguments.command) }
}

@available(macOS 26.0, *)
func appleOnDevice(_ prompt: String, run: @escaping @Sendable (String) async throws -> String) async throws -> String {
    let model = SystemLanguageModel.default
    guard case .available = model.availability else {
        throw ZError.unsupported("Apple Intelligence unavailable: \(model.availability)")   // adapt to ZError's real cases
    }
    let session = LanguageModelSession(model: model, tools: [GuestShellTool(run: run)],
                                       instructions: "Be terse. Use the shell tool when you need facts about the VM.")
    do {
        let response = try await session.respond(to: prompt,
                                                 options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 400))
        return response.content
    } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
        return "[context full: start a new session seeded with a summary]"
    }
}
#endif
```

## 4. External local servers (auto-detect + list models)

| Server | Default bind | Liveness probe | List models | Capabilities | Chat endpoint | Source |
|---|---|---|---|---|---|---|
| **Ollama** | `http://localhost:11434` | `GET /api/version` → `{"version":"0.12.6"}` | `GET /api/tags` → `{"models":[{"name","model","modified_at","size","digest","details":{"format","family","families","parameter_size","quantization_level"}}]}` | `POST /api/show {"model":"<name>"}` → `"capabilities":["completion","vision","tools","thinking"]` | native `POST /api/chat` (tools; `images: [base64]` on a message; tool results as `{"role":"tool","tool_name":"…","content":"…"}`), OpenAI-compatible under `/v1`, Anthropic-compatible base URL `http://localhost:11434` | [S25] |
| **LM Studio** ≥ 0.4.0 | `http://localhost:1234` | `GET /api/v1/models` | same → `{"models":[{"type":"llm","key","display_name","architecture","quantization":{"name","bits_per_weight"},"size_bytes","loaded_instances":[…],"max_context_length","format","capabilities":{"vision":bool,"trained_for_tool_use":bool,"reasoning":{…}}}]}` | in the list response | `/v1/chat/completions`, `/v1/responses`, `/v1/messages`, native `/api/v1/chat` | [S26] |
| LM Studio (legacy) | same | `GET /api/v0/models` | `/api/v0/models` (v0 REST, superseded) and OpenAI-shape `GET /v1/models` | — | `/api/v0/chat/completions` | [S26] |
| **llama.cpp `llama-server`** | `http://127.0.0.1:9931` (**current default**); many installs and older builds use `8080` | `GET /health` → 200 `{"status":"ok"}` / 503 `{"error":{"code":503,"message":"Loading model"…}}` (public, no API key) | `GET /v1/models` → `{"object":"list","data":[{"id","architecture":{"input_modalities":[…],"output_modalities":[…]},"meta":{"n_ctx_train","n_params","size",…}}]}` (one element). Router mode: `GET /models` → `{"data":[{"id","path","status":{"value":"loaded"…},"architecture":{…}}]}` | `input_modalities` contains `"image"` for vision | `/v1/chat/completions` (`image_url` parts; tools via Jinja), `/v1/responses`, Anthropic-compatible endpoints | [S27] |
| **Jan** | `http://127.0.0.1:1337`, prefix `/v1` | `GET /v1/models` | OpenAI shape | — | `/v1/chat/completions` | [S28] |
| **vLLM** | `http://localhost:8000` (`port: int = 8000`) | `GET /v1/models` | OpenAI shape | — | `/v1/chat/completions` | [S29] |

Auth: Ollama local needs none. LM Studio needs none unless "Require Authentication" is on, in which case it wants
`Authorization: Bearer <token>` and an unauthenticated probe gets **401**, which still proves the server exists [S26].
llama-server accepts `--api-key`, and `/health` stays public [S27]. Jan uses an optional Bearer key [S28]. A sandboxed
app reaches localhost with `com.apple.security.network.client`.

## 5. On-device embeddings and the vector store

Options:

* **`NLEmbedding.sentenceEmbedding(for: NLLanguage)`**: NaturalLanguage framework, macOS 11+. Returns `NLEmbedding?`
  (nil when a language has no model). `vector(for:)`, `distance(between:and:distanceType:)`, `dimension`,
  `currentSentenceEmbeddingRevision(for:)` [S30]. Zero download, but low quality by 2026 standards. The supported
  language list (commonly reported: English, Spanish, French, German, Italian, Portuguese, Simplified Chinese) and the
  **512-dim** size are **UNVERIFIED** (Apple's page does not list them). Read `dimension` at runtime.
* **`NLContextualEmbedding`**: macOS 14+. BERT-style per-token vectors; you must pool them yourself. Assets download
  via `requestAssets`. Has `maximumSequenceLength` and `languages` [S30]. More plumbing than value for retrieval.
* **MLX embedders (`MLXEmbedders`)**, registry at 3.32.3 [S9]:
  * `bge_micro` (`TaylorAI/bge-micro-v2`), `gte_tiny`, `minilm_l6` (`sentence-transformers/all-MiniLM-L6-v2`),
    `minilm_l12`, `snowflake_xs`, `bge_small` (`BAAI/bge-small-en-v1.5`), `multilingual_e5_small`, `bge_base`,
    `nomic_text_v1`, `nomic_text_v1_5`, `bge_large`, `snowflake_lg`, `bge_m3`, `mixedbread_large`.
  * **`qwen3_embedding` (`mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ`, 0.35 GB [S16])**.
  * `lfm2_embedding_350m[_4bit|_8bit]` (`mlx-community/LFM2.5-Embedding-350M-*`) and LFM2.5-ColBERT variants.
  * Also tiny MLX conversions: `mlx-community/bge-small-en-v1.5-4bit` (0.02 GB), `mlx-community/all-MiniLM-L6-v2-4bit`
    (0.01 GB), `mlx-community/embeddinggemma-300m-4bit` (0.21 GB) [S16].
  * The MLXEmbedders README's sample imports `MLXEmbeddersHuggingFace` / `MLXLMTokenizers`, which are **not**
    products in 3.32.3's `Package.swift` [S2][S9]. Reuse the `Downloader` / `TokenizerLoader` bridge from §1.4.
* **Provider embeddings** (`LLMClient.embed`): best quality, but needs network and a key.
* **Storage:**
  * ZKit already plans its own `CSQLite` wrapper, which is Linux-compatible and has no dependency.
  * Alternatives: `groue/GRDB.swift` **v7.11.1**, `stephencelis/SQLite.swift` **0.17.0** [S31].
  * `jkrukowski/SQLiteVec` **0.0.15** is a Swift package that bundles SQLite with the `sqlite-vec` extension (defines
    `SQLITE_ENABLE_FTS5`, macOS 10.15+) [S31]. `asg017/sqlite-vec` itself is still **alpha** (`v0.1.10-alpha.4`) [S31].

**Recommendation:**

* Keep the planned **own CSQLite wrapper**. Store `Float32` BLOB vectors with `model_id` and `dim` per row, and use
  **FTS5** for keywords.
* Do **brute-force cosine in process** (vDSP on macOS, a plain loop on Linux). That is fine up to ~100k chunks × 1,024
  dims (~400 MB scan worst case; normally far fewer chunks). Fuse vector and keyword results with reciprocal rank
  fusion.
* Default embedder order: provider embeddings when the active provider has them → **MLX `qwen3_embedding`** when the
  user downloaded local models → `NLEmbedder` → `HashingEmbedder`.
* Re-embed lazily when `model_id` changes. Skip sqlite-vec until the library reaches 100k+ items.

---

# Part B: agent and computer-use loop design

## 6. Anthropic (Claude) computer use

### 6.1 Versions, headers, models [S32][S33]

| Tool `type` | Beta header | Accepted by |
|---|---|---|
| **`computer_toolset_20260801`** (GA client toolset) | **none** | Claude API and Claude Models on Google Cloud (Google managed): `claude-fable-5-1`, `claude-mythos-5-1`, `claude-fable-5`, `claude-mythos-5`, `claude-opus-5-5`, `claude-opus-5`, `claude-sonnet-5-5`, `claude-sonnet-5`, `claude-opus-4-8`, `claude-haiku-5-5`. **Claude 5.5 and later accept only this version** on those two platforms |
| `computer_20251124` (beta) | `anthropic-beta: computer-use-2025-11-24` | Fable 5.1, Mythos 5.1, Fable 5, Mythos 5, Opus 5, Sonnet 5, Opus 4.8, Opus 4.7, Opus 4.6, Sonnet 4.6, Opus 4.5. On Amazon Bedrock also Opus/Sonnet/Haiku 5.5 |
| `computer_20250124` (beta) | `anthropic-beta: computer-use-2025-01-24` | Sonnet 4.5 (deprecated), Haiku 4.5, and Opus 4.1 / Sonnet 4 / Opus 4 (retired except on some clouds) |

Companion tools [S33][S34][S35][S36]:

| Tool | `type` and `name` | Header | Input |
|---|---|---|---|
| Bash | `bash_20250124`, name `bash` | none | `{command}` or `{restart: true}`. Your app owns the shell session |
| Text editor | `text_editor_20250728`, name `str_replace_based_edit_tool` | none | `view` / `create` / `str_replace` / `insert`; optional `max_characters`. Use `text_editor_20250124` only for pre-Claude-4 models |
| Memory | `memory_20250818`, name `memory` | none | Client-side commands `view`, `create`, `str_replace`, `insert`, `delete`, `rename` under `/memories`. The API adds a "MEMORY PROTOCOL" system instruction |

All requests use `POST https://api.anthropic.com/v1/messages` with headers `x-api-key`, `anthropic-version: 2023-06-01`
and `content-type: application/json` [S32].

### 6.2 The toolset's 17 members [S32]

Claude calls a member as a `tool_use` block whose `name` is the member and which carries `"toolset_name": "computer"`.
The `input` holds only that member's parameters. There is **no `action` field**.

| Member | Input |
|---|---|
| `screenshot` | `{}` → return an image |
| `zoom` | `region: [x0, y0, x1, y1]` → return that region at full resolution, scaled to fit your usual screenshot size; coordinates stay in full-screenshot space |
| `left_click`, `right_click`, `middle_click`, `double_click`, `triple_click` | `coordinate?: [x, y]` (omitted = current cursor position); `text?`: modifiers held during the click (`shift`, `ctrl`, `alt`, `super`, or `+`-joined such as `ctrl+shift`) |
| `left_click_drag` | `start_coordinate: [x, y]`, `coordinate: [x, y]`, `text?` (modifiers) |
| `mouse_move` | `coordinate: [x, y]` |
| `left_mouse_down`, `left_mouse_up` | `{}` (at the current cursor; move first with `mouse_move`) |
| `cursor_position` | `{}` → answer with text such as `X=512, Y=384` (screenshot pixels) |
| `scroll` | `scroll_direction: "up"/"down"/"left"/"right"`, `scroll_amount` (wheel clicks), `coordinate?`, `text?` (modifiers) |
| `type` | `text` |
| `key` | `text` (key or `+`-combo, such as `"Return"`, `"ctrl+s"`, `"alt+Tab"`), `repeat?` 1–100 (default 1). **Honor `repeat`** |
| `hold_key` | `text`, `duration` (seconds, ≤ 300) |
| `wait` | `duration` (seconds, ≤ 300) |

### 6.3 Wire format and loop rules [S32][S33]

* **Declaration:** `{"type": "computer_toolset_20260801"}` plus optional `"configs": {"<member>": {"enabled": false,
  "defer_loading": false}}`, `cache_control` and `allowed_callers: ["direct"]`.
  * The entry **rejects** `name`, `display_width_px`, `display_height_px`, `display_number` and `enable_zoom`, as well as
    `strict` and `input_examples`.
  * It also rejects a `tool_choice` naming the toolset, and any other tool named `computer` in the same request.
  * All 17 members are enabled by default, including `zoom`. Disable the ones we do not implement (v1: `hold_key`)
    rather than returning errors.
* **Response:** `stop_reason: "tool_use"` with one or more member blocks. Several blocks form a **batch**. Run them
  **in order**, stop at the first failure, and still answer **every** block:
  * Each success gets its normal result.
  * The failed block gets `is_error: true` with a description.
  * Every later block gets `is_error: true` with exactly `Not executed: an earlier computer action in this turn failed.`
  * A request that leaves a `tool_use` unanswered fails with `invalid_request_error`.
* **Result block:**

  ```json
  {"type": "tool_result", "tool_use_id": "toolu_…", "toolset_name": "computer",
   "content": [{"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "iVBORw0…"}}]}
  ```

  Every member result **must echo `"toolset_name": "computer"`**, or it is rejected. Results may contain only `text` and
  `image`. Non-image members answer `[{"type":"text","text":"OK"}]`.
* If the batch didn't end with `screenshot`, attach the current screenshot as an extra `image` block on the last
  result. That saves a round trip.
* Dispatch on the pair (`toolset_name`, `name`).
* To force one action per turn, send `tool_choice: {"type": "auto", "disable_parallel_tool_use": true}`.
* Ask for approval **per block** (a batch can finish a multistep action inside one turn).
* **Coordinates:** "in the pixel space of the full-display screenshots you return, with the origin at the top left".
  Scale back up yourself. On macOS Retina capture (2x), halve or downscale first.
* Overhead: the toolset adds about **4,500 input tokens** (zoom is about 410 of those). Each screenshot costs about
  1,000–1,800 tokens [S32].
* Streaming: each member's `input` arrives as one complete `input_json_delta` [S33].

**Legacy `computer_20251124` (beta, fallback):**

* Declare `{"type": "computer_20251124", "name": "computer", "display_width_px": W, "display_height_px": H,
  "display_number": 1, "enable_zoom": true}` with header `computer-use-2025-11-24`.
* Claude's call is `{"type":"tool_use","name":"computer","input":{"action":"left_click","coordinate":[500,300]}}`. Action
  names and fields match the members above, except `key` has no `repeat`, and `zoom` exists only with `enable_zoom` [S32].
* Results carry no `toolset_name` (it is a plain tool).
* Set `W×H` to the size of the screenshots you send (standard practice; **UNVERIFIED** wording).
* `computer_20250124` is the same without `zoom`.

### 6.4 Claude Agent SDK relevance

* The Claude Agent SDK (Python/TypeScript) runs Claude Code's loop. Its subagent model is a useful design reference
  (§10), but there is **no Swift SDK** [S51].
* The Python/TS SDKs ship beta **computer toolset driver classes** (`BetaAbstractComputerToolset20260801`) that run the
  loop and approval callbacks [S39].
* Z Computer must implement the same loop itself over HTTP in `AnthropicClient` + `NativeComputerBridge`.

## 7. OpenAI computer use

### 7.1 Status [S40][S44][S45]

* `computer-use-preview` / `computer-use-preview-2025-03-11`: **shut down 2026-07-23**. OpenAI's substitute is
  `gpt-5.6-terra`. The `computer_use_preview` tool type remains in the OpenAPI spec as the legacy shape [S43][S44].
* **GA:** `tools: [{"type": "computer"}]` on `POST https://api.openai.com/v1/responses`. Models whose "Supported
  tools" list includes `computer_use` (seen today): **`gpt-6.1-sol`** (used in all guide examples), `gpt-6.1-terra`
  ("precise computer use"), `gpt-6-astra`, `gpt-6-luna`, `gpt-5.4-mini` [S45].
* For GPT-6 Astra, OpenAI "recommend[s] code execution" (the model writes PyAutoGUI/Playwright scripts). "The `computer`
  tool remains supported as an alternative" [S40].
* "Preview" vs "GA" migration table [S41]:
  * model `computer-use-preview` → `gpt-6.1-sol`
  * `{type:"computer_use_preview", display_width, display_height, environment}` → `{type:"computer"}`
  * one `action` per call → batched `actions[]`
  * `truncation:"auto"` required → not necessary

### 7.2 Wire format (from the OpenAPI spec `openai/openai-openapi` v2.3.0 [S43] and the guides [S40][S41])

* **Output item** (`ComputerToolCall`):

  ```json
  {"type": "computer_call", "id": "cu_…", "call_id": "call_002",
   "actions": [{"type": "click", "button": "left", "x": 405, "y": 157},
               {"type": "type", "text": "penguin"}],
   "pending_safety_checks": [], "status": "completed"}
  ```

  `pending_safety_checks` and `status` are required. The schema still allows a single `action` for older items.
  `status: "completed"` means generation finished; you still have to execute the actions.
* **Actions** (`ComputerAction` oneOf, discriminator `type`):

  | `type` | Fields |
  |---|---|
  | `click` | `button` (`left`/`right`/`wheel`/`back`/`forward`), `x`, `y`, `keys?` (held) |
  | `double_click` | `x`, `y`, `keys` (nullable) |
  | `drag` | `path: [{x, y}, …]`, `keys?` |
  | `keypress` | `keys: ["CTRL", "A"]` |
  | `move` | `x`, `y`, `keys?` |
  | `screenshot` | — |
  | `scroll` | `x`, `y`, `scroll_x`, `scroll_y` (pixel distances), `keys?` |
  | `type` | `text` |
  | `wait` | no fields (the official samples wait 2 s) |

  Key names arrive upper-case (`ENTER`/`RETURN`, `ESC`, `CTRL`, `CMD`/`META`, `OPTION`/`ALT`, `ARROWUP`…). Normalise
  them [S41].
* **First turn** may be a lone `screenshot` action. Capture and return it without touching the UI [S40].
* **Return** one `computer_call_output` per call, after executing every action in order:

  ```json
  {"type": "computer_call_output", "call_id": "call_002",
   "output": {"type": "computer_screenshot", "image_url": "data:image/png;base64,…", "detail": "original"},
   "acknowledged_safety_checks": []}
  ```

  Continue with `previous_response_id: <response.id>` and the same `tools`. The loop ends when the response has no
  `computer_call` items [S40][S43].
* **`detail: "original"`** is recommended for computer use. Avoid `high`/`low`. Patch-based inputs are rejected above
  the **30,000-patch** limit. OpenAI observes strong results with **1440×900** and **1600×900** when downscaling, and
  says to remap coordinates [S41].

### 7.3 Safety checks [S42][S43]

* A `computer_call` can carry `pending_safety_checks: [{id, code?, message?}]`. **Do not execute** until a human
  approves.
* Then send the same objects back in `acknowledged_safety_checks` on the `computer_call_output`.
* The official SDK helpers require the approval callback to return **exactly `true`**. A missing or declined callback
  stops the run, and "a model choice or completion message cannot grant approval".
* Codes are free strings in the GA spec. The preview-era values `malicious_instructions` / `irrelevant_domain` /
  `sensitive_domain` are **UNVERIFIED** for GA.

### 7.4 Generic function calling (Chat Completions), the path for OpenAI-compatible providers [S43]

* Request `tools: [{"type": "function", "function": {"name", "description", "parameters": <JSON Schema>, "strict"?}}]`.
* Response `choices[0].message.tool_calls: [{"id", "type": "function", "function": {"name", "arguments": "<JSON
  string>"}}]`.
* Reply `{"role": "tool", "tool_call_id": "…", "content": "…"}`. **Tool messages accept only text** ("For tool
  messages, only type `text` is supported").
* So the screenshot after an action goes in a **following `user` message** with
  `{"type": "image_url", "image_url": {"url": "data:image/png;base64,…", "detail": "high"}}`.

## 8. Google Gemini computer use

### 8.1 Status and models [S46][S49]

* `gemini-2.5-computer-use-preview-10-2025`: released 2025-10-07, **shut down 2026-07-28**, replacement `gemini-3.8-flash`.
* Current models: **`gemini-3.8-flash`** ("recommended model for computer use"), `gemini-4-argon` (most capable),
  `gemini-3.5-flash-lite` (low latency), `gemini-3-flash-preview`.
* Gemini 4 / 3.x add browser + **mobile + desktop** environments, per-action `intent` strings, configurable safety
  policies, and opt-in prompt-injection screening.

### 8.2 Declaration

| API | Tool entry |
|---|---|
| `generateContent` (REST `v1beta/models/{model}:generateContent`, header `x-goog-api-key`) [S47] | `{"computerUse": {"environment": "ENVIRONMENT_DESKTOP", "excludedPredefinedFunctions": ["…"], "enablePromptInjectionDetection": true, "disabledSafetyPolicies": ["DATA_MODIFICATION"]}}` |
| Interactions API (`POST v1beta/interactions`), used by all current guide examples [S46][S48] | `{"type": "computer_use", "environment": "desktop", "excluded_predefined_functions": [...], "enable_prompt_injection_detection": true, "disabled_safety_policies": ["data_modification"]}` |

Further details [S47]:

* `Environment` enum: `ENVIRONMENT_UNSPECIFIED` (defaults to browser), `ENVIRONMENT_BROWSER`, `ENVIRONMENT_MOBILE`,
  `ENVIRONMENT_DESKTOP`.
* `SafetyPolicy` enum: `FINANCIAL_TRANSACTIONS`, `SENSITIVE_DATA_MODIFICATION`, `COMMUNICATION_TOOL`,
  `ACCOUNT_CREATION`, `DATA_MODIFICATION`, `USER_CONSENT_MANAGEMENT`, `LEGAL_TERMS_AND_AGREEMENTS`.
* Custom `functionDeclarations` can sit alongside, and `excludedPredefinedFunctions` removes built-ins.
* **UNVERIFIED:** a live `generateContent` call with `computerUse` on `gemini-3.8-flash`. The REST reference documents
  it, but every guide example uses Interactions.

### 8.3 Desktop actions (`ENVIRONMENT_DESKTOP`) [S46]

All take an `intent: str` too. Coordinates are **normalised integers 0–999**. Denormalise with `px = v / 1000 × width`.

| Function | Args |
|---|---|
| `click`, `double_click`, `triple_click`, `middle_click`, `right_click` | `x`, `y` |
| `mouse_down`, `mouse_up` | `x`, `y` |
| `move` | `x`, `y` |
| `type` | `text`, `press_enter?` (default false). The sample handler also accepts optional `x`, `y` and clicks there first |
| `drag_and_drop` | `start_x`, `start_y`, `end_x`, `end_y` |
| `wait` | `seconds?` (default 1) |
| `press_key` / `key_down` / `key_up` | `key` |
| `hotkey` | `keys: [str]` |
| `take_screenshot` | — |
| `scroll` | `x`, `y`, `direction` (`up`/`down`/`left`/`right`), `magnitude_in_pixels?` (0–999, default 300) |

The browser environment adds `navigate {url}`, `go_back` and `go_forward`. The mobile environment has `open_app`,
`list_apps`, `long_press`, …

### 8.4 Wire format

* **Interactions** [S46][S48]:
  * Response: `{"steps": [{"type": "function_call", "id": "…", "name": "click", "arguments": {"x": 450, "y": 120,
    "intent": "…", "safety_decision"?: {"decision": "require_confirmation", "explanation": "…"}}}]}`.
  * Reply with `previous_interaction_id` and `input: [{"type": "function_result", "name": "click", "call_id": "<id>",
    "result": [{"type": "text", "text": "{\"url\": …}"}, {"type": "image", "data": "<b64>", "mime_type":
    "image/png"}]}]`.
  * Send one `function_result` per executed call.
* **generateContent** [S47][S50]:
  * Calls arrive as `candidates[0].content.parts[].functionCall {id?, name, args}`.
  * Reply in a `user` turn with `functionResponse {id, name, response: {<json>}, parts: [{"inlineData": {"mimeType":
    "image/png", "data": "<b64>"}}]}`. `FunctionResponse.parts` is the multimodal slot.
  * Append the model's `content` to history **verbatim**. Gemini 3 uses thought signatures, which the SDKs "handle
    automatically". Whether a hand-rolled client gets a 400 for dropping them is **UNVERIFIED**, so never strip parts.
* **Safety** [S46]:
  * If `safety_decision.decision == "require_confirmation"`, ask the user. On approval add `"safety_acknowledgement":
    true` to that call's result object. On refusal stop.
  * A blocked action halts.
  * Overrides via `disabledSafetyPolicies` express a preference only, and the model may still require confirmation.
  * Prompt-injection detection (Gemini 3.5 Flash-Lite or later) is opt-in, default `false`.
* Screen size: the guide's examples use **1440×900** [S46].

## 9. Vendor-neutral tools and the no-tool-calling fallback

Design, with the full schemas in the implementation brief:

* One **flat** `computer` function: `action` enum plus optional fields, `additionalProperties: false`. Flat objects
  survive weak models and every OpenAI-compatible provider better than `oneOf`.
* A `shell` function, plus `task_complete` / `ask_user`.
* Coordinates are always in the pixel space of **the last screenshot the model saw**. Local Qwen3-VL instead uses the
  0–1000 grid (per-model setting).
* **No tool calling** (or a provider quirk `noTools`): the system prompt describes the same tools and demands exactly
  one fenced ```` ```json ```` block per turn, `{"tool": "<name>", "arguments": {…}}`.
  * When the provider supports `response_format: {"type": "json_schema"}`, force the envelope with the schema in the
    brief.
  * The lenient parser should accept `name`/`tool`, `arguments`/`args`/`parameters`, `<tool_call>…</tool_call>`,
    `<|python_tag|>{…}` and a bare first balanced `{…}`.
  * Reject more than one call per turn: execute the first and tell the model.
* OpenAI `strict: true` requires every property listed in `required` with `additionalProperties: false`, so a
  flat-with-optionals schema cannot be strict. Leave `strict` off for `computer`, or ship a strict variant whose optional
  fields are typed `["integer","null"]` (**UNVERIFIED** per provider).

## 9a. Screenshot scaling guidance

| Target | Hard limits | Recommended |
|---|---|---|
| Claude high-resolution tier (Opus 4.7 and later, which includes every toolset model) | Long edge ≤ **2,576 px** and ≤ **4,784 visual tokens** = `⌈w/28⌉ × ⌈h/28⌉`. If a request carries **> 20 images**, every image must be ≤ **2,000 px** per side. The API **rejects** oversized toolset images instead of resizing them [S32][S37] | 1280×800 (1,334 visual tokens) or 1440×900 (1,716 tokens), sent unscaled |
| Claude older tier (Haiku 4.5, Sonnet 4.5, …) | ≤ 1,568 px long edge and ≈ 1.15 MP [S32][S37] | `scale = min(1, 1568/longEdge, sqrt(1_150_000/(w·h)))`. 1280×800 fits unscaled; 1440×900 → ≈1356×847 |
| Anthropic general advice | "Avoid resolutions above 1920x1080". 1024×768 / 1280×720 for desktop tasks; 1280×800 / 1366×768 for web [S32] | |
| OpenAI `computer` | `detail: "original"` can still downscale over the model limits. Patch inputs above 30,000 patches are rejected [S41] | 1440×900 or 1600×900; remap coordinates |
| Gemini | Coordinates normalised 0–999, independent of image size [S46] | 1440×900 (guide examples) |
| Local Qwen3-VL (MLX) | MLX default budget 1,280 vision tokens per image (≈1.3 MP at 32 px per token) [S1]. `ChatSession` default resize is 512×512, so override `processing` [S5] | `maxPixels` ≈ 1280×800 |

**Recommendation:**

* VM framebuffer **1280×800** (Retina capture → downscale 2x first). It fits every vendor without scaling and keeps
  coordinates exact.
* Allow 1440×900 as a user option, with `ScreenshotScaler` computing `scale = min(1, maxEdge/longEdge,
  sqrt(maxPixels/(w·h)))` from the per-provider limits above, remembering the factor, and mapping `x_screen = round(x /
  scale)`.
* Clamp to bounds, and return `is_error` text for out-of-bounds coordinates [S32].
* Send PNG for small UI text. JPEG (quality ~80) is acceptable when the PNG exceeds ~1 MB (Anthropic: "consider
  compressing large screenshots") [S32].

## 9b. Context-trimming guidance

1. **Default (all providers):** keep the **last 3 screenshots** as images. Replace older ones with
   `[screenshot omitted: step N]`, pruning **in batches every ~25 turns** rather than every turn, so the prompt prefix
   stays byte-identical and caches keep hitting. Never send more than 20 images unless every image is ≤ 2,000 px per
   side [S32].
2. **Claude 5.5 generation (Fable 5.1, Opus 5.5, Sonnet 5.5, Haiku 5.5):** avoid client-side pruning. Removing an
   earlier screenshot invalidates every later thinking block.
   * Resize to ≤ 2,000 px per side.
   * Use server-side **context editing** `{"context_management": {"edits": [{"type": "clear_tool_uses_20250919",
     "trigger": …, "keep": …, "clear_at_least": …, "exclude_tools": […]}]}}` with header `anthropic-beta:
     context-management-2025-06-27` [S32][S38]. (`clear_thinking_20251015` also exists.)
   * If you must prune, set `prefix_mismatch_behavior: "drop_block"` from then on [S32].
3. **Prompt caching:** one `cache_control` breakpoint after system + tools, plus one on the latest turn's last
   `tool_result`, advanced each turn. Maximum 4 breakpoints [S32].
4. **OpenAI Responses:** continue with `previous_response_id`. The server holds history, so the client sends only the
   new `computer_call_output`. `truncation` is no longer needed with the GA tool [S41]. Using `previous_response_id`
   with `store: false` is **UNVERIFIED**; keep `store` default.
5. **Gemini:** Interactions keeps state via `previous_interaction_id` [S46]. `generateContent` is stateless, so apply
   rule 1 to old `inlineData` parts.
6. **Local MLX models:** context is small (set `maxKVSize`, e.g. 16k) and prefill is expensive. Keep **1** screenshot,
   keep the history append-only so `ChatSession` reuses the KV cache (#515) [S1], and summarise into a fresh session at
   ~70 % of the budget (`ContextManager` already plans this).
7. **Apple FoundationModels (4k):** on `exceededContextWindowSize`, start a new session seeded with the first and last
   transcript entries or a summary, per Apple's guide [S24].
8. **Durable facts** belong in the memory library (§11), not the transcript. Anthropic's long-running-agent guidance
   pairs memory with context clearing and compaction [S36].

## 10. Team mode: patterns and recommendation

What the frameworks do:

* **Claude Agent SDK subagents** [S51]:
  * `agents: {name: AgentDefinition(description, prompt, tools, model, …)}`; the lead invokes them through the
    `Agent` tool.
  * Each subagent has **context isolation**: a fresh conversation where only its final message returns to the
    parent. The parent's history is *not* inherited; the only input is the prompt string.
  * Subagents can run in parallel, and run in the background by default with `status: "async_launched"`.
  * Tools are restricted per agent. Named agents can talk via `SendMessage`.
* **Anthropic multi-agent research system** [S53]:
  * Orchestrator-worker: a lead plans, spawns parallel subagents, and synthesises.
  * Opus-4 lead with Sonnet-4 workers beat single-agent Opus 4 by **90.2 %** on their research eval.
  * Agents use ~4× the tokens of chat, and multi-agent systems **~15×**.
  * The lead stores the plan in external memory. Synchronous fan-out "simplifies coordination" but bottlenecks.
  * Tasks with heavy shared context and tight dependencies (most coding) fit poorly.
* **OpenAI Agents SDK handoffs** [S52]:
  * Handoffs are **tools named `transfer_to_<agent_name>`**. Control moves to the other agent, which by default sees
    the conversation.
  * Customise with `handoff(agent, tool_name_override, on_handoff, input_type, input_filter, is_enabled)`.
* **CrewAI** [S54]: `Process.sequential` (task outputs feed the next task's `context`) or `Process.hierarchical`
  (needs `manager_llm` / `manager_agent`, which delegates and validates).
* **AutoGen is archived.** Microsoft points new users to **Microsoft Agent Framework**: python-1.23.0 and
  dotnet-1.26.0 (Oct 2026), with sequential, concurrent, handoff and group-collaboration workflows, checkpointing and
  human-in-the-loop [S55].

**Recommended design for 2–6 agents sharing one VM** (fits the existing ZTeam plan):

* **Lead / planner (1).** Turns the goal into ≤ 8 tasks on the `TaskBoard` (`todo` / `doing` / `blocked` / `done`,
  assignee, result, `dependsOn`). It assigns tasks, and it alone writes the final report.
* **Workers (1–4).** Each worker is its own `AgentRunner` with an **isolated context**. It receives only the task text,
  the relevant board entries and a memory block, and it returns a **short report** (Claude-subagent style), never its
  transcript.
* **Reviewer (0–1).** Checks each `done` task against its acceptance line (screenshot plus shell evidence) and can
  reopen it.
* **`SurfaceLease`.** One FIFO lease for *input* (mouse and keyboard) per VM, held **per action batch**, not per task,
  with a max hold of ~10 s.
  * Acquiring the lease returns a **fresh screenshot**. If its hash differs from what the agent planned against, the
    agent must re-plan before acting.
  * Screenshots never block.
  * Shell commands run through the guest agent **outside** the input lease with their own concurrency cap (e.g. 2).
    That is a deliberate change from "lease around shell" in ARCHITECTURE.md; GUI-launching commands (`xdg-open`, …)
    should still take the lease.
* **`MessageBus`.** `team_send(to, text)` / `team_inbox()` plus broadcast. Keep messages short, and put state on the
  board, not in chat.
* **Defaults.**
  * Team size 2–3, because tokens scale ~15× [S53].
  * Bounded concurrency, with synchronous fan-out per planning round (simpler, as in [S53]).
  * Per-member step budgets, and a team-wide token and cost budget shown in the UI.
  * Approvals stay per action and are routed to the human regardless of which agent asks.
  * Prefer partitioning work so that only one agent does GUI work and the others do shell or research.

## 11. Memory and personal library: patterns and recommended schema

How the reference systems structure memory:

* **Claude memory tool** `memory_20250818` [S36]:
  * Client-side file operations under `/memories` (`view`, `create`, `str_replace`, `insert`, `delete`, `rename`). No
    beta header.
  * The API injects "ALWAYS VIEW YOUR MEMORY DIRECTORY BEFORE DOING ANYTHING ELSE… ASSUME INTERRUPTION".
  * It pairs with context editing and compaction. Your handler must block path traversal.
* **MemGPT** (arXiv 2310.08560) [S58]: OS-style **virtual context management**. A small main context is paged
  to and from external tiers (recall storage for conversation, archival storage for documents) by function calls.
* **Letta** [S56]:
  * Agent memory lives as `label`/`value` blocks (`persona`, `human`, …) in a git-backed **MemFS**.
  * Files under `system/` are in the system prompt every turn. Everything else appears only as a file tree the agent
    reads on demand.
  * Shared repositories give several agents the same files.
* **Mem0** (arXiv 2504.19413) [S57]: extract candidate facts from each exchange, retrieve similar memories by
  embedding, and let the LLM choose **ADD / UPDATE / DELETE / NOOP** for each fact through a tool call. A graph variant
  also exists.

**Recommended schema** (maps 1:1 onto ZCore `MemoryKind`: `profile`, `fact`, `preference`, `episode`, `document`,
`chunk`):

| Table | Columns | Notes |
|---|---|---|
| `items` | `id UUID PK`, `kind`, `title`, `text`, `tags JSON`, `parent_id`, `source`, `metadata JSON`, `created_at`, `updated_at`, `pinned BOOL`, `confidence REAL` | Profile and preference rows are short key facts. A `document` row holds file metadata; its `chunk` rows (~800 tokens, 15 % overlap) point to it via `parent_id` |
| `embeddings` | `item_id`, `model_id`, `dim`, `vector BLOB(float32)` | Several `model_id`s may coexist during re-embedding |
| `items_fts` | FTS5 over `title`, `text`, `tags` | LIKE fallback where FTS5 is missing (some Linux sqlite builds) |
| `episodes` (or `kind = episode`) | task, outcome, 5-line summary, model, agent, step count, cost | Written by `EpisodeRecorder` at run end |

Per-turn retrieval: `MemoryContextBuilder` injects a block of at most ~600 tokens, built as follows:

1. All `profile` and pinned `preference` items (≤ 200 tokens).
2. The top-k (5) hybrid hits for the task text plus the latest user message (cosine ∪ BM25, reciprocal rank fusion,
   restricted to `fact` / `chunk` / `episode`).
3. The single most similar past `episode` summary.

Writes:

* `memory_save` (agent-initiated).
* A Mem0-style consolidation pass after each run: extract facts, compare with the top-5 similar items, then
  ADD / UPDATE / DELETE / NOOP.
* Explicit user edits in the Library UI always win (`source = "user"`, never auto-deleted).

For Claude models, optionally also expose the native `memory_20250818` tool, backed by the same store with `/memories/<kind>/<title>.md` ↔ `items`. Keep it off by default to avoid two memory interfaces in one prompt.

---

# Implementation brief for the ZAgent and ZLocal coders

Everything below is meant to be copied into code or into `providers.json`. Facts are sourced in the sections above.

## B1. The vendor-neutral tools to ship

### B1.1 `computer` (ToolSpec `name: "computer"`, `native: nil`)

```json
{
  "name": "computer",
  "description": "Operate the virtual machine's screen, mouse and keyboard. Coordinates are pixels in the most recent screenshot you received (origin top-left), unless the system prompt says the 0-1000 grid is used. Every action except 'wait' returns a fresh screenshot. Prefer the shell tool for anything that does not need the GUI.",
  "parameters": {
    "type": "object",
    "properties": {
      "action": {
        "type": "string",
        "enum": ["screenshot", "click", "double_click", "triple_click", "right_click", "middle_click",
                 "mouse_move", "mouse_down", "mouse_up", "drag", "scroll", "type", "key", "wait", "zoom"],
        "description": "What to do."
      },
      "x": {"type": "integer", "minimum": 0, "description": "Target x for click/double_click/triple_click/right_click/middle_click/mouse_move/mouse_down/mouse_up/scroll, and drag start x."},
      "y": {"type": "integer", "minimum": 0, "description": "Target y (same actions as x)."},
      "to_x": {"type": "integer", "minimum": 0, "description": "Drag end x (action=drag)."},
      "to_y": {"type": "integer", "minimum": 0, "description": "Drag end y (action=drag)."},
      "text": {"type": "string", "description": "Literal text to type (action=type). Unicode allowed. Use action=key for Enter/Tab/shortcuts."},
      "keys": {"type": "string", "description": "Key or '+'-joined combination for action=key, xdotool names: 'Return', 'Escape', 'Tab', 'BackSpace', 'ctrl+c', 'ctrl+shift+t', 'super', 'alt+F4', 'Page_Down'."},
      "repeat": {"type": "integer", "minimum": 1, "maximum": 100, "description": "Times to press 'keys' (action=key). Default 1."},
      "modifiers": {"type": "string", "description": "Modifiers held during a click or scroll: 'shift', 'ctrl', 'alt', 'super', or '+'-joined."},
      "direction": {"type": "string", "enum": ["up", "down", "left", "right"], "description": "Scroll direction (action=scroll)."},
      "amount": {"type": "integer", "minimum": 1, "maximum": 30, "description": "Scroll wheel clicks (action=scroll). Default 3."},
      "seconds": {"type": "number", "minimum": 0.1, "maximum": 30, "description": "Pause length (action=wait). Default 1."},
      "region": {"type": "array", "items": {"type": "integer", "minimum": 0}, "minItems": 4, "maxItems": 4,
                 "description": "[x0, y0, x1, y1] to inspect at full resolution (action=zoom)."}
    },
    "required": ["action"],
    "additionalProperties": false
  }
}
```

Execution over `ComputerSurface` (coordinates first mapped `screen = round(v / scale)` and clamped):

| `action` | `ComputerSurface` call |
|---|---|
| `screenshot` | `screenshot()` |
| `click` | `click(x:y:button:.left,count:1)` |
| `double_click` | `click(…, count: 2)` |
| `triple_click` | `click(…, count: 3)` |
| `right_click` | `click(…, button: .right, count: 1)` |
| `middle_click` | `click(…, button: .middle, count: 1)` |
| `mouse_move` | `mouseMove(x:y:)` |
| `mouse_down` / `mouse_up` | `mouseDown/mouseUp(x:y:button:.left)` |
| `drag` | `drag(fromX:fromY:toX:toY:)` |
| `scroll` | `scroll(x:y:dx:dy:)`: `dy = +amount` for down, `-amount` for up; `dx` likewise for right/left. Default point is screen centre |
| `type` | `typeText(text)` |
| `key` | `pressKeys(keys)` × `repeat` |
| `wait` | `Task.sleep` |
| `zoom` | `screenshot()` at full resolution → crop `region` → scale to the normal screenshot size (`ImageResizer`) |

`modifiers` cannot be expressed with today's `ComputerSurface`, which has no key-down/key-up. **Proposal for the
orchestrator:** add `keyDown(_:)`/`keyUp(_:)` (guest agent: `xdotool keydown/keyup`). Until then, return `is_error:
"modifier-click not supported yet"`.

Key-name normalisation to the xdotool names the surface expects:

| Incoming | Canonical |
|---|---|
| `ENTER`, `RETURN`, `Enter` | `Return` |
| `ESC`, `ESCAPE` | `Escape` |
| `BACKSPACE` | `BackSpace` |
| `DEL`, `DELETE` | `Delete` |
| `SPACE` | `space` |
| `TAB` | `Tab` |
| `PAGEUP` / `PAGEDOWN` | `Page_Up` / `Page_Down` |
| `ARROWUP` / `UP`, and so on | `Up` / `Down` / `Left` / `Right` |
| `CTRL`, `CONTROL` | `ctrl` |
| `ALT`, `OPTION` | `alt` |
| `SHIFT` | `shift` |
| `CMD`, `COMMAND`, `META`, `SUPER`, `WIN` | `super` on a Linux guest, `cmd` on a macOS guest |

Normalise case-insensitively. OpenAI's own samples use exactly these upper-case aliases [S41]. Gemini's key spelling
is undocumented, so apply the same alias table (**UNVERIFIED**).

### B1.2 `shell`, `task_complete`, `ask_user`

```json
[
  {"name": "shell",
   "description": "Run one bash command inside the virtual machine through the guest agent (bash -lc). Returns exit_code, stdout, stderr (truncated to 16 kB each). Destructive commands may require user approval.",
   "parameters": {"type": "object",
     "properties": {"command": {"type": "string", "description": "The bash command line."},
                    "timeout_seconds": {"type": "integer", "minimum": 1, "maximum": 600, "description": "Default 60."}},
     "required": ["command"], "additionalProperties": false}},
  {"name": "task_complete",
   "description": "Call exactly once when the task is finished or cannot be finished.",
   "parameters": {"type": "object",
     "properties": {"summary": {"type": "string"}, "success": {"type": "boolean"}},
     "required": ["summary", "success"], "additionalProperties": false}},
  {"name": "ask_user",
   "description": "Ask the human a question when you are blocked or need a decision. The run pauses until they answer.",
   "parameters": {"type": "object",
     "properties": {"question": {"type": "string"}},
     "required": ["question"], "additionalProperties": false}}
]
```

Shell result text (JSON so every model parses it the same way):
`{"exit_code":0,"stdout":"…","stderr":"…","truncated":false,"duration_s":0.4}`.

### B1.3 Fallback for models without tool calling

System-prompt block (append the four schemas above, compacted):

````text
You can act only by replying with exactly ONE fenced JSON block and nothing after it:
```json
{"tool": "<computer|shell|task_complete|ask_user>", "arguments": { ... }}
```
Put any reasoning BEFORE the block, in at most two sentences. Wait for the result before the next action.
````

When the provider supports structured outputs, force the envelope with `response_format: {"type": "json_schema",
"json_schema": {"name": "agent_step", "schema": …}}`:

```json
{
  "type": "object",
  "properties": {
    "thought": {"type": "string", "description": "One or two sentences."},
    "tool": {"type": "string", "enum": ["computer", "shell", "task_complete", "ask_user"]},
    "arguments": {"type": "object"}
  },
  "required": ["tool", "arguments"],
  "additionalProperties": false
}
```

`TextToolCallParser` order:

1. The last ```` ```json ```` fence.
2. Any `<tool_call>…</tool_call>`.
3. `<|python_tag|>{…}`.
4. The first balanced `{…}` in the text.

Accept the keys `tool`/`name` and `arguments`/`args`/`parameters`. If `arguments` arrives as a string, parse it once
more. On failure, send `Could not parse an action. Reply with one fenced JSON block.` and count it as a step. Feed tool
results back as a `user` message: `Result of <tool>: <json>`, plus the screenshot image for vision models.

## B2. Native action → neutral action translation

### B2.1 Anthropic `computer_toolset_20260801` (member `name`, `toolset_name: "computer"`)

Legacy `computer_20251124` / `computer_20250124` use the same table with `name: "computer"` and the member in
`input.action`. They have no `repeat`, and `zoom` exists only with `enable_zoom: true`.

| Native member | Native input | Neutral `computer` call | Result to send back |
|---|---|---|---|
| `screenshot` | `{}` | `screenshot` | image |
| `zoom` | `region:[x0,y0,x1,y1]` | `zoom region` | image |
| `left_click` | `coordinate?`, `text?` (modifiers) | `click x y modifiers` (missing coordinate → tracked cursor position) | `OK` (+ trailing screenshot on the last block of the batch) |
| `right_click` / `middle_click` / `double_click` / `triple_click` | same | `right_click` / `middle_click` / `double_click` / `triple_click` | `OK` |
| `left_click_drag` | `start_coordinate`, `coordinate`, `text?` | `drag x,y = start, to_x,to_y = coordinate` | `OK` |
| `mouse_move` | `coordinate` | `mouse_move` | `OK` |
| `left_mouse_down` / `left_mouse_up` | `{}` | `mouse_down` / `mouse_up` at the tracked cursor | `OK` |
| `cursor_position` | `{}` | none; answer from the tracked cursor, in screenshot space | text `X=…, Y=…` |
| `scroll` | `scroll_direction`, `scroll_amount`, `coordinate?`, `text?` | `scroll direction amount x y modifiers` | `OK` |
| `type` | `text` | `type` | `OK` |
| `key` | `text`, `repeat?` | `key keys=text repeat` | `OK` |
| `hold_key` | `text`, `duration` | not supported in v1. **Disable it** with `"configs": {"hold_key": {"enabled": false}}` | `is_error` if called anyway |
| `wait` | `duration` | `wait seconds=min(duration, 30)` | `OK` |

Batch rules: run in order, stop at the first failure, and answer the rest with `Not executed: an earlier computer
action in this turn failed.` Every result carries `"toolset_name": "computer"`.

Transcript encoding (stateless, no ZCore change): store native member calls as
`ToolCall(name: "computer.<member>")`. `AnthropicClient` splits the prefix back into `name` + `"toolset_name":
"computer"` when it re-encodes `tool_use` / `tool_result` blocks.

### B2.2 OpenAI `computer` (`computer_call.actions[]`, one `call_id` for the whole batch)

| Native action | Fields | Neutral |
|---|---|---|
| `screenshot` | — | `screenshot` |
| `click` | `button: left` | `click x y` (`keys` → `modifiers`) |
| `click` | `button: right` / `wheel` | `right_click` / `middle_click` |
| `click` | `button: back` / `forward` | `key keys="alt+Left"` / `"alt+Right"` (browser semantics) |
| `double_click` | `x y keys` | `double_click` |
| `drag` | `path:[{x,y}…]` | 2 points → `drag`; more points → `mouse_down`(p0), `mouse_move`(p1…pn), `mouse_up`(pn) |
| `move` | `x y` | `mouse_move` |
| `scroll` | `x y scroll_x scroll_y` (pixels) | `scroll x y`, direction from the sign (`scroll_y > 0` = down), `amount = max(1, round(abs(px)/100))` (**UNVERIFIED** px-per-click; tune in the app) |
| `keypress` | `keys:["CTRL","A"]` | `key keys="ctrl+a"` (normalise each, join with `+`) |
| `type` | `text` | `type` |
| `wait` | — | `wait seconds=2` (the official samples sleep 2 s) |

After **all** actions run, send **one** `computer_call_output` with `output.type = "computer_screenshot"`,
`image_url = "data:image/png;base64,…"`, `detail = "original"`, plus `acknowledged_safety_checks` (only after human
approval). If `pending_safety_checks` is non-empty, raise an `ApprovalRequest` **before** executing anything.

### B2.3 Gemini `computerUse` (`ENVIRONMENT_DESKTOP`), coordinates 0–999 → `px = v/1000 × W`

| Native function | Args | Neutral |
|---|---|---|
| `take_screenshot` | — | `screenshot` |
| `click` / `double_click` / `triple_click` / `right_click` / `middle_click` | `x y` | same name |
| `move` | `x y` | `mouse_move` |
| `mouse_down` / `mouse_up` | `x y` | `mouse_down` / `mouse_up` |
| `type` | `text press_enter? [x y]` | if `x`,`y` present: `click x y` first; then `type text`; then `key Return` if `press_enter` |
| `drag_and_drop` | `start_x start_y end_x end_y` | `drag` |
| `scroll` | `x y direction magnitude_in_pixels?=300` | `scroll x y direction amount = max(1, round(magnitude/100))` |
| `press_key` | `key` | `key keys=<normalised>` |
| `hotkey` | `keys:[…]` | `key keys=<normalised, joined with '+'>` |
| `key_down` / `key_up` | `key` | not supported in v1. Declare them in `excludedPredefinedFunctions` |
| `wait` | `seconds?=1` | `wait` |
| `navigate` / `go_back` / `go_forward` (browser env only) | `url` / — | not used with the desktop environment. If they appear: `key "ctrl+l"` + `type url` + `key Return` / `key "alt+Left"` / `key "alt+Right"` |

Show `intent` in the activity feed. Handle `safety_decision.decision == "require_confirmation"` with an
`ApprovalRequest`, and on approval add `"safety_acknowledgement": true` to that call's response object. Send one
function result per call, each with the JSON text (`{"url": …}` is optional on a desktop) and the new screenshot as
inline PNG.

## B3. Native tool declarations to send

| Vendor / API | Declaration | Extra |
|---|---|---|
| Anthropic, current models | `{"type": "computer_toolset_20260801", "configs": {"hold_key": {"enabled": false}}}` (also add `"zoom": {"enabled": false}` until `ImageResizer` crop exists) | No beta header. Optionally `{"type": "bash_20250124", "name": "bash"}` as `NativeToolKind.anthropicBash` → our `shell` |
| Anthropic, Opus 4.5–4.7 / Sonnet 4.6 | `{"type": "computer_20251124", "name": "computer", "display_width_px": W, "display_height_px": H, "display_number": 1}` | Header `anthropic-beta: computer-use-2025-11-24` |
| Anthropic, Haiku 4.5 / Sonnet 4.5 | `{"type": "computer_20250124", "name": "computer", "display_width_px": W, "display_height_px": H, "display_number": 1}` | Header `anthropic-beta: computer-use-2025-01-24` |
| OpenAI Responses | `{"type": "computer"}` | Continue with `previous_response_id` |
| Gemini generateContent | `{"computerUse": {"environment": "ENVIRONMENT_DESKTOP", "excludedPredefinedFunctions": ["key_down", "key_up"]}}` | Plus `functionDeclarations` for `shell`, `task_complete`, `ask_user` |
| Everyone else | `computer` + `shell` + `task_complete` + `ask_user` as plain functions | or the B1.3 text protocol |

## B4. Notes for ZCore / ZProviders (no signature changes required)

* Update the doc comments on `NativeToolKind`:
  * `.anthropicComputer` → "computer_toolset_20260801 (GA) or legacy computer_20251124 / computer_20250124".
  * `.openAIComputer` → "Responses API `computer` tool (GA); computer_use_preview was shut down 2026-07-23".
  * `.geminiComputer` → "generateContent `computerUse` / Interactions `computer_use`".
* Keep the per-model native tool **version string** in `providers.json`, following the "no model strings in Swift"
  rule. Suggested quirk keys:
  * `"anthropicComputerTool": "computer_toolset_20260801" | "computer_20251124" | "computer_20250124"`
  * `"coordinateSpace": "screenshot" | "normalized1000"` (Gemini native, local Qwen3-VL)
  * `"maxImageLongEdge"`, `"maxImagePixels"` or `"maxVisualTokens"`
* `providers.json` model ids to mark `nativeComputerUse`:
  * `anthropicComputer`: the Claude list in §6.1.
  * `openAIComputer`: `gpt-6.1-sol`, `gpt-6.1-terra`, `gpt-6-astra`, `gpt-6-luna`, `gpt-5.4-mini`.
  * `geminiComputer`: `gemini-3.8-flash`, `gemini-4-argon`, `gemini-3.5-flash-lite`, `gemini-3-flash-preview`.
  * **Remove** `computer-use-preview` and `gemini-2.5-computer-use-preview-10-2025` (both shut down).
* Gemini's `FunctionCall.id` is optional. Synthesise a local id, and echo the model's id only when it sent one.
* OpenAI batches map to N neutral `ToolCall`s sharing one `call_id`. `OpenAIResponsesClient` must collapse their
  results back into one `computer_call_output`.

## B5. Recommended MLX pins and CI

Primary (needs the `macos-26` runner; Xcode ≥ 26.4):

```yaml
# project.yml (xcodegen) — app target only; never from ZKit (MLX needs Xcode to compile Metal)
packages:
  mlx-swift:
    url: https://github.com/ml-explore/mlx-swift
    exactVersion: 0.32.3        # fixes the <26.4 launch crash of 0.32.2; tools-version 6.3
  mlx-swift-lm:
    url: https://github.com/ml-explore/mlx-swift-lm
    exactVersion: 3.32.3        # products: MLXLLM, MLXVLM, MLXLMCommon, MLXEmbedders
  swift-huggingface:
    url: https://github.com/huggingface/swift-huggingface
    exactVersion: 1.0.0         # product HuggingFace (HubClient/HubCache) for the Downloader bridge
  swift-transformers:
    url: https://github.com/huggingface/swift-transformers
    exactVersion: 1.3.5         # product Tokenizers for the TokenizerLoader bridge
```

Fallback (only if CI must stay on `macos-15` / Xcode 26.3): `mlx-swift-lm` **exact `3.31.4`** + `mlx-swift` **exact
`0.31.4`** (tools-version 5.12), same HF packages. 3.31.4 itself asks for `upToNextMinor(from: "0.31.4")`, so without the
exact pin SwiftPM resolves 0.31.6, which needs Xcode 26.4. You lose the 3.32 Qwen3-VL memory fixes [S1][S11][S18].

macOS CI job:

```yaml
  macos-app:
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode 26.6
        run: |
          sudo xcode-select -s /Applications/Xcode_26.6.app/Contents/Developer
          xcodebuild -version && swift --version
      - name: Install Metal toolchain (exit code lies; parse Status)
        run: |
          status() { xcodebuild -showComponent MetalToolchain 2>&1 | awk -F': *' '/^Status:/ { print tolower($2); exit }'; }
          [ "$(status)" = "installed" ] || xcodebuild -downloadComponent MetalToolchain
          [ "$(status)" = "installed" ] || { echo "::error::MetalToolchain still '$(status)'"; exit 1; }
      - name: Generate project
        run: brew install xcodegen && xcodegen generate
      - name: Build
        run: >
          xcodebuild build -project ZComputer.xcodeproj -scheme ZComputer
          -destination 'generic/platform=macOS' -skipPackagePluginValidation
          CODE_SIGNING_ALLOWED=NO
```

Add `-skipMacroValidation` only if someone adopts the `MLXHuggingFace` macros. The bridges in §1.4 make them
unnecessary. Cache `~/Library/Developer/Xcode/DerivedData/**/SourcePackages` keyed on `Package.resolved`, because MLX's
C++/Metal build is slow. Entitlements need nothing beyond the existing `network.client`.

## B6. Curated small-model list (`LocalModelCatalog`)

Sizes come from the HF API on 2026-10-27 [S16]. `vision` = MLXVLM can take images [S8]. `tools` = MLX Swift has a
native parser for the family's tool-call dialect [S6]; when `false`, use the text protocol (B1.3). `minRAMGB` is **our
heuristic, not a vendor figure**: the smallest of 8 / 16 / 24 / 32 ≥ `sizeGB × 1.5 + 6` (text) or `+ 8` (vision),
leaving room for macOS plus a running ~4 GB VM.

```json
[
  {"id": "mlx-community/Qwen3-1.7B-4bit", "name": "Qwen3 1.7B", "sizeGB": 0.98, "vision": false, "tools": true, "minRAMGB": 8},
  {"id": "mlx-community/Qwen3-0.6B-4bit", "name": "Qwen3 0.6B", "sizeGB": 0.35, "vision": false, "tools": true, "minRAMGB": 8},
  {"id": "mlx-community/LFM2-1.2B-4bit", "name": "LFM2 1.2B", "sizeGB": 0.66, "vision": false, "tools": true, "minRAMGB": 8},
  {"id": "mlx-community/Qwen3-4B-Instruct-2507-4bit", "name": "Qwen3 4B Instruct 2507", "sizeGB": 2.28, "vision": false, "tools": true, "minRAMGB": 16},
  {"id": "mlx-community/Llama-3.2-3B-Instruct-4bit", "name": "Llama 3.2 3B Instruct", "sizeGB": 1.82, "vision": false, "tools": true, "minRAMGB": 16},
  {"id": "mlx-community/Phi-4-mini-instruct-4bit", "name": "Phi-4 mini instruct", "sizeGB": 2.18, "vision": false, "tools": false, "minRAMGB": 16},
  {"id": "mlx-community/SmolLM3-3B-4bit", "name": "SmolLM3 3B", "sizeGB": 1.75, "vision": false, "tools": false, "minRAMGB": 16},
  {"id": "mlx-community/gemma-3n-E2B-it-lm-4bit", "name": "Gemma 3n E2B (text)", "sizeGB": 2.55, "vision": false, "tools": false, "minRAMGB": 16},
  {"id": "mlx-community/Qwen3-VL-2B-Instruct-4bit", "name": "Qwen3-VL 2B Instruct", "sizeGB": 1.80, "vision": true, "tools": true, "minRAMGB": 16},
  {"id": "mlx-community/Qwen3-VL-4B-Instruct-4bit", "name": "Qwen3-VL 4B Instruct", "sizeGB": 3.11, "vision": true, "tools": true, "minRAMGB": 16},
  {"id": "mlx-community/Qwen3.5-2B-4bit", "name": "Qwen3.5 2B", "sizeGB": 1.75, "vision": true, "tools": true, "minRAMGB": 16},
  {"id": "mlx-community/Qwen3.5-4B-4bit", "name": "Qwen3.5 4B", "sizeGB": 3.06, "vision": true, "tools": true, "minRAMGB": 16},
  {"id": "mlx-community/gemma-4-e2b-it-4bit", "name": "Gemma 4 E2B", "sizeGB": 3.58, "vision": true, "tools": true, "minRAMGB": 16},
  {"id": "mlx-community/gemma-3-4b-it-qat-4bit", "name": "Gemma 3 4B (QAT)", "sizeGB": 3.03, "vision": true, "tools": false, "minRAMGB": 16},
  {"id": "mlx-community/LFM2.5-VL-1.6B-4bit", "name": "LFM2.5-VL 1.6B", "sizeGB": 1.50, "vision": true, "tools": false, "minRAMGB": 16},
  {"id": "mlx-community/UI-TARS-1.5-7B-4bit", "name": "UI-TARS 1.5 7B (GUI agent)", "sizeGB": 4.89, "vision": true, "tools": false, "minRAMGB": 16},
  {"id": "mlx-community/Qwen3-VL-8B-Instruct-4bit", "name": "Qwen3-VL 8B Instruct", "sizeGB": 5.78, "vision": true, "tools": true, "minRAMGB": 24}
]
```

Defaults:

* Text: `Qwen3-1.7B-4bit` (8 GB Macs) or `Qwen3-4B-Instruct-2507-4bit` (16 GB+).
* Screen (vision): `Qwen3-VL-4B-Instruct-4bit`, with `coordinateSpace = normalized1000` [S20]. Qwen3.5 2B/4B are newer
  natively multimodal alternatives worth an A/B.
* UI-TARS and Qwen2.5-VL use absolute pixels in the resized image (**UNVERIFIED**). UI-TARS also uses its own action
  grammar, so it needs a dedicated parser before shipping. Keep it hidden behind "experimental".

Embedders (same shape, for the Library settings) [S9][S16]:

```json
[
  {"id": "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ", "name": "Qwen3 Embedding 0.6B", "sizeGB": 0.35, "vision": false, "tools": false, "minRAMGB": 8},
  {"id": "mlx-community/LFM2.5-Embedding-350M-4bit", "name": "LFM2.5 Embedding 350M", "sizeGB": 0.20, "vision": false, "tools": false, "minRAMGB": 8},
  {"id": "BAAI/bge-small-en-v1.5", "name": "BGE small en v1.5", "sizeGB": 0.13, "vision": false, "tools": false, "minRAMGB": 8}
]
```

`BAAI/bge-small-en-v1.5`: the repo totals 0.40 GB, but the downloader fetches only the 0.13 GB of safetensors and JSON
it matches. MLXEmbedders model types at 3.32.3: `bert`, `roberta`, `distilbert`, `nomic_bert`, `qwen3`, `lfm2`,
`gemma3`, `gemma3_text`, `gemma3n` [S9].

## B7. Local-server probe table (`LocalServerDiscovery.scan()`)

Probe all hosts concurrently with a ~400 ms timeout each, `127.0.0.1` only. Identify a server **by response shape**,
never by port alone, because 8000 and 8080 are common dev ports.

| # | host:port | Probe (GET unless noted) | Identify by | List models | Model fields to map → `ModelInfo` | Client to build |
|---|---|---|---|---|---|---|
| 1 | `127.0.0.1:11434` | `/api/version` | `{"version": "<semver>"}` | `GET /api/tags` → `models[]` | `name` → id; `details.parameter_size`, `details.quantization_level`, `size`. Then `POST /api/show {"model": name}` → `capabilities` ∋ `"vision"` / `"tools"` | `OllamaClient` (`/api/chat`), apiStyle `ollama` |
| 2 | `127.0.0.1:1234` | `/api/v1/models` | `{"models": [{"type", "key", "capabilities": {...}}]}`; **401** = LM Studio with auth on (ask for token) | same | `key` → id; `display_name`; `capabilities.vision`; `capabilities.trained_for_tool_use`; `max_context_length`; skip `type != "llm"` | `OpenAIChatClient` base `http://127.0.0.1:1234/v1` |
| 2b | `127.0.0.1:1234` | `/api/v0/models`, then `/v1/models` | legacy LM Studio (< 0.4): `{"data": [...]}` (v0 field names **UNVERIFIED**) | same | `id` | same |
| 3 | `127.0.0.1:9931`, then `127.0.0.1:8080` | `/health` | `{"status": "ok"}` (200), or 503 `{"error": {"message": "Loading model", "type": "unavailable_error"}}` | `GET /v1/models` (single model); router mode `GET /models` (`status.value`: `loaded`, …) | `id` (path or `--alias`); `architecture.input_modalities` ∋ `"image"` → vision; `meta.n_ctx_train` → context; tools assumed (Jinja on by default) | `OpenAIChatClient` base `http://host:port/v1` |
| 4 | `127.0.0.1:1337` | `/v1/models` | OpenAI list `{"object": "list", "data": [{"id"}]}`; 401 = key required | same | `id` | `OpenAIChatClient` base `http://127.0.0.1:1337/v1` |
| 5 | `127.0.0.1:8000` | `/v1/models` | OpenAI list (vLLM puts `owned_by: "vllm"`, **UNVERIFIED**) | same | `id`, `max_model_len` (**UNVERIFIED** field) | `OpenAIChatClient` base `http://127.0.0.1:8000/v1` |

Re-scan on app launch, when Settings ▸ Local models opens, and on a manual Refresh. Never scan non-loopback hosts
without a user-entered URL.

## B8. Not verified today (do these on the first macOS CI run / with live keys)

1. A real `xcodebuild` of mlx-swift-lm **3.32.3** + mlx-swift **0.32.3** on `macos-26` / Xcode 26.6 with a
   **macOS 15** deployment target. Also confirm the app does not crash at launch on macOS 15 (0.32.3's fix targets
   exactly that).
2. That the `MLXFoundationModels` trait does not break a Xcode 26 build when we do not link that product (docs say it
   compiles out).
3. The Swift snippets (MLX, FoundationModels) compile as written. Note the `ToolSpec` / `ToolCall` / `Tokenizer` name
   collisions.
4. Phi-4-mini and SmolLM3 tool calling in MLX Swift. The catalogue marks them `tools: false`.
5. Gemini `computerUse` via **generateContent** (not Interactions) on `gemini-3.8-flash`; whether dropping thought
   signatures causes a 400; Gemini key-name spelling.
6. OpenAI `pending_safety_checks` code values for the GA tool; `previous_response_id` with `store: false`;
   px-per-wheel-click for `scroll`.
7. NLEmbedding sentence-embedding dimension (512?) and language list.
8. Qwen2.5-VL / UI-TARS absolute-pixel coordinate convention; Gemma's GUI-grounding ability.
9. llama-server's port-change date (9931 vs 8080). Probe both regardless.
10. Legacy `computer_20251124` coordinate frame wording (we assume `display_*_px` = screenshot size).

---

## Sources

All seen **2026-10-27** (fetched with `gh`/curl/HTTP from this machine) unless marked otherwise.

| Tag | Source |
|---|---|
| S1 | mlx-swift-lm releases (3.32.3, 3.31.4 notes): https://github.com/ml-explore/mlx-swift-lm/releases, https://github.com/ml-explore/mlx-swift-lm/releases/tag/3.32.3, https://github.com/ml-explore/mlx-swift-lm/releases/tag/3.31.4 |
| S2 | mlx-swift-lm Package.swift @3.32.3 / @3.31.4: https://github.com/ml-explore/mlx-swift-lm/blob/3.32.3/Package.swift, https://github.com/ml-explore/mlx-swift-lm/blob/3.31.4/Package.swift |
| S3 | mlx-swift-lm README @3.32.3: https://github.com/ml-explore/mlx-swift-lm/blob/3.32.3/README.md |
| S4 | Using mlx-swift-lm (downloaders/tokenizers, macros): https://github.com/ml-explore/mlx-swift-lm/blob/3.32.3/Libraries/MLXLMCommon/Documentation.docc/using.md |
| S5 | ChatSession @3.32.3: https://github.com/ml-explore/mlx-swift-lm/blob/3.32.3/Libraries/MLXLMCommon/ChatSession.swift |
| S6 | MLXLMCommon @3.32.3: `UserInput.swift`, `Chat.swift`, `Evaluate.swift`, `ModelContainer.swift`, `ModelFactory.swift`, `Tool/Tool.swift`, `Tool/ToolCall.swift`, `Tool/ToolCallFormat.swift` under https://github.com/ml-explore/mlx-swift-lm/tree/3.32.3/Libraries/MLXLMCommon |
| S7 | LLM registry: https://github.com/ml-explore/mlx-swift-lm/blob/3.32.3/Libraries/MLXLLM/LLMModelFactory.swift (+ `Models/Phi3.swift`) |
| S8 | VLM registry and model types: https://github.com/ml-explore/mlx-swift-lm/blob/3.32.3/Libraries/MLXVLM/VLMModelFactory.swift |
| S9 | MLXEmbedders: https://github.com/ml-explore/mlx-swift-lm/blob/3.32.3/Libraries/MLXEmbedders/ModelFactory.swift and `README.md` |
| S10 | mlx-swift releases 0.32.3 / 0.32.2: https://github.com/ml-explore/mlx-swift/releases/tag/0.32.3, https://github.com/ml-explore/mlx-swift/releases/tag/0.32.2 |
| S11 | mlx-swift Package.swift @0.32.3 (and first line of @0.31.3, 0.31.4, 0.31.5, 0.31.6, 0.32.2): https://github.com/ml-explore/mlx-swift/blob/0.32.3/Package.swift |
| S12 | mlx-swift README @0.32.3 (SwiftPM cannot build Metal shaders; two-copies warning): https://github.com/ml-explore/mlx-swift/blob/0.32.3/README.md |
| S13 | mlx-swift-lm PR #538 and CI workflow (MetalToolchain status parsing, `-skipPackagePluginValidation`): https://github.com/ml-explore/mlx-swift-lm/pull/538, https://github.com/ml-explore/mlx-swift-lm/blob/main/.github/workflows/pull_request.yml |
| S14 | mlx-swift-examples releases and app entitlements: https://github.com/ml-explore/mlx-swift-examples/releases, https://github.com/ml-explore/mlx-swift-examples/blob/main/Applications/MLXChatExample/MLXChatExample.entitlements (+ LLMEval, LoRATrainingExample, LLMBasic) |
| S15 | GitHub runner images: https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md (image 20260907), https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md (image 20261013), https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md (image 20261022) |
| S16 | Hugging Face model API (sizes, model_type): `https://huggingface.co/api/models/<repo-id>?blobs=true` for every repo listed in §1.5, §5 and B6 |
| S17 | Apple entitlement `com.apple.developer.kernel.increased-memory-limit` (iOS/iPadOS 15+, visionOS 2.5+): https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit |
| S18 | The user's Synapse app (local, read 2026-10-27): `C:/Users/evera/Projects/synapse/project.yml` (MLX pins + Xcode 26.4 note), `Synapse/Views/AI/HFBridge.swift` (Downloader/Tokenizer bridges), `.github/workflows/ci.yml` (`-downloadComponent MetalToolchain`) |
| S19 | https://github.com/huggingface/swift-huggingface/releases (1.0.0), https://github.com/huggingface/swift-transformers/releases (1.3.5) |
| S20 | Qwen3-VL computer-use cookbook (`display_width_px: 1000`): https://github.com/QwenLM/Qwen3-VL/blob/main/cookbooks/computer_use.ipynb; README: https://github.com/QwenLM/Qwen3-VL |
| S21 | llama.cpp XCFramework doc and releases: https://github.com/ggml-org/llama.cpp/blob/master/docs/xcframework.md, https://github.com/ggml-org/llama.cpp/releases/tag/b11935, https://github.com/ggml-org/llama.cpp/releases/tag/v0.7.0, https://github.com/ggml-org/llama.cpp/releases/tag/b11669 |
| S22 | https://github.com/mattt/llama.swift (README, tags) |
| S23 | https://github.com/eastriverlee/LLM.swift (README, tag v3.0.3, Package.swift) |
| S24 | Apple Foundation Models docs: https://developer.apple.com/documentation/foundationmodels, …/languagemodelsession, …/systemlanguagemodel, …/systemlanguagemodel/availability-swift.enum/unavailablereason, …/systemlanguagemodel/contextsize, …/systemlanguagemodel/tokencount(for:), …/tool, …/generationoptions, …/languagemodelsession/generationerror, …/attachment, …/privatecloudcomputelanguagemodel, …/languagemodel, …/managing-the-context-window, …/analyzing-images-with-multimodal-prompting |
| S25 | Ollama docs: https://docs.ollama.com/api/introduction, https://docs.ollama.com/api/tags, https://docs.ollama.com/api/chat, https://docs.ollama.com/api-reference/show-model-details, https://docs.ollama.com/api-reference/get-version, https://docs.ollama.com/capabilities/tool-calling |
| S26 | LM Studio docs: https://lmstudio.ai/docs/developer/rest, https://lmstudio.ai/docs/developer/rest/list, https://lmstudio.ai/docs/developer/rest/endpoints, https://lmstudio.ai/docs/developer/openai-compat, https://lmstudio.ai/docs/developer/core/authentication |
| S27 | llama-server README and defaults: https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md, https://github.com/ggml-org/llama.cpp/blob/master/common/common.h (`int32_t port = 9931;`) |
| S28 | Jan local API server: https://github.com/janhq/jan/blob/main/docs/src/pages/docs/desktop/api-server.mdx |
| S29 | vLLM default port: https://github.com/vllm-project/vllm/blob/main/vllm/entrypoints/common/cli_args.py |
| S30 | NaturalLanguage: https://developer.apple.com/documentation/naturallanguage/nlembedding, https://developer.apple.com/documentation/naturallanguage/nlembedding/sentenceembedding(for:), https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding |
| S31 | https://github.com/groue/GRDB.swift/releases (v7.11.1), https://github.com/stephencelis/SQLite.swift/releases (0.17.0), https://github.com/jkrukowski/SQLiteVec (0.0.15, Package.swift), https://github.com/asg017/sqlite-vec/releases (v0.1.10-alpha.4) |
| S32 | Anthropic computer use tool: https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool (markdown fetched 2026-10-27; frontmatter status `ga`) |
| S33 | Anthropic tool reference / client toolsets: https://platform.claude.com/docs/en/agents-and-tools/tool-use/tool-reference |
| S34 | Bash tool: https://platform.claude.com/docs/en/agents-and-tools/tool-use/bash-tool |
| S35 | Text editor tool: https://platform.claude.com/docs/en/agents-and-tools/tool-use/text-editor-tool |
| S36 | Memory tool: https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool |
| S37 | Vision limits: https://platform.claude.com/docs/en/build-with-claude/vision |
| S38 | Context editing: https://platform.claude.com/docs/en/build-with-claude/context-editing |
| S39 | SDK browser/computer toolsets: https://platform.claude.com/docs/en/agents-and-tools/tool-use/browser-use-sdk |
| S40 | OpenAI computer use guide: https://developers.openai.com/api/docs/guides/tools-computer-use |
| S41 | OpenAI computer use integration recipes (actions, screenshots, migration from preview): https://developers.openai.com/api/docs/guides/tools-computer-use-integration |
| S42 | OpenAI browser and desktop drivers (safety-check approval): https://developers.openai.com/api/docs/guides/tools-computer-use-sdk-drivers |
| S43 | OpenAI OpenAPI spec v2.3.0 (`ComputerTool`, `ComputerToolCall`, `ComputerAction`, `ComputerCallOutputItemParam`, `ComputerCallSafetyCheckParam`, `ComputerUsePreviewTool`, `ChatCompletionRequestToolMessage`): https://github.com/openai/openai-openapi (openapi.yaml; local copy downloaded 2026-10-27) |
| S44 | OpenAI deprecations (computer-use-preview shutdown 2026-07-23): https://developers.openai.com/api/docs/deprecations |
| S45 | OpenAI models: https://developers.openai.com/api/docs/models, https://developers.openai.com/api/docs/models/gpt-6.1-sol, …/gpt-6.1-terra, …/gpt-6-astra, …/gpt-6-luna, …/gpt-5.4-mini |
| S46 | Gemini computer use: https://ai.google.dev/gemini-api/docs/computer-use |
| S47 | Gemini generateContent reference (`ComputerUse`, `Environment`, `SafetyPolicy`, `FunctionCall`, `FunctionResponse`, `FunctionResponsePart`): https://ai.google.dev/api/generate-content |
| S48 | Gemini Interactions reference: https://ai.google.dev/api/interactions |
| S49 | Gemini deprecations (gemini-2.5-computer-use-preview-10-2025 shutdown 2026-07-28): https://ai.google.dev/gemini-api/docs/deprecations |
| S50 | Gemini function calling (thought signatures, multimodal function responses): https://ai.google.dev/gemini-api/docs/function-calling |
| S51 | Claude Agent SDK subagents: https://code.claude.com/docs/en/agent-sdk/subagents |
| S52 | OpenAI Agents SDK handoffs: https://openai.github.io/openai-agents-python/handoffs/ |
| S53 | Anthropic, "How we built our multi-agent research system": https://www.anthropic.com/engineering/multi-agent-research-system |
| S54 | CrewAI processes: https://docs.crewai.com/en/concepts/processes |
| S55 | AutoGen (archived) and Microsoft Agent Framework: https://github.com/microsoft/autogen, https://github.com/microsoft/agent-framework (releases python-1.23.0, dotnet-1.26.0) |
| S56 | Letta memory: https://docs.letta.com/agent-sdk/memory/index.md |
| S57 | Mem0 paper: https://arxiv.org/abs/2504.19413 (ADD/UPDATE/DELETE/NOOP from https://arxiv.org/html/2504.19413) |
| S58 | MemGPT paper: https://arxiv.org/abs/2310.08560 |
