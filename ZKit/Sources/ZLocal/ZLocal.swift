import Foundation
import ZCore

// ZLocal: everything about local models that builds on Linux.
//
// * `LocalServerDiscovery` finds Ollama / LM Studio / llama.cpp / Jan / vLLM / KoboldCpp (and user endpoints) and lists
//   their models as ZCore `ModelInfo`s inside `LocalServer`s. The app maps them onto ZProviders descriptors.
// * `LocalModelCatalog` is the curated in-app MLX model list (+ embedders); `MLXPins` holds the exact package pins.
// * `LocalModelStore` tracks downloaded MLX models on disk and plans Hugging Face downloads.
// * `HostCapabilities` says what this Mac can run.
//
// The MLX runner and Apple Foundation Models client live in the app target (Apple-only packages).
public enum ZLocalModule { public static let name = "ZLocal" }
