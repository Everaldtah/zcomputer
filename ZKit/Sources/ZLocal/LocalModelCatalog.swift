import Foundation
import ZCore

/// Chat model or embedder.
public enum LocalModelKind: String, Codable, Sendable, Hashable {
    case chat
    case embedding
}

/// How a vision model reports click coordinates (ZAgent converts them to screenshot pixels).
public enum LocalCoordinateSpace: String, Codable, Sendable, Hashable {
    /// 0–1000 relative grid on both axes (Qwen3-VL; Qwen's computer-use cookbook declares a 1000×1000 display).
    case normalized1000
    /// Absolute pixels of the image the model was given (Qwen2.5-VL / UI-TARS convention, UNVERIFIED).
    case imagePixels
}

/// One curated in-app MLX model (Hugging Face repo id + facts from docs/research/local-models-and-agent-loops.md B6).
public struct LocalModelSpec: Sendable, Hashable, Codable, Identifiable {
    /// Hugging Face repo id, e.g. `mlx-community/Qwen3-4B-Instruct-2507-4bit`.
    public var id: String
    public var name: String
    /// Download size (sum of the files the downloader fetches), in GB (10^9 bytes).
    public var sizeGB: Double
    /// MLXVLM can feed it images.
    public var vision: Bool
    /// MLX Swift has a native parser for the family's tool-call dialect; when false use the text protocol.
    public var tools: Bool
    /// Our heuristic: smallest of 8/16/24/32 ≥ sizeGB × 1.5 + 6 (text) or + 8 (vision), leaving room for a ~4 GB VM.
    public var minRAMGB: Int
    /// HF `model_type` (`qwen3`, `qwen3_vl`, `gemma4`, ...).
    public var family: String
    /// Quantisation of the weights (`4bit`, `4bit-qat`, `4bit-dwq`, `fp32`).
    public var quantization: String
    public var notes: String?
    public var kind: LocalModelKind
    /// Curated rank, 1 = first pick. `recommended(forRAMGB:)` sorts by it.
    public var priority: Int
    /// Coordinate convention for GUI grounding (vision models only).
    public var coordinateSpace: LocalCoordinateSpace?
    /// Hidden unless the user opts into experimental models (needs a dedicated parser, e.g. UI-TARS).
    public var experimental: Bool

    public init(id: String, name: String, sizeGB: Double, vision: Bool, tools: Bool, minRAMGB: Int, family: String,
                quantization: String, notes: String? = nil, kind: LocalModelKind = .chat, priority: Int,
                coordinateSpace: LocalCoordinateSpace? = nil, experimental: Bool = false) {
        self.id = id; self.name = name; self.sizeGB = sizeGB; self.vision = vision; self.tools = tools
        self.minRAMGB = minRAMGB; self.family = family; self.quantization = quantization; self.notes = notes
        self.kind = kind; self.priority = priority; self.coordinateSpace = coordinateSpace; self.experimental = experimental
    }

    /// Download size in bytes.
    public var sizeBytes: Int64 { Int64((sizeGB * 1_000_000_000).rounded()) }

    /// `"mlx-community"` for `"mlx-community/Qwen3-1.7B-4bit"`.
    public var organization: String { id.split(separator: "/").first.map(String.init) ?? id }
    /// `"Qwen3-1.7B-4bit"` for `"mlx-community/Qwen3-1.7B-4bit"`.
    public var repository: String { id.split(separator: "/").last.map(String.init) ?? id }

    /// As a ZCore model (provider id `LocalModelCatalog.providerID`).
    public var modelInfo: ModelInfo {
        ModelInfo(id: id, displayName: name,
                  capabilities: ModelCapabilities(vision: vision, tools: tools, streaming: true),
                  free: true, notes: notes)
    }

    public var modelRef: ModelRef { ModelRef(provider: LocalModelCatalog.providerID, model: id) }
}

/// Curated small models for in-app MLX inference, plus embedders. Embedded in code (no resource file) so the
/// app target and tests read the same list.
public enum LocalModelCatalog {
    /// Provider id the app registers its in-process MLX client under.
    public static let providerID: ProviderID = "mlx"

    /// RAM tiers used by `minRAMGB`.
    public static let ramTiers: [Int] = [8, 16, 24, 32]

    /// `model_type`s MLXVLM 3.32.3 registers (image input). Every `vision` model's `family` is one of these.
    public static let visionFamilies: Set<String> = [
        "paligemma", "qwen2_vl", "qwen2_5_vl", "qwen3_vl", "qwen3_vl_moe", "qwen3_5", "qwen3_5_moe", "idefics3",
        "gemma3", "gemma4", "gemma4_unified", "smolvlm", "fastvlm", "llava_qwen2", "pixtral", "mistral3", "lfm2_vl",
        "glm_ocr", "muse_glimmer",
    ]

