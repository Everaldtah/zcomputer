import Foundation

/// Guesses what a locally served model can do from its name alone. Used when a server does not report
/// capabilities (OpenAI-style `/v1/models` lists) or when its capability endpoint fails. Server-reported
/// capabilities always win over these guesses.
public enum LocalModelHeuristics {

    /// Substrings that mark a vision (image-input) model family.
    static let visionMarkers: [String] = [
        "vision", "llava", "bakllava", "minicpm-v", "minicpm_v", "moondream", "pixtral", "mllama",
        "smolvlm", "idefics", "paligemma", "internvl", "fastvlm", "ui-tars", "ui_tars", "qwen3.5", "qwen3_5",
        "qwen3-5", "kimi-vl", "glm-4v", "glm-4.5v", "glm4v", "phi-3.5-vision", "phi-4-multimodal", "granite3.2-vision",
        "mistral-small-3.1", "mistral-small3.1", "mistral-small-3.2", "mistral-small3.2", "llama4", "llama-4",
    ]

    /// Gemma 3/4 take images except the text-only sizes and the Gemma 3n `-lm` text conversions.
    static let gemmaVisionPrefixes = ["gemma3", "gemma-3", "gemma4", "gemma-4"]
    static let gemmaTextOnlyMarkers = ["gemma3n", "gemma-3n", "270m", "1b", "-text", "_text", "-lm"]

    /// Families without a tool-call format (or with their own action grammar).
    static let noToolMarkers: [String] = [
        "llava", "bakllava", "moondream", "gemma2", "gemma-2", "gemma3", "gemma-3", "ui-tars", "ui_tars",
        "codellama", "starcoder", "tinyllama", "phi-2", "phi2", "smolvlm", "paligemma", "lfm2-vl", "lfm2.5-vl",
        "lfm2_vl", "deepseek-coder", "stablelm", "orca-mini", "vicuna", "falcon",
    ]

    /// Substrings that mark an embedding / reranking model (not a chat model).
    static let embeddingMarkers: [String] = [
        "embed", "bge-", "bge_", "minilm", "e5-", "gte-", "gte_", "rerank", "colbert", "snowflake-arctic-embed",
        "mxbai-embed", "nomic-bert",
    ]

    /// Lower-cased name with any `org/` prefix and `.gguf` suffix stripped.
    static func normalized(_ name: String) -> String {
        var s = name.lowercased()
        if s.hasSuffix(".gguf") { s.removeLast(5) }
        return s
    }

    /// Splits on everything that is not a letter or digit.
    static func tokens(_ name: String) -> [String] {
        normalized(name).split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
    }

    /// True for embedding/reranker models, which should not be offered as chat models.
    public static func isEmbeddingModel(_ name: String) -> Bool {
        let n = normalized(name)
        return embeddingMarkers.contains { n.contains($0) }
    }

    /// True when the name suggests the model accepts images ("vl", "vision", "llava", "qwen3-vl", "gemma3", ...).
    public static func likelyVision(_ name: String) -> Bool {
        if isEmbeddingModel(name) { return false }
        let n = normalized(name)
        if visionMarkers.contains(where: { n.contains($0) }) { return true }
        // "vl" as its own token or a token suffix: "qwen3-vl", "qwen2.5vl", "internvl3", "lfm2-vl".
        for token in tokens(name) {
            let stripped = token.trimmingCharacters(in: CharacterSet.decimalDigits)
            if token == "vl" || token == "vlm" || stripped.hasSuffix("vl") || stripped.hasSuffix("vlm") { return true }
        }
        if gemmaVisionPrefixes.contains(where: { n.contains($0) }) {
            return !gemmaTextOnlyMarkers.contains(where: { n.contains($0) })
        }
        return false
    }

    /// True when the model probably supports native tool calls. Most current instruct models do; the
    /// exceptions are embedders, base models and families with no tool-call format.
    public static func likelyTools(_ name: String) -> Bool {
        if isEmbeddingModel(name) { return false }
        let n = normalized(name)
        if noToolMarkers.contains(where: { n.contains($0) }) { return false }
        let t = tokens(name)
        if t.contains("base") { return false }
        return true
    }
}
