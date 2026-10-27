import Foundation
import XCTest
import ZCore
@testable import ZProviders

final class CatalogTests: XCTestCase {
    func catalog() throws -> ProviderCatalog { try ProviderCatalog.loadBundled() }

    func testBundledCatalogLoads() throws {
        let catalog = try catalog()
        XCTAssertEqual(catalog.all.count, 41)
        XCTAssertEqual(Set(catalog.all.map(\.id)).count, catalog.all.count, "provider ids are unique")
        XCTAssertEqual(ProviderCatalog.bundled.all.count, 41)
        XCTAssertEqual(catalog.byID.count, 41)
    }

    func testEveryProviderHasAUsableBaseURL() throws {
        for provider in try catalog().all {
            if provider.quirkSet.contains(Quirk.userSuppliedBaseURL) {
                XCTAssertTrue(provider.baseURL.isEmpty, "\(provider.id): template keeps its base URL empty")
                continue
            }
            XCTAssertFalse(provider.baseURL.isEmpty, "\(provider.id) has no baseURL")
            var values: [String: String] = [:]
            for name in provider.baseURLPlaceholders { values[name] = "example" }
            let filled = Placeholders.fill(provider.baseURL, values: values)
            let url = URL(string: filled)
            XCTAssertNotNil(url?.host, "\(provider.id): \(provider.baseURL) is not a URL")
            XCTAssertTrue(["http", "https"].contains(url?.scheme ?? ""), "\(provider.id): scheme")
            if provider.kind != .local {
                XCTAssertEqual(url?.scheme, "https", "\(provider.id): hosted providers use https")
            }
        }
    }

    func testPlaceholdersAreTheDocumentedOnes() throws {
        let catalog = try catalog()
        XCTAssertEqual(catalog["cloudflare"]?.baseURLPlaceholders, ["account_id"])
        XCTAssertEqual(catalog["bedrock"]?.baseURLPlaceholders, ["region"])
        XCTAssertEqual(catalog["azure-openai"]?.baseURLPlaceholders, ["resource"])
        let others = catalog.all.filter { !["cloudflare", "bedrock", "azure-openai"].contains($0.id.rawValue) }
        for provider in others { XCTAssertEqual(provider.baseURLPlaceholders, [], "\(provider.id)") }
    }

    func testModelsAreWellFormed() throws {
        for provider in try catalog().all {
            let ids = provider.models.map(\.id)
            XCTAssertEqual(Set(ids).count, ids.count, "\(provider.id): duplicate model ids")
            for model in provider.models {
                XCTAssertFalse(model.id.trimmingCharacters(in: .whitespaces).isEmpty, "\(provider.id): empty model id")
                XCTAssertFalse(model.name.isEmpty, "\(provider.id)/\(model.id): empty name")
                if let context = model.contextTokens { XCTAssertGreaterThan(context, 0) }
            }
            if provider.defaultModel.isEmpty {
                XCTAssertTrue(provider.models.isEmpty, "\(provider.id): models but no default model")
            } else {
                XCTAssertTrue(ids.contains(provider.defaultModel), "\(provider.id): default \(provider.defaultModel) not in models")
            }
        }
    }

    func testFreeFlagsAreConsistentWithKind() throws {
        for provider in try catalog().all {
            let freeModels = provider.models.filter(\.free)
            switch provider.kind {
            case .paid, .local:
                XCTAssertTrue(freeModels.isEmpty, "\(provider.id) is \(provider.kind) but lists free models")
            case .free:
                XCTAssertEqual(provider.freeTier?.available, true, "\(provider.id): free kind without a free tier")
                XCTAssertFalse(freeModels.isEmpty, "\(provider.id): free kind without free models")
            case .freemium:
                XCTAssertNotNil(provider.freeTier, "\(provider.id): freemium without freeTier")
            }
            if provider.kind == .local { XCTAssertNil(provider.freeTier, "\(provider.id)") }
        }
    }

    func testNativeComputerUseOnlyOnFirstPartyAPIs() throws {
        var counts: [NativeToolKind: Int] = [:]
        for provider in try catalog().all {
            for model in provider.models {
                guard let native = model.nativeComputerUse else { continue }
                counts[native, default: 0] += 1
                XCTAssertTrue(model.vision && model.tools, "\(provider.id)/\(model.id)")
                switch native {
                case .anthropicComputer: XCTAssertEqual(provider.apiStyle, .anthropic)
                case .openAIComputer: XCTAssertEqual(provider.apiStyle, .openai)
                case .geminiComputer: XCTAssertEqual(provider.apiStyle, .gemini)
                case .anthropicBash, .anthropicTextEditor: XCTFail("not a computer-use kind")
                }
            }
        }
        XCTAssertEqual(counts[.anthropicComputer], 6)
        XCTAssertEqual(counts[.openAIComputer], 5)
        XCTAssertEqual(counts[.geminiComputer], 5)
    }

