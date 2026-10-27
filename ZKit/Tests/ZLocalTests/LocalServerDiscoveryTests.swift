import Foundation
import XCTest
import ZCore
@testable import ZLocal

final class LocalServerDiscoveryTests: XCTestCase {

    private func model(_ server: LocalServer?, _ id: String, file: StaticString = #filePath, line: UInt = #line) -> ModelInfo? {
        let found = server?.models.first(where: { $0.id == id })
        XCTAssertNotNil(found, "missing model \(id)", file: file, line: line)
        return found
    }

    // MARK: Ollama

    func testOllamaTagsParse() async {
        let mock = MockTransport()
        mock.on("http://127.0.0.1:11434/api/tags", json: """
        {"models":[
          {"name":"qwen3:4b","model":"qwen3:4b","modified_at":"2026-10-01T00:00:00Z","size":2497293918,"digest":"a1",
           "details":{"format":"gguf","family":"qwen3","families":["qwen3"],"parameter_size":"4.0B","quantization_level":"Q4_K_M"}},
          {"name":"llava:7b","model":"llava:7b","size":4733363377,
           "details":{"format":"gguf","family":"llama","families":["llama","clip"],"parameter_size":"7B","quantization_level":"Q4_0"}},
          {"name":"qwen3-vl:4b","model":"qwen3-vl:4b","size":3300000000,
           "details":{"family":"qwen3vl","parameter_size":"4.4B","quantization_level":"Q4_K_M"}},
          {"name":"nomic-embed-text:latest","model":"nomic-embed-text:latest","size":274302450,
           "details":{"family":"nomic-bert","parameter_size":"137M","quantization_level":"F16"}}
        ]}
        """)
        mock.on("http://127.0.0.1:11434/api/version", json: #"{"version":"0.12.6"}"#)
        mock.on("http://127.0.0.1:11434/api/show", method: "POST", body: #"{"model":"qwen3:4b"}"#, json: """
        {"capabilities":["completion","tools","thinking"],"model_info":{"general.architecture":"qwen3","qwen3.context_length":40960}}
        """)
        mock.on("http://127.0.0.1:11434/api/show", method: "POST", body: #"{"model":"qwen3-vl:4b"}"#, json: """
        {"capabilities":["completion","vision","tools"],"model_info":{"qwen3vl.context_length":262144}}
        """)

        let servers = await LocalServerDiscovery(transport: mock).scan(timeout: 2)
        XCTAssertEqual(servers.count, 1)
        guard let ollama = servers.first else { return }
        XCTAssertEqual(ollama.kind, .ollama)
        XCTAssertEqual(ollama.id, "ollama@127.0.0.1:11434")
        XCTAssertEqual(ollama.name, "Ollama")
        XCTAssertEqual(ollama.apiStyle, .ollama)
        XCTAssertEqual(ollama.baseURL.absoluteString, "http://127.0.0.1:11434")
        XCTAssertEqual(ollama.openAIBaseURL.absoluteString, "http://127.0.0.1:11434/v1")
        XCTAssertEqual(ollama.providerID, "ollama")
        XCTAssertEqual(ollama.version, "0.12.6")
        XCTAssertTrue(ollama.reachable)
        XCTAssertFalse(ollama.requiresAuth)
        XCTAssertGreaterThanOrEqual(ollama.latencyMs, 0)
        XCTAssertEqual(ollama.models.map(\.id), ["qwen3:4b", "llava:7b", "qwen3-vl:4b", "nomic-embed-text:latest"])

        let qwen = model(ollama, "qwen3:4b")
        XCTAssertEqual(qwen?.capabilities.tools, true)
        XCTAssertEqual(qwen?.capabilities.vision, false)
        XCTAssertEqual(qwen?.capabilities.contextWindow, 40960)
        XCTAssertEqual(qwen?.free, true)
        XCTAssertEqual(qwen?.notes?.contains("Q4_K_M"), true)

        // /api/show capabilities win.
        let vl = model(ollama, "qwen3-vl:4b")
        XCTAssertEqual(vl?.capabilities.vision, true)
        XCTAssertEqual(vl?.capabilities.tools, true)
        XCTAssertEqual(vl?.capabilities.contextWindow, 262144)

        // No /api/show answer: heuristics (clip family / name).
        let llava = model(ollama, "llava:7b")
        XCTAssertEqual(llava?.capabilities.vision, true)
        XCTAssertEqual(llava?.capabilities.tools, false)

        let embed = model(ollama, "nomic-embed-text:latest")
        XCTAssertEqual(embed?.capabilities.vision, false)
        XCTAssertEqual(embed?.capabilities.tools, false)
        XCTAssertEqual(embed?.notes?.contains("embedding"), true)

        XCTAssertEqual(mock.requestCount(containing: "/api/show"), 4)
    }

    // MARK: LM Studio

    func testLMStudioV1() async {
        let mock = MockTransport()
        mock.on("http://127.0.0.1:1234/api/v1/models", json: """
        {"models":[
          {"type":"llm","publisher":"qwen","key":"qwen/qwen3-4b-2507","display_name":"Qwen3 4B 2507","architecture":"qwen3",
           "quantization":{"name":"Q4_K_M","bits_per_weight":4},"size_bytes":2500000000,"params_string":"4B",
           "loaded_instances":[{"id":"qwen/qwen3-4b-2507","config":{"context_length":4096}}],"max_context_length":262144,
           "format":"gguf","capabilities":{"vision":false,"trained_for_tool_use":true}},
          {"type":"llm","key":"google/gemma-3-4b","display_name":"Gemma 3 4B","quantization":{"name":"4bit","bits_per_weight":4},
           "size_bytes":3000000000,"loaded_instances":[],"max_context_length":131072,"format":"mlx",
           "capabilities":{"vision":true,"trained_for_tool_use":false}},
          {"type":"embedding","key":"text-embedding-nomic-embed-text-v1.5","display_name":"Nomic Embed","size_bytes":84000000,
           "loaded_instances":[],"max_context_length":2048,"format":"gguf"}
        ]}
        """)
        let servers = await LocalServerDiscovery(transport: mock).scan(timeout: 2)
        XCTAssertEqual(servers.count, 1)
        guard let lms = servers.first else { return }
        XCTAssertEqual(lms.kind, .lmStudio)
        XCTAssertEqual(lms.id, "lmstudio@127.0.0.1:1234")
        XCTAssertEqual(lms.apiStyle, .openai)
        XCTAssertEqual(lms.baseURL.absoluteString, "http://127.0.0.1:1234/v1")
        XCTAssertEqual(lms.openAIBaseURL, lms.baseURL)
        XCTAssertEqual(lms.models.map(\.id), ["qwen/qwen3-4b-2507", "google/gemma-3-4b"], "embedding models are skipped")

        let qwen = model(lms, "qwen/qwen3-4b-2507")
        XCTAssertEqual(qwen?.displayName, "Qwen3 4B 2507")
        XCTAssertEqual(qwen?.capabilities.tools, true)
        XCTAssertEqual(qwen?.capabilities.vision, false)
        XCTAssertEqual(qwen?.capabilities.contextWindow, 262144)
        XCTAssertEqual(qwen?.notes?.contains("loaded"), true)

        let gemma = model(lms, "google/gemma-3-4b")
        XCTAssertEqual(gemma?.capabilities.vision, true)
        XCTAssertEqual(gemma?.capabilities.tools, false)
        // v1 answered, so neither fallback was tried.
        XCTAssertEqual(mock.requestCount(containing: "/api/v0/models"), 0)
        XCTAssertEqual(mock.requestCount(containing: "1234/v1/models"), 0)
    }

    func testLMStudioFallsBackToOpenAIModels() async {
        let mock = MockTransport()
        mock.live("http://127.0.0.1:1234")   // /api/v1/models and /api/v0/models answer 404
        mock.on("http://127.0.0.1:1234/v1/models", json: """
        {"object":"list","data":[
          {"id":"qwen2.5-vl-7b-instruct","object":"model","owned_by":"organization_owner"},
          {"id":"llama-3.2-3b-instruct","object":"model","owned_by":"organization_owner"}
        ]}
        """)
        let servers = await LocalServerDiscovery(transport: mock).scan(timeout: 2)
        XCTAssertEqual(servers.count, 1)
        guard let lms = servers.first else { return }
        XCTAssertEqual(lms.kind, .lmStudio, "a generic OpenAI list on LM Studio's port keeps the hint")
        XCTAssertEqual(lms.baseURL.absoluteString, "http://127.0.0.1:1234/v1")
        XCTAssertEqual(lms.models.map(\.id), ["qwen2.5-vl-7b-instruct", "llama-3.2-3b-instruct"])
        XCTAssertEqual(model(lms, "qwen2.5-vl-7b-instruct")?.capabilities.vision, true)
        XCTAssertEqual(model(lms, "llama-3.2-3b-instruct")?.capabilities.vision, false)
        XCTAssertEqual(model(lms, "llama-3.2-3b-instruct")?.capabilities.tools, true)
        XCTAssertEqual(mock.requestCount(containing: "/api/v1/models"), 1)
        XCTAssertEqual(mock.requestCount(containing: "/api/v0/models"), 1)
    }

    func testLMStudioLegacyV0() async {
        let mock = MockTransport()
        mock.live("http://127.0.0.1:1234")
        mock.on("http://127.0.0.1:1234/api/v0/models", json: """
        {"object":"list","data":[
          {"id":"qwen2-vl-7b-instruct","object":"model","type":"vlm","quantization":"4bit","state":"not-loaded","max_context_length":32768},
          {"id":"meta-llama-3.1-8b-instruct","object":"model","type":"llm","state":"loaded","max_context_length":131072,"capabilities":["tool_use"]},
          {"id":"text-embedding-nomic-embed-text-v1.5","object":"model","type":"embeddings","state":"not-loaded"}
        ]}
        """)
        let servers = await LocalServerDiscovery(transport: mock).scan(timeout: 2)
        guard let lms = servers.first else { return XCTFail("LM Studio v0 not found") }
        XCTAssertEqual(lms.kind, .lmStudio)
        XCTAssertEqual(lms.models.map(\.id), ["qwen2-vl-7b-instruct", "meta-llama-3.1-8b-instruct"])
        XCTAssertEqual(model(lms, "qwen2-vl-7b-instruct")?.capabilities.vision, true)
        XCTAssertEqual(model(lms, "meta-llama-3.1-8b-instruct")?.capabilities.tools, true)
        XCTAssertEqual(model(lms, "meta-llama-3.1-8b-instruct")?.capabilities.contextWindow, 131072)
    }

    func testLMStudioAuthRequired() async {
        let mock = MockTransport()
        mock.on("http://127.0.0.1:1234/api/v1/models", status: 401, json: #"{"error":"Unauthorized"}"#)
        let servers = await LocalServerDiscovery(transport: mock).scan(timeout: 2)
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers.first?.kind, .lmStudio)
        XCTAssertEqual(servers.first?.requiresAuth, true)
        XCTAssertEqual(servers.first?.reachable, true)
        XCTAssertEqual(servers.first?.models.isEmpty, true)
    }

    // MARK: llama.cpp

    func testLlamaCppBothPorts() async {
        let mock = MockTransport()
        mock.on("http://127.0.0.1:9931/health", json: #"{"status":"ok"}"#)
        mock.on("http://127.0.0.1:9931/v1/models", json: """
        {"object":"list","data":[{"id":"Qwen3-VL-4B-Instruct-Q4_K_M.gguf","object":"model","created":1,"owned_by":"llamacpp",
          "meta":{"vocab_type":2,"n_vocab":151936,"n_ctx_train":262144,"n_embd":2560,"n_params":4000000000,"size":2500000000},
          "architecture":{"input_modalities":["text","image"],"output_modalities":["text"]}}]}
        """)
        mock.on("http://127.0.0.1:9931/props", json: """
        {"default_generation_settings":{"n_ctx":16384},"total_slots":1,"model_path":"/models/Qwen3-VL-4B-Instruct-Q4_K_M.gguf",
         "modalities":{"vision":true,"audio":false},"build_info":"b11935-814f603"}
        """)
        mock.on("http://127.0.0.1:8080/health", json: #"{"status":"ok"}"#)
        mock.on("http://127.0.0.1:8080/v1/models", json: """
        {"object":"list","data":[{"id":"/home/me/models/llama-3.2-3b-instruct-q4_k_m.gguf","object":"model","owned_by":"llamacpp",
          "meta":{"n_ctx_train":131072}}]}
        """)

        let servers = await LocalServerDiscovery(transport: mock).scan(timeout: 2)
        XCTAssertEqual(servers.map(\.id), ["llamacpp@127.0.0.1:9931", "llamacpp@127.0.0.1:8080"])
        XCTAssertEqual(servers.map(\.kind), [.llamaCpp, .llamaCpp])
        guard servers.count == 2 else { return }

        let current = servers[0]
        XCTAssertEqual(current.name, "llama.cpp server")
        XCTAssertEqual(current.baseURL.absoluteString, "http://127.0.0.1:9931/v1")
        XCTAssertEqual(current.apiStyle, .openai)
        XCTAssertEqual(current.version, "b11935-814f603")
        let vl = current.models.first
        XCTAssertEqual(vl?.id, "Qwen3-VL-4B-Instruct-Q4_K_M.gguf")
        XCTAssertEqual(vl?.displayName, "Qwen3-VL-4B-Instruct-Q4_K_M", "/props model_path names the model")
        XCTAssertEqual(vl?.capabilities.vision, true)
        XCTAssertEqual(vl?.capabilities.contextWindow, 16384, "runtime n_ctx beats n_ctx_train")

        let legacy = servers[1]
        XCTAssertEqual(legacy.name, "llama.cpp server (port 8080)")
        XCTAssertEqual(legacy.baseURL.absoluteString, "http://127.0.0.1:8080/v1")
        let llama = legacy.models.first
        XCTAssertEqual(llama?.displayName, "llama-3.2-3b-instruct-q4_k_m")
        XCTAssertEqual(llama?.capabilities.vision, false)
        XCTAssertEqual(llama?.capabilities.tools, true)
        XCTAssertEqual(llama?.capabilities.contextWindow, 131072)
    }

    func testLlamaCppLoadingModel() async {
        let mock = MockTransport()
        mock.on("http://127.0.0.1:9931/health", status: 503,
                json: #"{"error":{"code":503,"message":"Loading model","type":"unavailable_error"}}"#)
        let servers = await LocalServerDiscovery(transport: mock).scan(timeout: 2)
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers.first?.kind, .llamaCpp)
        XCTAssertEqual(servers.first?.loading, true)
        XCTAssertEqual(servers.first?.models.isEmpty, true)
    }

    func testLlamaCppRouterMode() async {
        let mock = MockTransport()
        mock.on("http://127.0.0.1:9931/health", json: #"{"status":"ok"}"#)
        mock.on("http://127.0.0.1:9931/v1/models", json: #"{"object":"list","data":[]}"#)
        mock.on("http://127.0.0.1:9931/models", json: """
        {"data":[{"id":"qwen3-4b","path":"/m/qwen3-4b.gguf","status":{"value":"loaded"}},
                 {"id":"gemma-3-4b","path":"/m/gemma-3-4b.gguf","status":{"value":"unloaded"},"architecture":{"input_modalities":["text","image"]}}]}
        """)
        let servers = await LocalServerDiscovery(transport: mock).scan(timeout: 2)
        guard let server = servers.first else { return XCTFail("router-mode llama-server not found") }
        XCTAssertEqual(server.kind, .llamaCpp)
        XCTAssertEqual(server.models.map(\.id), ["qwen3-4b", "gemma-3-4b"])
        XCTAssertEqual(model(server, "gemma-3-4b")?.capabilities.vision, true)
        XCTAssertEqual(model(server, "qwen3-4b")?.notes, "loaded")
    }

    // MARK: Other servers

    func testVLLMKoboldCppAndJan() async {
        let mock = MockTransport()
        mock.on("http://127.0.0.1:8000/v1/models", json: """
        {"object":"list","data":[{"id":"Qwen/Qwen3-4B-Instruct-2507","object":"model","created":1,"owned_by":"vllm",
          "root":"Qwen/Qwen3-4B-Instruct-2507","parent":null,"max_model_len":32768}]}
        """)
        mock.on("http://127.0.0.1:5001/v1/models", json: """
        {"object":"list","data":[{"id":"koboldcpp/Mistral-7B-Instruct","object":"model","created":1,"owned_by":"koboldcpp",
          "permission":[],"root":"koboldcpp"}]}
        """)
        mock.on("http://127.0.0.1:1337/v1/models", json: """
        {"object":"list","data":[{"id":"llama3.2-3b-instruct","object":"model","owned_by":"user"}]}
        """)
        let servers = await LocalServerDiscovery(transport: mock).scan(timeout: 2)
        XCTAssertEqual(servers.map(\.kind), [.jan, .vllm, .koboldCpp], "endpoint order: 1337, 8000, 5001")
        let vllm = servers.first(where: { $0.kind == .vllm })
        XCTAssertEqual(vllm?.baseURL.absoluteString, "http://127.0.0.1:8000/v1")
        XCTAssertEqual(vllm?.models.first?.capabilities.contextWindow, 32768)
        XCTAssertEqual(servers.first(where: { $0.kind == .koboldCpp })?.models.first?.id, "koboldcpp/Mistral-7B-Instruct")
        XCTAssertEqual(servers.first(where: { $0.kind == .jan })?.baseURL.absoluteString, "http://127.0.0.1:1337/v1")
        XCTAssertEqual(servers.first(where: { $0.kind == .jan })?.providerID, "jan")
    }

    func testShapeBeatsPort() async {
        // llama-server started with --port 8000 is reported as llama.cpp, not vLLM.
        let mock = MockTransport()
        mock.on("http://127.0.0.1:8000/v1/models", json: """
        {"object":"list","data":[{"id":"phi-4-mini.gguf","object":"model","owned_by":"llamacpp","meta":{"n_ctx_train":131072}}]}
        """)
        let servers = await LocalServerDiscovery(transport: mock).scan(timeout: 2)
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers.first?.kind, .llamaCpp)
        XCTAssertEqual(servers.first?.id, "llamacpp@127.0.0.1:8000")
        XCTAssertEqual(servers.first?.name, "llama.cpp server (port 8000)")
    }

    // MARK: Unreachable / unrecognised / slow

    func testNothingRunningFindsNothing() async {
        let mock = MockTransport()
        let discovery = LocalServerDiscovery(transport: mock)
        let servers = await discovery.scan(timeout: 2)
        XCTAssertTrue(servers.isEmpty)
        let last = await discovery.lastScan
        XCTAssertTrue(last.isEmpty)
        // One request per default endpoint: a refused connection stops further probing of that port.
        XCTAssertEqual(mock.requests.count, LocalServerDiscovery.defaultEndpoints.count)
    }

    func testUnrecognisedServersAreExcluded() async {
        let mock = MockTransport()
        // A web dev server on 8080 that answers every path with HTML, and an app on 8000 with a bare /health.
        for path in ["/health", "/v1/models", "/props", "/models"] {
            mock.on("http://127.0.0.1:8080\(path)", json: "<html><body>dev server</body></html>")
        }
        mock.on("http://127.0.0.1:8000/health", json: #"{"status":"ok"}"#)
        mock.on("http://127.0.0.1:11434/api/tags", json: #"{"models":[]}"#)   // real Ollama, nothing pulled
        let servers = await LocalServerDiscovery(transport: mock).scan(timeout: 2)
        XCTAssertEqual(servers.map(\.id), ["ollama@127.0.0.1:11434"])
        XCTAssertEqual(servers.first?.models.isEmpty, true)
    }

    func testSlowServerTimesOut() async {
        let mock = MockTransport()
        mock.on("http://127.0.0.1:11434/api/tags", json: #"{"models":[]}"#, delay: 5)
        mock.on("http://127.0.0.1:1337/v1/models", json: #"{"object":"list","data":[{"id":"m"}]}"#)
        let start = Date()
        let servers = await LocalServerDiscovery(transport: mock).scan(timeout: 0.2)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(servers.map(\.kind), [.jan], "the slow Ollama is dropped, the fast Jan kept")
        XCTAssertLessThan(elapsed, 3, "scan must not wait for the slow server")
    }

    // MARK: Custom endpoints

    func testCustomLANEndpointIdentifiedByShape() async {
        let mock = MockTransport()
        mock.live("http://192.168.1.50:11434")
        mock.on("http://192.168.1.50:11434/api/tags", json: """
        {"models":[{"name":"gemma3:4b","model":"gemma3:4b","size":3338801804,"details":{"parameter_size":"4.3B","quantization_level":"Q4_K_M"}}]}
        """)
        guard let endpoint = LocalEndpoint(string: "http://192.168.1.50:11434") else { return XCTFail("parse") }
        let discovery = LocalServerDiscovery(transport: mock, customEndpoints: [endpoint])
        let servers = await discovery.scan(timeout: 2)
        XCTAssertEqual(servers.count, 1)
        guard let server = servers.first else { return }
        XCTAssertEqual(server.kind, .ollama)
        XCTAssertEqual(server.id, "ollama@192.168.1.50:11434")
        XCTAssertEqual(server.name, "Ollama @ 192.168.1.50:11434")
        XCTAssertEqual(server.baseURL.absoluteString, "http://192.168.1.50:11434")
        let gemma = server.models.first
        XCTAssertEqual(gemma?.capabilities.vision, true, "gemma3 4b takes images")
        XCTAssertEqual(gemma?.capabilities.tools, false)
    }

    func testProbeReportsUnreachableEndpoint() async {
        let discovery = LocalServerDiscovery(transport: MockTransport())
        let endpoint = LocalEndpoint(host: "10.0.0.9", port: 9999)
        let server = await discovery.probe(endpoint, timeout: 1)
        XCTAssertFalse(server.reachable)
        XCTAssertEqual(server.kind, .openAICompatible)
        XCTAssertEqual(server.baseURL.absoluteString, "http://10.0.0.9:9999/v1")
        XCTAssertTrue(server.models.isEmpty)
    }

    func testCustomEndpointSendsBearerToken() async {
        let mock = MockTransport()
        mock.on("http://127.0.0.1:1337/v1/models", json: #"{"object":"list","data":[{"id":"llama3.2-3b-instruct"}]}"#)
        let endpoint = LocalEndpoint(port: 1337, kindHint: .jan, apiKey: "secret")
        let server = await LocalServerDiscovery(transport: mock, includeDefaults: false).probe(endpoint, timeout: 2)
        XCTAssertTrue(server.reachable)
        XCTAssertEqual(mock.requests.first?.headers["Authorization"], "Bearer secret")
    }

    func testEndpointsDeduplicateLocalhost() async {
        guard let custom = LocalEndpoint(string: "localhost:11434") else { return XCTFail("parse") }
        let discovery = LocalServerDiscovery(transport: MockTransport(), customEndpoints: [custom])
        let endpoints = await discovery.endpoints
        XCTAssertEqual(endpoints.count, LocalServerDiscovery.defaultEndpoints.count)
        XCTAssertEqual(endpoints.first?.host, "localhost")
        XCTAssertEqual(endpoints.first?.kindHint, .ollama, "the default's hint survives the merge")
    }

    func testEndpointParsing() throws {
        let lan = try XCTUnwrap(LocalEndpoint(string: "https://192.168.1.5:1234/v1"))
        XCTAssertEqual(lan.scheme, "https")
        XCTAssertEqual(lan.host, "192.168.1.5")
        XCTAssertEqual(lan.port, 1234)
        XCTAssertEqual(LocalEndpoint(string: "ollama.local", kindHint: .ollama)?.port, 11434)
        XCTAssertNil(LocalEndpoint(string: "myhost"), "no port and no hint")
        XCTAssertNil(LocalEndpoint(string: "ftp://x:21"))
        XCTAssertNil(LocalEndpoint(string: "   "))
        XCTAssertNil(LocalEndpoint(string: "host:70000"))
    }

    func testEndpointCodableDropsAPIKey() throws {
        let endpoint = LocalEndpoint(host: "192.168.1.5", port: 1234, kindHint: .lmStudio, apiKey: "secret")
        let data = try JSONEncoder().encode(endpoint)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret"))
        let decoded = try JSONDecoder().decode(LocalEndpoint.self, from: data)
        XCTAssertNil(decoded.apiKey)
        XCTAssertEqual(decoded.port, 1234)
        XCTAssertEqual(decoded.kindHint, .lmStudio)
    }

    func testKindsMatchProviderCatalogueIDs() {
        XCTAssertEqual(LocalServerKind.ollama.providerID, "ollama")
        XCTAssertEqual(LocalServerKind.lmStudio.providerID, "lmstudio")
        XCTAssertEqual(LocalServerKind.llamaCpp.providerID, "llamacpp")
        XCTAssertEqual(LocalServerKind.koboldCpp.providerID, "koboldcpp")
        XCTAssertEqual(LocalServerKind.llamaCpp.defaultPorts, [9931, 8080])
    }
}

final class LocalModelHeuristicsTests: XCTestCase {
    func testVision() {
        for name in ["qwen3-vl:4b", "qwen2.5vl:7b", "llava:7b", "llama3.2-vision:11b", "gemma3:4b", "gemma3:27b",
                     "mlx-community/Qwen3-VL-4B-Instruct-4bit", "internvl3-8b", "minicpm-v:8b", "gemma-4-e2b-it",
                     "mlx-community/Qwen3.5-2B-4bit", "UI-TARS-1.5-7B", "LFM2.5-VL-1.6B"] {
            XCTAssertTrue(LocalModelHeuristics.likelyVision(name), name)
        }
        for name in ["qwen3:4b", "llama3.2:3b", "gemma3:1b", "gemma3n:e4b", "devstral:24b", "phi4-mini",
                     "mlx-community/gemma-3n-E2B-it-lm-4bit", "nomic-embed-text", "mistral:7b", "LFM2-1.2B"] {
            XCTAssertFalse(LocalModelHeuristics.likelyVision(name), name)
        }
    }

    func testTools() {
        for name in ["qwen3:4b", "llama3.1:8b", "qwen3-vl:4b", "mistral-nemo", "gemma4:e4b", "phi4-mini"] {
            XCTAssertTrue(LocalModelHeuristics.likelyTools(name), name)
        }
        for name in ["llava:7b", "gemma3:4b", "nomic-embed-text", "bge-m3", "qwen2.5-coder:7b-base", "UI-TARS-1.5-7B"] {
            XCTAssertFalse(LocalModelHeuristics.likelyTools(name), name)
        }
    }

    func testEmbedding() {
        XCTAssertTrue(LocalModelHeuristics.isEmbeddingModel("nomic-embed-text:latest"))
        XCTAssertTrue(LocalModelHeuristics.isEmbeddingModel("mxbai-embed-large"))
        XCTAssertTrue(LocalModelHeuristics.isEmbeddingModel("bge-m3"))
        XCTAssertFalse(LocalModelHeuristics.isEmbeddingModel("qwen3:4b"))
    }
}
