#if ZC_MLX
import Foundation
import MLXLMCommon
@preconcurrency import Tokenizers

// The only file that imports Tokenizers: it and MLXLMCommon both define `Tokenizer` and `TokenizerError`
// (pattern from Synapse's HFBridge.swift, docs/research/local-models-and-agent-loops.md §1.4).

/// swift-transformers' tokenizer behind MLX's tokenizer protocol.
struct MLXTokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

/// Loads a model folder's tokenizer with swift-transformers. Not strict: newer repos name tokenizer classes that
/// swift-transformers 1.3.5 does not list (Qwen3.5's `Qwen3_5Tokenizer`, mlx-community's `TokenizersBackend`); the
/// tokenizer itself is described by tokenizer.json, so an unknown name falls back to its BPE model.
struct MLXTransformersLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        MLXTokenizerBridge(upstream: try await AutoTokenizer.from(modelFolder: directory, strict: false))
    }
}
#endif
