import Foundation
import ZCore

// ZProviders: the provider catalogue (Resources/providers.json), HTTP/SSE plumbing over an injectable `Transport`,
// and `LLMClient` implementations for OpenAI Chat Completions (and every OpenAI-compatible server), the OpenAI
// Responses API, Anthropic Messages, Google Gemini and Ollama. Start at `ProviderCatalog.bundled` and
// `ProviderClientFactory.makeClient(provider:model:keyStore:transport:)`; `KeyTester` validates keys.
//
// No ZCore signatures were changed; the extra contract (native computer-use call naming) is documented on
// `NativeToolNaming` and in ZAgent's NativeComputerBridge.swift.
public enum ZProvidersModule { public static let name = "ZProviders" }
