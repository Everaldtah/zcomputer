import Foundation
import XCTest
import ZCore
@testable import ZProviders

final class ProviderClientFactoryTests: XCTestCase {
    let catalog = ProviderCatalog.bundled

    func provider(_ id: ProviderID) throws -> ProviderDescriptor { try XCTUnwrap(catalog[id]) }

    func keys(_ pairs: [ProviderID: String] = [:]) -> InMemoryKeyStore { InMemoryKeyStore(keys: pairs) }

    func testPicksTheClientByStyleAndNativeCapability() async throws {
        let store = keys(["anthropic": "a", "google": "g", "openai": "o", "groq": "q", "ollama-cloud": "c", "deepseek": "d"])
        let transport = MockTransport()

        let anthropic = try await ProviderClientFactory.makeClient(provider: try provider("anthropic"), keyStore: store,
                                                                   transport: transport)
        XCTAssertTrue(anthropic is AnthropicClient)
        XCTAssertEqual(anthropic.model, ModelRef(provider: "anthropic", model: "claude-opus-5-5"))
        XCTAssertEqual(anthropic.capabilities.nativeComputerUse, .anthropicComputer)

        let gemini = try await ProviderClientFactory.makeClient(provider: try provider("google"), keyStore: store, transport: transport)
        XCTAssertTrue(gemini is GeminiClient)

        let responses = try await ProviderClientFactory.makeClient(provider: try provider("openai"), model: "gpt-6.1-sol",
                                                                   keyStore: store, transport: transport)
        XCTAssertTrue(responses is OpenAIResponsesClient, "native OpenAI computer use goes through /responses")

        let chat = try await ProviderClientFactory.makeClient(provider: try provider("groq"), keyStore: store, transport: transport)
        XCTAssertTrue(chat is OpenAIChatClient)

        let deepseek = try await ProviderClientFactory.makeClient(provider: try provider("deepseek"), keyStore: store,
                                                                  transport: transport)
        XCTAssertTrue(deepseek is OpenAIChatClient)

        let cloud = try await ProviderClientFactory.makeClient(provider: try provider("ollama-cloud"), keyStore: store,
                                                               transport: transport)
        XCTAssertTrue(cloud is OllamaClient)

        let local = try await ProviderClientFactory.makeClient(provider: try provider("ollama"), model: "llama3.2:3b",
                                                               keyStore: keys(), transport: transport)
        XCTAssertTrue(local is OllamaClient)
        XCTAssertTrue(local.capabilities.tools)

        XCTAssertEqual(ProviderClientFactory.clientKind(provider: try provider("openai"), modelID: "gpt-6.1-terra"), .openAIResponses)
        XCTAssertEqual(ProviderClientFactory.clientKind(provider: try provider("groq"), modelID: "qwen/qwen3.8-27b"), .openAIChat)
    }

    func testCustomStyleIsUnsupported() async throws {
        let perplexity = try provider("perplexity")
        let error = await caughtError {
            _ = try await ProviderClientFactory.makeClient(provider: perplexity, keyStore: self.keys(["perplexity": "p"]),
                                                           transport: MockTransport())
        }
        guard case ZError.unsupported(let message)? = error as? ZError else { return XCTFail("\(String(describing: error))") }
        XCTAssertTrue(message.contains("Perplexity"))
    }

    func testMissingKeyAndMissingModel() async throws {
        let groq = try provider("groq")
        let missing = await caughtError {
            _ = try await ProviderClientFactory.makeClient(provider: groq, keyStore: self.keys(), transport: MockTransport())
        }
        XCTAssertEqual(missing as? ZError, .missingAPIKey("groq"))

        let blank = await caughtError {
            _ = try await ProviderClientFactory.makeClient(provider: groq, keyStore: self.keys(["groq": "   "]),
                                                           transport: MockTransport())
        }
        XCTAssertEqual(blank as? ZError, .missingAPIKey("groq"))

        let lmstudio = try provider("lmstudio")
        let noModel = await caughtError {
            _ = try await ProviderClientFactory.makeClient(provider: lmstudio, keyStore: self.keys(), transport: MockTransport())
        }
        guard case ZError.invalidArgument? = noModel as? ZError else { return XCTFail("\(String(describing: noModel))") }

        let ok = try await ProviderClientFactory.makeClient(provider: lmstudio, model: "qwen3-4b", keyStore: keys(),
                                                            transport: MockTransport())
        XCTAssertTrue(ok is OpenAIChatClient)
    }

    func testPlaceholdersAreFilledFromTheOverride() async throws {
        let cloudflare = try provider("cloudflare")
        let store = keys(["cloudflare": "cf-token"])
        let unresolved = await caughtError {
            _ = try await ProviderClientFactory.resolveEndpoint(provider: cloudflare, keyStore: store)
        }
        guard case ZError.invalidArgument(let message)? = unresolved as? ZError else {
            return XCTFail("\(String(describing: unresolved))")
        }
        XCTAssertTrue(message.contains("{account_id}"))

        try await store.setBaseURLOverride(URL(string: "account_id=abc123"), for: "cloudflare")
        let endpoint = try await ProviderClientFactory.resolveEndpoint(provider: cloudflare, keyStore: store)
        XCTAssertEqual(endpoint.baseURL.absoluteString, "https://api.cloudflare.com/client/v4/accounts/abc123/ai/v1")
        XCTAssertEqual(endpoint.apiKey, "cf-token")

        // The client built from it calls the resolved URL.
        let transport = MockTransport()
        transport.enqueue(body: "data: [DONE]\n\n")
        let client = try await ProviderClientFactory.makeClient(provider: cloudflare, keyStore: store, transport: transport)
        _ = try await collect(client.stream(messages: [.user("hi")], tools: [], options: .standard))
        XCTAssertEqual(transport.lastRequest?.url.absoluteString,
                       "https://api.cloudflare.com/client/v4/accounts/abc123/ai/v1/chat/completions")
        XCTAssertEqual(transport.lastRequest?.header("authorization"), "Bearer cf-token")
    }