    func testStylesAndAuth() throws {
        let catalog = try catalog()
        XCTAssertEqual(catalog["anthropic"]?.apiStyle, .anthropic)
        XCTAssertEqual(catalog["anthropic"]?.authHeader, .header("x-api-key"))
        XCTAssertEqual(catalog["google"]?.authHeader, .header("x-goog-api-key"))
        XCTAssertEqual(catalog["groq"]?.authHeader, .bearer)
        XCTAssertEqual(catalog["ollama"]?.authHeader, .noAuth)
        XCTAssertEqual(catalog["ollama"]?.apiStyle, .ollama)
        XCTAssertEqual(catalog["perplexity"]?.apiStyle, .custom)
        XCTAssertEqual(catalog["ollama"]?.requiresAPIKey, false)
        XCTAssertEqual(catalog["ovh"]?.requiresAPIKey, false, "apiKeyOptional")
        XCTAssertEqual(catalog["groq"]?.requiresAPIKey, true)
        XCTAssertEqual(catalog["lmstudio"]?.requiresAPIKey, false)
    }

    func testQueries() throws {
        let catalog = try catalog()
        let free = Set(catalog.free.map(\.id))
        XCTAssertTrue(free.contains("google") && free.contains("groq") && free.contains("openrouter"))
        XCTAssertFalse(free.contains("anthropic"))
        let local = Set(catalog.local.map(\.id))
        XCTAssertEqual(local, ["ollama", "lmstudio", "llamacpp", "jan", "vllm", "koboldcpp"])
        XCTAssertEqual(catalog.defaultModel(for: "anthropic"), ModelRef(provider: "anthropic", model: "claude-opus-5-5"))
        XCTAssertNil(catalog.defaultModel(for: "ollama"))
        XCTAssertNil(catalog.defaultModel(for: "nope"))

        let gemini = try XCTUnwrap(catalog.modelInfo(ModelRef(provider: "google", model: "gemini-3.8-flash")))
        XCTAssertTrue(gemini.free)
        XCTAssertEqual(gemini.capabilities.nativeComputerUse, .geminiComputer)
        XCTAssertTrue(gemini.capabilities.vision && gemini.capabilities.tools && gemini.capabilities.jsonMode)
        XCTAssertEqual(gemini.capabilities.contextWindow, 1_048_576)

        let claude = try XCTUnwrap(catalog.modelInfo(ModelRef(provider: "anthropic", model: "claude-opus-5-5")))
        XCTAssertFalse(claude.capabilities.jsonMode)
        XCTAssertEqual(claude.notes, "Recommended")

        let unknown = try XCTUnwrap(catalog.capabilities(ModelRef(provider: "ollama", model: "qwen3:4b")))
        XCTAssertTrue(unknown.tools)
        XCTAssertFalse(unknown.vision)
        XCTAssertNil(unknown.nativeComputerUse)

        let hyperbolic = try XCTUnwrap(catalog["hyperbolic"])
        XCTAssertTrue(hyperbolic.models.allSatisfy { !hyperbolic.capabilities(forModel: $0.id).vision }, "textOnly quirk")

        XCTAssertFalse(catalog.freeModels.isEmpty)
        XCTAssertEqual(catalog.nativeComputerUseModels.count, 16)
        XCTAssertEqual(catalog.models(for: "openai").count, 5)
    }

    func testCustomProvidersMergeAndReplace() async throws {
        let store = InMemoryCustomProviderStore()
        let custom = ProviderDescriptor.custom(id: "my-gateway", name: "My gateway", baseURL: "https://gw.example.com/v1",
                                               models: [ModelDescriptor(id: "m1", vision: true, tools: true)])
        try await store.save(custom)
        let local = ProviderDescriptor.custom(id: "lan-box", name: "LAN box", baseURL: "http://localhost:8081/v1",
                                              requiresKey: false)
        try await store.save(local)

        let merged = await ProviderCatalog.bundled.merging(customStore: store)
        XCTAssertEqual(merged.all.count, 43)
        XCTAssertEqual(merged["my-gateway"]?.apiStyle, .openai)
        XCTAssertEqual(merged["my-gateway"]?.defaultModel, "m1")
        XCTAssertEqual(merged["my-gateway"]?.kind, .paid)
        XCTAssertEqual(merged["lan-box"]?.kind, .local)
        XCTAssertEqual(merged["lan-box"]?.requiresAPIKey, false)
        XCTAssertEqual(merged.defaultModel(for: "my-gateway")?.model, "m1")

        var renamed = custom
        renamed.name = "Renamed"
        try await store.save(renamed)
        let again = await ProviderCatalog.bundled.merging(customStore: store)
        XCTAssertEqual(again.all.count, 43)
        XCTAssertEqual(again["my-gateway"]?.name, "Renamed")

        try await store.remove("lan-box")
        let fewer = await ProviderCatalog.bundled.merging(customStore: store)
        XCTAssertEqual(fewer.all.count, 42)

        // A custom provider with a bundled id replaces the bundled entry.
        let override = ProviderCatalog.bundled.merge(custom: [ProviderDescriptor.custom(id: "groq", name: "Groq proxy",
                                                                                       baseURL: "https://proxy.example/v1")])
        XCTAssertEqual(override.all.count, 41)
        XCTAssertEqual(override["groq"]?.name, "Groq proxy")
    }