    /// MLXEmbedders 3.32.3 model types.
    public static let embedderFamilies: Set<String> = [
        "bert", "roberta", "distilbert", "nomic_bert", "qwen3", "lfm2", "gemma3", "gemma3_text", "gemma3n",
    ]

    /// Chat models (B6), sizes from the Hugging Face API on 2026-10-27.
    public static let models: [LocalModelSpec] = [
        LocalModelSpec(id: "mlx-community/Qwen3-1.7B-4bit", name: "Qwen3 1.7B", sizeGB: 0.98, vision: false, tools: true,
                       minRAMGB: 8, family: "qwen3", quantization: "4bit",
                       notes: "Default text model on 8 GB Macs. Hybrid thinking.", priority: 3),
        LocalModelSpec(id: "mlx-community/Qwen3-0.6B-4bit", name: "Qwen3 0.6B", sizeGB: 0.35, vision: false, tools: true,
                       minRAMGB: 8, family: "qwen3", quantization: "4bit",
                       notes: "Tiny; utility tasks only.", priority: 11),
        LocalModelSpec(id: "mlx-community/LFM2-1.2B-4bit", name: "LFM2 1.2B", sizeGB: 0.66, vision: false, tools: true,
                       minRAMGB: 8, family: "lfm2", quantization: "4bit",
                       notes: "Fast small model with the lfm2 tool dialect.", priority: 10),
        LocalModelSpec(id: "mlx-community/Qwen3-4B-Instruct-2507-4bit", name: "Qwen3 4B Instruct 2507", sizeGB: 2.28,
                       vision: false, tools: true, minRAMGB: 16, family: "qwen3", quantization: "4bit",
                       notes: "Default text model on 16 GB+ Macs. Non-thinking.", priority: 1),
        LocalModelSpec(id: "mlx-community/Llama-3.2-3B-Instruct-4bit", name: "Llama 3.2 3B Instruct", sizeGB: 1.82,
                       vision: false, tools: true, minRAMGB: 16, family: "llama", quantization: "4bit",
                       notes: "llama3 tool dialect.", priority: 9),
        LocalModelSpec(id: "mlx-community/Phi-4-mini-instruct-4bit", name: "Phi-4 mini instruct", sizeGB: 2.18,
                       vision: false, tools: false, minRAMGB: 16, family: "phi3", quantization: "4bit",
                       notes: "No Phi-4 tool dialect in MLX Swift: uses the text tool protocol.", priority: 13),
        LocalModelSpec(id: "mlx-community/SmolLM3-3B-4bit", name: "SmolLM3 3B", sizeGB: 1.75, vision: false, tools: false,
                       minRAMGB: 16, family: "smollm3", quantization: "4bit",
                       notes: "Tool calling unverified in MLX Swift: uses the text tool protocol.", priority: 12),
        LocalModelSpec(id: "mlx-community/gemma-3n-E2B-it-lm-4bit", name: "Gemma 3n E2B (text)", sizeGB: 2.55,
                       vision: false, tools: false, minRAMGB: 16, family: "gemma3n", quantization: "4bit",
                       notes: "Text-only conversion; Gemma 3n has no image path in MLX Swift.", priority: 15),
        LocalModelSpec(id: "mlx-community/Qwen3-VL-2B-Instruct-4bit", name: "Qwen3-VL 2B Instruct", sizeGB: 1.80,
                       vision: true, tools: true, minRAMGB: 16, family: "qwen3_vl", quantization: "4bit",
                       notes: "Small screen model.", priority: 7, coordinateSpace: .normalized1000),
        LocalModelSpec(id: "mlx-community/Qwen3-VL-4B-Instruct-4bit", name: "Qwen3-VL 4B Instruct", sizeGB: 3.11,
                       vision: true, tools: true, minRAMGB: 16, family: "qwen3_vl", quantization: "4bit",
                       notes: "Default screen (vision) model.", priority: 2, coordinateSpace: .normalized1000),
        LocalModelSpec(id: "mlx-community/Qwen3.5-2B-4bit", name: "Qwen3.5 2B", sizeGB: 1.75, vision: true, tools: true,
                       minRAMGB: 16, family: "qwen3_5", quantization: "4bit",
                       notes: "Natively multimodal; A/B against Qwen3-VL.", priority: 6, coordinateSpace: .normalized1000),
        LocalModelSpec(id: "mlx-community/Qwen3.5-4B-4bit", name: "Qwen3.5 4B", sizeGB: 3.06, vision: true, tools: true,
                       minRAMGB: 16, family: "qwen3_5", quantization: "4bit",
                       notes: "Natively multimodal; A/B against Qwen3-VL.", priority: 5, coordinateSpace: .normalized1000),
        LocalModelSpec(id: "mlx-community/gemma-4-e2b-it-4bit", name: "Gemma 4 E2B", sizeGB: 3.58, vision: true, tools: true,
                       minRAMGB: 16, family: "gemma4", quantization: "4bit",
                       notes: "gemma4 tool dialect; GUI grounding untested.", priority: 8),
        LocalModelSpec(id: "mlx-community/gemma-3-4b-it-qat-4bit", name: "Gemma 3 4B (QAT)", sizeGB: 3.03, vision: true,
                       tools: false, minRAMGB: 16, family: "gemma3", quantization: "4bit-qat",
                       notes: "No tool tokens: uses the text tool protocol.", priority: 14),
        LocalModelSpec(id: "mlx-community/LFM2.5-VL-1.6B-4bit", name: "LFM2.5-VL 1.6B", sizeGB: 1.50, vision: true,
                       tools: false, minRAMGB: 16, family: "lfm2_vl", quantization: "4bit",
                       notes: "Tool dialect unverified: uses the text tool protocol.", priority: 16),
        LocalModelSpec(id: "mlx-community/UI-TARS-1.5-7B-4bit", name: "UI-TARS 1.5 7B (GUI agent)", sizeGB: 4.89,
                       vision: true, tools: false, minRAMGB: 16, family: "qwen2_5_vl", quantization: "4bit",
                       notes: "GUI-agent fine-tune with its own action grammar; needs a dedicated parser.", priority: 17,
                       coordinateSpace: .imagePixels, experimental: true),
        LocalModelSpec(id: "mlx-community/Qwen3-VL-8B-Instruct-4bit", name: "Qwen3-VL 8B Instruct", sizeGB: 5.78,
                       vision: true, tools: true, minRAMGB: 24, family: "qwen3_vl", quantization: "4bit",
                       notes: "Strongest local screen model; 24 GB+.", priority: 4, coordinateSpace: .normalized1000),
    ]

