import Foundation
import XCTest
import ZCore
@testable import ZLocal

final class LocalModelStoreTests: XCTestCase {
    private var root = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zlocal-store-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func write(_ relative: String, bytes: Int) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: bytes).write(to: url)
    }

    // MARK: Tracking

    func testInstalledSizesAndDelete() async throws {
        try write("mlx-community/Qwen3-1.7B-4bit/config.json", bytes: 100)
        try write("mlx-community/Qwen3-1.7B-4bit/model.safetensors", bytes: 4_000)
        try write("mlx-community/Qwen3-1.7B-4bit/tokenizer.json", bytes: 900)
        try write("someone/custom-model/config.json", bytes: 10)
        try write("someone/custom-model/model-00001-of-00002.safetensors", bytes: 50)
        // Not models: no weights, hidden folder, stray file at the org level.
        try write("someone/notes-only/README.md", bytes: 5)
        try write(".cache/x/config.json", bytes: 5)
        try write("someone/stray.txt", bytes: 5)

        let store = LocalModelStore(root: root, transport: MockTransport())
        let installed = await store.installed
        XCTAssertEqual(installed.map(\.id), ["mlx-community/Qwen3-1.7B-4bit", "someone/custom-model"])
        XCTAssertEqual(installed.first?.sizeBytes, 5_000)
        XCTAssertEqual(installed.first?.spec?.name, "Qwen3 1.7B", "curated models carry their catalogue entry")
        XCTAssertNil(installed.last?.spec)
        XCTAssertTrue(installed.allSatisfy(\.isComplete))

        let isInstalled = await store.isInstalled("mlx-community/Qwen3-1.7B-4bit")
        XCTAssertTrue(isInstalled)
        let size = await store.sizeOnDisk(id: "someone/custom-model")
        XCTAssertEqual(size, 60)
        let total = await store.totalSizeOnDisk()
        XCTAssertGreaterThanOrEqual(total, 5_060)

        try await store.delete(id: "someone/custom-model")
        let afterDelete = await store.installed
        XCTAssertEqual(afterDelete.map(\.id), ["mlx-community/Qwen3-1.7B-4bit"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("someone").path),
                      "org folder kept while it still has content")

        try await store.delete(id: "mlx-community/Qwen3-1.7B-4bit")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("mlx-community").path),
                       "empty org folder removed")
        let empty = await store.installed
        XCTAssertTrue(empty.isEmpty)

        do {
            try await store.delete(id: "mlx-community/Qwen3-1.7B-4bit")
            XCTFail("deleting a missing model must throw")
        } catch let error as ZError {
            guard case .notFound = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testIncompleteDownloadsAreTrackedSeparately() async throws {
        let store = LocalModelStore(root: root, transport: MockTransport())
        let dir = try await store.prepareDirectory(for: "mlx-community/Qwen3-0.6B-4bit")
        XCTAssertEqual(dir.lastPathComponent, "Qwen3-0.6B-4bit")
        try Data(repeating: 1, count: 10).write(to: dir.appendingPathComponent("config.json"))
        try Data(repeating: 1, count: 20).write(to: dir.appendingPathComponent("model.safetensors"))

        var installed = await store.installed
        XCTAssertTrue(installed.isEmpty, "marker present: still downloading")
        let incomplete = await store.incomplete
        XCTAssertEqual(incomplete.map(\.id), ["mlx-community/Qwen3-0.6B-4bit"])
        XCTAssertEqual(incomplete.first?.isComplete, false)

        try await store.markInstalled(id: "mlx-community/Qwen3-0.6B-4bit")
        installed = await store.installed
        XCTAssertEqual(installed.map(\.id), ["mlx-community/Qwen3-0.6B-4bit"])
        XCTAssertEqual(installed.first?.sizeBytes, 30)
    }

    func testMarkInstalledChecksThePlan() async throws {
        let store = LocalModelStore(root: root, transport: MockTransport())
        let id = "mlx-community/LFM2-1.2B-4bit"
        let dir = try await store.prepareDirectory(for: id)
        let plan = DownloadPlan(repoID: id, revision: "main", files: [
            DownloadPlan.File(path: "config.json", url: try XCTUnwrap(URL(string: "https://huggingface.co/x/config.json")), sizeBytes: 10),
            DownloadPlan.File(path: "model.safetensors", url: try XCTUnwrap(URL(string: "https://huggingface.co/x/m")), sizeBytes: 20),
        ], destination: dir)
        try Data(repeating: 1, count: 10).write(to: dir.appendingPathComponent("config.json"))
        try Data(repeating: 1, count: 5).write(to: dir.appendingPathComponent("model.safetensors"))   // truncated

        XCTAssertEqual(store.missingFiles(in: plan).map(\.path), ["model.safetensors"])
        do {
            try await store.markInstalled(id: id, plan: plan)
            XCTFail("a truncated file must block markInstalled")
        } catch {}

        try Data(repeating: 1, count: 20).write(to: dir.appendingPathComponent("model.safetensors"))
        XCTAssertTrue(store.missingFiles(in: plan).isEmpty)
        try await store.markInstalled(id: id, plan: plan)
        let ok = await store.isInstalled(id)
        XCTAssertTrue(ok)
    }

    func testRejectsUnsafeIDs() async {
        let store = LocalModelStore(root: root, transport: MockTransport())
        for bad in ["../etc", "a/../b", "org/..", "noslash", "a/b/c", "/abs", "org/", "./x", "org/.hidden", "or g/x"] {
            XCTAssertThrowsError(try LocalModelStore.splitRepoID(bad), bad)
            do {
                try await store.delete(id: bad)
                XCTFail("delete accepted \(bad)")
            } catch {}
        }
        XCTAssertNoThrow(try LocalModelStore.splitRepoID("mlx-community/Qwen3.5-2B-4bit"))
        XCTAssertNoThrow(try LocalModelStore.splitRepoID("BAAI/bge-small-en-v1.5"))
    }

    func testDefaultRootPath() throws {
        let url = try LocalModelStore.defaultRoot()
        XCTAssertEqual(url.lastPathComponent, "Models")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "ZComputer")
    }

    // MARK: Download plans

    func testDownloadPlanFiltersModelInfoListing() async throws {
        let mock = MockTransport()
        mock.on("https://huggingface.co/api/models/mlx-community/Qwen3-VL-4B-Instruct-4bit?blobs=true", json: """
        {"id":"mlx-community/Qwen3-VL-4B-Instruct-4bit","sha":"0123abcd","siblings":[
          {"rfilename":".gitattributes","size":1570},
          {"rfilename":"README.md","size":2100},
          {"rfilename":"chat_template.jinja","size":5300},
          {"rfilename":"config.json","size":1800},
          {"rfilename":"generation_config.json","size":214},
          {"rfilename":"merges.txt","size":1671853},
          {"rfilename":"model-00001-of-00002.safetensors","size":2000000000,"lfs":{"sha256":"aa11","size":2000000000,"pointerSize":135}},
          {"rfilename":"model-00002-of-00002.safetensors","size":1100000000,"lfs":{"sha256":"bb22","size":1100000000,"pointerSize":135}},
          {"rfilename":"model.safetensors.index.json","size":61000},
          {"rfilename":"preprocessor_config.json","size":390},
          {"rfilename":"tokenizer.json","size":11422654},
          {"rfilename":"tokenizer_config.json","size":5400},
          {"rfilename":"vocab.json","size":2776833},
          {"rfilename":"pytorch_model.bin","size":8000000000},
          {"rfilename":"model.gguf","size":3000000000},
          {"rfilename":"onnx/model.onnx","size":900000000},
          {"rfilename":"1_Pooling/config.json","size":190},
          {"rfilename":"assets/demo.png","size":30000}
        ]}
        """)
        let store = LocalModelStore(root: root, transport: mock)
        let plan = try await store.downloadPlan(for: "mlx-community/Qwen3-VL-4B-Instruct-4bit")

        XCTAssertEqual(plan.files.map(\.path), [
            "chat_template.jinja", "config.json", "generation_config.json", "merges.txt",
            "model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors", "model.safetensors.index.json",
            "preprocessor_config.json", "tokenizer.json", "tokenizer_config.json", "vocab.json",
        ])
        XCTAssertEqual(plan.revision, "0123abcd", "files are pinned to the listed commit")
        XCTAssertEqual(plan.files.first(where: { $0.path == "config.json" })?.url.absoluteString,
                       "https://huggingface.co/mlx-community/Qwen3-VL-4B-Instruct-4bit/resolve/0123abcd/config.json")
        XCTAssertEqual(plan.files.first(where: { $0.path.hasPrefix("model-00001") })?.sha256, "aa11")
        XCTAssertEqual(plan.totalBytes, 5300 + 1800 + 214 + 1_671_853 + 2_000_000_000 + 1_100_000_000 + 61000 + 390
                       + 11_422_654 + 5400 + 2_776_833)
        XCTAssertEqual(plan.destination.path, root.appendingPathComponent("mlx-community/Qwen3-VL-4B-Instruct-4bit").path)
        XCTAssertEqual(plan.localURL(for: plan.files[1]).lastPathComponent, "config.json")
        XCTAssertEqual(mock.requests.first?.headers["Accept"], "application/json")
    }

    func testDownloadPlanFromTreeListingWithRevisionAndToken() async throws {
        let mock = MockTransport()
        mock.on("https://huggingface.co/api/models/BAAI/bge-small-en-v1.5/revision/v1.0?blobs=true", json: """
        [
          {"type":"directory","oid":"d1","size":0,"path":"onnx"},
          {"type":"file","oid":"f1","size":743,"path":"config.json"},
          {"type":"file","oid":"f2","size":133466304,"path":"model.safetensors","lfs":{"oid":"cafe","size":133466304,"pointerSize":134}},
          {"type":"file","oid":"f3","size":133508397,"path":"pytorch_model.bin","lfs":{"oid":"beef","size":133508397,"pointerSize":134}},
          {"type":"file","oid":"f4","size":711396,"path":"tokenizer.json"},
          {"type":"file","oid":"f5","size":231508,"path":"vocab.txt"},
          {"type":"file","oid":"f6","size":125,"path":"special_tokens_map.json"},
          {"type":"file","oid":"f7","size":52,"path":".gitattributes"}
        ]
        """)
        let store = LocalModelStore(root: root, transport: mock)
        let plan = try await store.downloadPlan(for: "BAAI/bge-small-en-v1.5", revision: "v1.0", token: "hf_x")
        XCTAssertEqual(plan.files.map(\.path), ["config.json", "model.safetensors", "special_tokens_map.json",
                                                "tokenizer.json", "vocab.txt"])
        XCTAssertEqual(plan.revision, "v1.0")
        XCTAssertEqual(plan.files.first(where: { $0.path == "model.safetensors" })?.sha256, "cafe")
        XCTAssertEqual(plan.files.first(where: { $0.path == "vocab.txt" })?.url.absoluteString,
                       "https://huggingface.co/BAAI/bge-small-en-v1.5/resolve/v1.0/vocab.txt")
        XCTAssertEqual(mock.requests.first?.headers["Authorization"], "Bearer hf_x")
    }

    func testDownloadPlanErrors() async throws {
        let mock = MockTransport()
        mock.on("https://huggingface.co/api/models/org/missing?blobs=true", status: 404, json: #"{"error":"Repository not found"}"#)
        mock.on("https://huggingface.co/api/models/org/gated?blobs=true", status: 401, json: #"{"error":"Access to model org/gated is restricted"}"#)
        mock.on("https://huggingface.co/api/models/org/gguf-only?blobs=true", json: """
        {"sha":"1","siblings":[{"rfilename":"config.json"},{"rfilename":"model.Q4_K_M.gguf"}]}
        """)
        let store = LocalModelStore(root: root, transport: mock)

        await assertZError(.notFound("")) { _ = try await store.downloadPlan(for: "org/missing") }
        await assertZError(.http(status: 401, body: "")) { _ = try await store.downloadPlan(for: "org/gated") }
        await assertZError(.unsupported("")) { _ = try await store.downloadPlan(for: "org/gguf-only") }
        await assertZError(.invalidArgument("")) { _ = try await store.downloadPlan(for: "../../etc/passwd") }
        // huggingface.co not reachable at all.
        let offline = LocalModelStore(root: root, transport: MockTransport())
        await assertZError(.network("")) { _ = try await offline.downloadPlan(for: "org/any") }
    }

    func testModelFileFilter() {
        for keep in ["model.safetensors", "config.json", "tokenizer.json", "tokenizer_config.json", "tokenizer.model",
                     "chat_template.jinja", "vocab.txt", "merges.txt", "vocab.json", "qwen.tiktoken",
                     "model.safetensors.index.json", "preprocessor_config.json"] {
            XCTAssertTrue(LocalModelStore.isModelFile(keep), keep)
        }
        for drop in ["README.md", ".gitattributes", "pytorch_model.bin", "model.gguf", "onnx/model.onnx",
                     "1_Pooling/config.json", "images/a.png", "LICENSE", "model.npz"] {
            XCTAssertFalse(LocalModelStore.isModelFile(drop), drop)
        }
    }

    /// Asserts the closure throws a `ZError` with the same case as `expected` (payloads ignored).
    private func assertZError(_ expected: ZError, file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as ZError {
            XCTAssertEqual(Self.caseName(error), Self.caseName(expected), "\(error)", file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    private static func caseName(_ error: ZError) -> String {
        String(String(describing: error).prefix(while: { $0 != ":" }))
    }
}