    func testLenientDecoding() throws {
        let json = """
        [
          {"id": "x", "name": "X", "kind": "weird", "apiStyle": "grpc", "baseURL": "https://x.example/v1",
           "authHeader": "query:key", "unknownField": [1, 2, 3],
           "models": [{"id": "m", "vision": true, "nativeComputerUse": "somethingNew", "extra": {}}],
           "quirks": ["noTools"], "defaultModel": "m"},
          {"id": "y"},
          {"id": "z", "models": null, "freeTier": {"available": true}, "modelsEndpoint": null, "authHeader": "x-api-key"}
        ]
        """
        let catalog = try ProviderCatalog(data: Data(json.utf8))
        XCTAssertEqual(catalog.all.count, 3)
        let x = try XCTUnwrap(catalog["x"])
        XCTAssertEqual(x.kind, .paid)
        XCTAssertEqual(x.apiStyle, .custom)
        XCTAssertEqual(x.authHeader, .query("key"))
        XCTAssertEqual(x.models.first?.name, "m")
        XCTAssertNil(x.models.first?.nativeComputerUse)
        XCTAssertEqual(x.models.first?.vision, true)
        XCTAssertEqual(x.models.first?.tools, false)
        let y = try XCTUnwrap(catalog["y"])
        XCTAssertEqual(y.name, "y")
        XCTAssertEqual(y.models, [])
        XCTAssertEqual(y.defaultModel, "")
        XCTAssertEqual(y.apiStyle, .openai)
        let z = try XCTUnwrap(catalog["z"])
        XCTAssertEqual(z.freeTier?.available, true)
        XCTAssertNil(z.modelsEndpoint)
        XCTAssertEqual(z.authHeader, .header("x-api-key"))

        XCTAssertThrowsError(try ProviderCatalog(data: Data("{\"not\": \"an array\"}".utf8))) { error in
            guard case ZError.decoding = error else { return XCTFail("\(error)") }
        }
    }

    func testEncodingRoundTrips() throws {
        let catalog = try catalog()
        let data = try JSONEncoder().encode(catalog.all)
        let decoded = try ProviderCatalog(data: data)
        XCTAssertEqual(decoded.all, catalog.all)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"authHeader\":\"x-goog-api-key\""))
        XCTAssertTrue(text.contains("\"nativeComputerUse\":\"anthropicComputer\""))
    }

    func testQuirkSet() {
        let quirks = QuirkSet(["noLogprobs", "maxImagesPerRequest:3", "noParallelToolCalls:openai/gpt-oss-*",
                               "anthropicVersion:2023-06-01", "freeModelsSuffix::free",
                               "toolsRequireResponsesAPI:gpt-6.1-sol,gpt-6.1-terra"])
        XCTAssertTrue(quirks.contains("noLogprobs"))
        XCTAssertTrue(quirks.contains("nologprobs"), "case-insensitive names")
        XCTAssertFalse(quirks.contains("noTools"))
        XCTAssertEqual(quirks.intValue("maxImagesPerRequest"), 3)
        XCTAssertEqual(quirks.value("anthropicVersion"), "2023-06-01")
        XCTAssertEqual(quirks.value("freeModelsSuffix"), ":free")
        XCTAssertTrue(quirks.applies("noLogprobs", toModel: "anything"))
        XCTAssertTrue(quirks.applies("noParallelToolCalls", toModel: "openai/gpt-oss-120b"))
        XCTAssertFalse(quirks.applies("noParallelToolCalls", toModel: "qwen/qwen3.8-27b"))
        XCTAssertTrue(quirks.applies("toolsRequireResponsesAPI", toModel: "gpt-6.1-terra"))
        XCTAssertFalse(quirks.applies("toolsRequireResponsesAPI", toModel: "gpt-6-luna"))
        XCTAssertTrue(QuirkSet.glob("gpt-?.1-*", matches: "GPT-6.1-sol"))
        XCTAssertFalse(QuirkSet.glob("gpt-6", matches: "gpt-6.1"))
    }

    func testAuthStyleParsing() {
        XCTAssertEqual(AuthStyle(rawValue: "bearer"), .bearer)
        XCTAssertEqual(AuthStyle(rawValue: "none"), .noAuth)
        XCTAssertEqual(AuthStyle(rawValue: "x-api-key"), .header("x-api-key"))
        XCTAssertEqual(AuthStyle(rawValue: "query:key"), .query("key"))
        XCTAssertEqual(AuthStyle.query("key").rawValue, "query:key")
        XCTAssertEqual(AuthStyle.noAuth.rawValue, "none")
    }
}