    /// On-device embedders for the Library (B6).
    public static let embedders: [LocalModelSpec] = [
        LocalModelSpec(id: "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ", name: "Qwen3 Embedding 0.6B", sizeGB: 0.35,
                       vision: false, tools: false, minRAMGB: 8, family: "qwen3", quantization: "4bit-dwq",
                       notes: "Default local embedder.", kind: .embedding, priority: 1),
        LocalModelSpec(id: "mlx-community/LFM2.5-Embedding-350M-4bit", name: "LFM2.5 Embedding 350M", sizeGB: 0.20,
                       vision: false, tools: false, minRAMGB: 8, family: "lfm2", quantization: "4bit",
                       kind: .embedding, priority: 2),
        LocalModelSpec(id: "BAAI/bge-small-en-v1.5", name: "BGE small en v1.5", sizeGB: 0.13, vision: false, tools: false,
                       minRAMGB: 8, family: "bert", quantization: "fp32",
                       notes: "Repo is 0.40 GB; only the 0.13 GB of safetensors + JSON is downloaded.",
                       kind: .embedding, priority: 3),
    ]

    /// Chat models and embedders.
    public static var all: [LocalModelSpec] { models + embedders }

    /// Looks a model up by HF repo id (exact, then case-insensitive).
    public static func byID(_ id: String) -> LocalModelSpec? {
        all.first(where: { $0.id == id }) ?? all.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame })
    }

    /// Chat models that take images, best first.
    public static var visionCapable: [LocalModelSpec] {
        models.filter(\.vision).sorted(by: Self.byPriority)
    }

    /// Chat models that fit a Mac with `ramGB` of memory, best first (curated `priority`). Experimental models are
    /// left out unless asked for.
    public static func recommended(forRAMGB ramGB: Int, includeExperimental: Bool = false) -> [LocalModelSpec] {
        models.filter { $0.minRAMGB <= ramGB && (includeExperimental || !$0.experimental) }.sorted(by: Self.byPriority)
    }

    /// The text model the research picked for this much memory (Qwen3 1.7B on 8 GB, Qwen3 4B Instruct 2507 on 16 GB+).
    public static func defaultTextModel(forRAMGB ramGB: Int) -> LocalModelSpec? {
        recommended(forRAMGB: ramGB).first(where: { !$0.vision })
    }

    /// The screen model the research picked (Qwen3-VL 4B), or the best vision model that fits.
    public static func defaultVisionModel(forRAMGB ramGB: Int) -> LocalModelSpec? {
        recommended(forRAMGB: ramGB).first(where: { $0.vision && $0.tools })
    }

    /// The default embedder that fits.
    public static func defaultEmbedder(forRAMGB ramGB: Int) -> LocalModelSpec? {
        embedders.filter { $0.minRAMGB <= ramGB }.sorted(by: Self.byPriority).first
    }

    /// The tier `minRAMGB` should be for a size, per the B6 heuristic.
    public static func heuristicMinRAMGB(sizeGB: Double, vision: Bool) -> Int {
        let need = sizeGB * 1.5 + (vision ? 8 : 6)
        return ramTiers.first(where: { Double($0) >= need }) ?? (ramTiers.last ?? 32)
    }

    static func byPriority(_ a: LocalModelSpec, _ b: LocalModelSpec) -> Bool {
        a.priority != b.priority ? a.priority < b.priority : a.id < b.id
    }
}