    func testBaseURLResolution() throws {
        XCTAssertEqual(try ProviderClientFactory.resolveBaseURL(template: "https://{resource}.openai.azure.com/openai/v1",
                                                                override: URL(string: "?resource=myres")).absoluteString,
                       "https://myres.openai.azure.com/openai/v1")
        XCTAssertEqual(try ProviderClientFactory.resolveBaseURL(template: "https://bedrock-runtime.{region}.amazonaws.com/openai/v1",
                                                                override: URL(string: "region=eu-west-1")).absoluteString,
                       "https://bedrock-runtime.eu-west-1.amazonaws.com/openai/v1")
        XCTAssertEqual(try ProviderClientFactory.resolveBaseURL(template: "https://api.groq.com/openai/v1",
                                                                override: URL(string: "http://localhost:9999/v1")).absoluteString,
                       "http://localhost:9999/v1", "a full URL replaces the template")
        XCTAssertEqual(try ProviderClientFactory.resolveBaseURL(template: "https://api.groq.com/openai/v1", override: nil).absoluteString,
                       "https://api.groq.com/openai/v1")
        XCTAssertThrowsError(try ProviderClientFactory.resolveBaseURL(template: "", override: nil))
        XCTAssertEqual(try ProviderClientFactory.resolveBaseURL(template: "", override: URL(string: "https://gw.example.com/v1"))
            .absoluteString, "https://gw.example.com/v1", "custom template takes the user's URL")
    }

    func testEndpointURLJoiningAndAuth() throws {
        let query = testEndpoint("https://example.com/v1/", auth: .query("key"), key: "k1")
        XCTAssertEqual(try query.url("/models", query: [URLQueryItem(name: "pageSize", value: "5")]).absoluteString,
                       "https://example.com/v1/models?pageSize=5&key=k1")
        XCTAssertEqual(query.headers()["Authorization"], nil)
        let header = testEndpoint("https://example.com", auth: .header("x-api-key"), key: "k2")
        XCTAssertEqual(header.headers(["anthropic-version": "2023-06-01"]), ["x-api-key": "k2", "anthropic-version": "2023-06-01"])
        let optional = testEndpoint("http://localhost:1234/v1", auth: .noAuth, key: "lm-token")
        XCTAssertEqual(optional.headers()["Authorization"], "Bearer lm-token", "optional tokens on local servers")
        XCTAssertEqual(testEndpoint("http://localhost:1234/v1", auth: .noAuth, key: nil).headers(), [:])
    }
}

final class KeyTesterTests: XCTestCase {
    func testValidKeyWithATinyCompletion() async throws {
        let groq = try XCTUnwrap(ProviderCatalog.bundled["groq"])
        let transport = MockTransport()
        transport.enqueue(body: #"data: {"choices":[{"index":0,"delta":{"content":"OK"}}]}"# + "\n\ndata: [DONE]\n\n")
        let result = await KeyTester.test(provider: groq, keyStore: InMemoryKeyStore(keys: ["groq": "gsk_test"]),
                                          transport: transport)
        XCTAssertTrue(result.ok, result.message)
        XCTAssertEqual(result.method, .completion)
        XCTAssertEqual(result.model, "qwen/qwen3.8-27b")
        XCTAssertGreaterThanOrEqual(result.latency, 0)
        XCTAssertEqual(transport.lastBody?["max_tokens"], 64)
        XCTAssertEqual(transport.lastBody?.at("messages", 0, "content"), .string(KeyTester.prompt))
    }

    func testRejectedKey() async throws {
        let anthropic = try XCTUnwrap(ProviderCatalog.bundled["anthropic"])
        let transport = MockTransport()
        transport.enqueue(status: 401, body: #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)
        let result = await KeyTester.test(provider: anthropic, keyStore: InMemoryKeyStore(keys: ["anthropic": "bad"]),
                                          transport: transport)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.message, "Key rejected (HTTP 401): authentication_error: invalid x-api-key")
        XCTAssertEqual(result.error, .http(status: 401, body: "authentication_error: invalid x-api-key"))
        XCTAssertEqual(transport.requests.count, 1, "no retries while testing a key")
    }

    func testMissingKeyAndLocalServerListing() async throws {
        let mistral = try XCTUnwrap(ProviderCatalog.bundled["mistral"])
        let missing = await KeyTester.test(provider: mistral, keyStore: InMemoryKeyStore(), transport: MockTransport())
        XCTAssertFalse(missing.ok)
        XCTAssertEqual(missing.error, .missingAPIKey("mistral"))

        let lmstudio = try XCTUnwrap(ProviderCatalog.bundled["lmstudio"])
        let transport = MockTransport()
        transport.enqueue(body: #"{"object":"list","data":[{"id":"qwen3-4b"},{"id":"gemma-4-e2b"}]}"#)
        let listed = await KeyTester.test(provider: lmstudio, keyStore: InMemoryKeyStore(), transport: transport)
        XCTAssertTrue(listed.ok, listed.message)
        XCTAssertEqual(listed.method, .listModels)
        XCTAssertEqual(listed.modelCount, 2)
        XCTAssertEqual(transport.lastRequest?.url.absoluteString, "http://localhost:1234/v1/models")
    }
}