/// Exact MLX / Hugging Face Swift package pins for the **app target** (never ZKit: MLX needs Xcode to build Metal).
/// project.yml and the app's local-model code read these so the pins live in one place.
public enum MLXPins {
    public struct Package: Sendable, Hashable, Codable {
        /// xcodegen package key and SwiftPM identity, e.g. `mlx-swift-lm`.
        public var name: String
        public var url: String
        public var exactVersion: String
        /// Products the app links from this package (empty: pinned only so SwiftPM cannot float it).
        public var products: [String]
        public var comment: String

        public init(name: String, url: String, exactVersion: String, products: [String], comment: String) {
            self.name = name; self.url = url; self.exactVersion = exactVersion; self.products = products; self.comment = comment
        }
    }

    /// Which pin set: current (Xcode ≥ 26.4, `macos-26` runner) or the Xcode 26.3 fallback.
    public enum PinSet: String, Sendable, CaseIterable {
        case primary
        case fallback
    }

    public static let mlxSwiftLMURL = "https://github.com/ml-explore/mlx-swift-lm"
    public static let mlxSwiftURL = "https://github.com/ml-explore/mlx-swift"
    public static let swiftHuggingFaceURL = "https://github.com/huggingface/swift-huggingface"
    public static let swiftTransformersURL = "https://github.com/huggingface/swift-transformers"

    public static let mlxSwiftLMVersion = "3.32.3"
    public static let mlxSwiftVersion = "0.32.3"
    public static let swiftHuggingFaceVersion = "1.0.0"
    public static let swiftTransformersVersion = "1.3.5"
    public static let fallbackMLXSwiftLMVersion = "3.31.4"
    public static let fallbackMLXSwiftVersion = "0.31.4"

    /// Minimum Xcode for the primary pins (mlx-swift ≥ 0.31.5 declares swift-tools-version 6.3).
    public static let minimumXcode = "26.4"
    /// GitHub runner label for the primary pins (`macos-15` stops at Xcode 26.3).
    public static let ciRunner = "macos-26"
    /// Xcode the CI selects on that runner.
    public static let ciXcode = "26.6"

    public static let mlxSwiftLMProducts = ["MLXLLM", "MLXVLM", "MLXLMCommon", "MLXEmbedders"]

    public static func packages(_ set: PinSet = .primary) -> [Package] {
        let lmVersion = set == .primary ? mlxSwiftLMVersion : fallbackMLXSwiftLMVersion
        let mlxVersion = set == .primary ? mlxSwiftVersion : fallbackMLXSwiftVersion
        let mlxComment = set == .primary
            ? "fixes the <26.4 launch crash of 0.32.2; tools-version 6.3"
            : "tools-version 5.12; exact pin or SwiftPM floats to 0.31.6 (needs Xcode 26.4)"
        return [
            Package(name: "mlx-swift", url: mlxSwiftURL, exactVersion: mlxVersion, products: [], comment: mlxComment),
            Package(name: "mlx-swift-lm", url: mlxSwiftLMURL, exactVersion: lmVersion, products: mlxSwiftLMProducts,
                    comment: "products: " + mlxSwiftLMProducts.joined(separator: ", ")),
            Package(name: "swift-huggingface", url: swiftHuggingFaceURL, exactVersion: swiftHuggingFaceVersion,
                    products: ["HuggingFace"], comment: "product HuggingFace (HubClient/HubCache) for the Downloader bridge"),
            Package(name: "swift-transformers", url: swiftTransformersURL, exactVersion: swiftTransformersVersion,
                    products: ["Tokenizers"], comment: "product Tokenizers for the TokenizerLoader bridge"),
        ]
    }

    /// The `packages:` block for xcodegen's project.yml.
    public static func xcodegenPackagesYAML(_ set: PinSet = .primary) -> String {
        var lines = ["packages:"]
        for p in packages(set) {
            lines.append("  \(p.name):")
            lines.append("    url: \(p.url)")
            lines.append("    exactVersion: \(p.exactVersion)        # \(p.comment)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The app target's `dependencies:` entries for project.yml (`- package: mlx-swift-lm` / `product: MLXLLM`).
    public static func xcodegenDependenciesYAML(_ set: PinSet = .primary, indent: Int = 6) -> String {
        let pad = String(repeating: " ", count: indent)
        var lines: [String] = []
        for p in packages(set) {
            for product in p.products {
                lines.append("\(pad)- package: \(p.name)")
                lines.append("\(pad)  product: \(product)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
