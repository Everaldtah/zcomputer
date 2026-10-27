import Foundation
import XCTest
import ZCore
@testable import ZLocal

final class LocalModelCatalogTests: XCTestCase {

    func testIDsAreUniqueAndWellFormed() throws {
        let ids = LocalModelCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate ids")
        XCTAssertEqual(LocalModelCatalog.models.count, 17)
        XCTAssertEqual(LocalModelCatalog.embedders.count, 3)
        for id in ids {
            XCTAssertNoThrow(try LocalModelStore.splitRepoID(id), id)
        }
        let priorities = LocalModelCatalog.models.map(\.priority)
        XCTAssertEqual(Set(priorities).count, priorities.count, "chat priorities must be a strict order")
    }

    func testSizesAndRAMTiers() {
        for spec in LocalModelCatalog.all {
            XCTAssertGreaterThan(spec.sizeGB, 0, spec.id)
            XCTAssertGreaterThan(spec.sizeBytes, 0, spec.id)
            XCTAssertTrue(LocalModelCatalog.ramTiers.contains(spec.minRAMGB), spec.id)
            XCTAssertEqual(spec.minRAMGB, LocalModelCatalog.heuristicMinRAMGB(sizeGB: spec.sizeGB, vision: spec.vision),
                           "minRAMGB follows the B6 heuristic for \(spec.id)")
            XCTAssertFalse(spec.name.isEmpty)
            XCTAssertFalse(spec.family.isEmpty)
            XCTAssertFalse(spec.quantization.isEmpty)
        }
    }

    func testEveryVisionModelHasAVisionFamily() {
        for spec in LocalModelCatalog.all where spec.vision {
            XCTAssertTrue(LocalModelCatalog.visionFamilies.contains(spec.family), "\(spec.id) family \(spec.family)")
        }
        for spec in LocalModelCatalog.all where !spec.vision {
            XCTAssertNil(spec.coordinateSpace, "\(spec.id): coordinate space is for vision models only")
        }
        // ...and the text-only Gemma 3n is not one.
        XCTAssertFalse(LocalModelCatalog.visionFamilies.contains("gemma3n"))
        XCTAssertEqual(LocalModelCatalog.byID("mlx-community/Qwen3-VL-4B-Instruct-4bit")?.coordinateSpace, .normalized1000)
    }

    func testEmbeddersAreEmbeddings() {
        for spec in LocalModelCatalog.embedders {
            XCTAssertEqual(spec.kind, .embedding)
            XCTAssertFalse(spec.vision)
            XCTAssertTrue(LocalModelCatalog.embedderFamilies.contains(spec.family), spec.id)
        }
        XCTAssertTrue(LocalModelCatalog.models.allSatisfy { $0.kind == .chat })
        XCTAssertEqual(LocalModelCatalog.defaultEmbedder(forRAMGB: 8)?.id, "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ")
    }

    func testRecommendedOrdering() {
        let eight = LocalModelCatalog.recommended(forRAMGB: 8)
        XCTAssertEqual(eight.map(\.id), ["mlx-community/Qwen3-1.7B-4bit", "mlx-community/LFM2-1.2B-4bit",
                                         "mlx-community/Qwen3-0.6B-4bit"])

        let sixteen = LocalModelCatalog.recommended(forRAMGB: 16)
        XCTAssertEqual(sixteen.first?.id, "mlx-community/Qwen3-4B-Instruct-2507-4bit")
        XCTAssertEqual(sixteen.dropFirst().first?.id, "mlx-community/Qwen3-VL-4B-Instruct-4bit")
        XCTAssertTrue(sixteen.allSatisfy { $0.minRAMGB <= 16 })
        XCTAssertFalse(sixteen.contains { $0.id == "mlx-community/Qwen3-VL-8B-Instruct-4bit" }, "needs 24 GB")
        XCTAssertFalse(sixteen.contains { $0.experimental }, "UI-TARS is hidden by default")
        XCTAssertEqual(sixteen.map(\.priority), sixteen.map(\.priority).sorted())

        let all = LocalModelCatalog.recommended(forRAMGB: 64, includeExperimental: true)
        XCTAssertEqual(all.count, LocalModelCatalog.models.count)
        XCTAssertTrue(LocalModelCatalog.recommended(forRAMGB: 4).isEmpty)
        // More memory never removes a model.
        XCTAssertTrue(Set(eight.map(\.id)).isSubset(of: Set(sixteen.map(\.id))))
    }

    func testDefaults() {
        XCTAssertEqual(LocalModelCatalog.defaultTextModel(forRAMGB: 8)?.id, "mlx-community/Qwen3-1.7B-4bit")
        XCTAssertEqual(LocalModelCatalog.defaultTextModel(forRAMGB: 16)?.id, "mlx-community/Qwen3-4B-Instruct-2507-4bit")
        XCTAssertEqual(LocalModelCatalog.defaultVisionModel(forRAMGB: 16)?.id, "mlx-community/Qwen3-VL-4B-Instruct-4bit")
        XCTAssertNil(LocalModelCatalog.defaultVisionModel(forRAMGB: 8))
    }

    func testVisionCapableAndByID() {
        let vision = LocalModelCatalog.visionCapable
        XCTAssertFalse(vision.isEmpty)
        XCTAssertTrue(vision.allSatisfy(\.vision))
        XCTAssertEqual(vision.first?.id, "mlx-community/Qwen3-VL-4B-Instruct-4bit")
        XCTAssertEqual(vision.count, LocalModelCatalog.models.filter(\.vision).count)

        XCTAssertEqual(LocalModelCatalog.byID("mlx-community/Qwen3-1.7B-4bit")?.name, "Qwen3 1.7B")
        XCTAssertEqual(LocalModelCatalog.byID("MLX-COMMUNITY/qwen3-1.7b-4bit")?.id, "mlx-community/Qwen3-1.7B-4bit")
        XCTAssertEqual(LocalModelCatalog.byID("BAAI/bge-small-en-v1.5")?.kind, .embedding)
        XCTAssertNil(LocalModelCatalog.byID("nope/nothing"))
    }

    func testModelInfoMapping() throws {
        let spec = try XCTUnwrap(LocalModelCatalog.byID("mlx-community/Qwen3.5-2B-4bit"))
        let info = spec.modelInfo
        XCTAssertEqual(info.id, spec.id)
        XCTAssertEqual(info.displayName, "Qwen3.5 2B")
        XCTAssertTrue(info.capabilities.vision)
        XCTAssertTrue(info.capabilities.tools)
        XCTAssertTrue(info.free)
        XCTAssertEqual(spec.modelRef, ModelRef(provider: "mlx", model: spec.id))
        XCTAssertEqual(spec.organization, "mlx-community")
        XCTAssertEqual(spec.repository, "Qwen3.5-2B-4bit")
    }

    func testMLXPins() {
        let primary = MLXPins.packages(.primary)
        func version(_ name: String, _ set: [MLXPins.Package]) -> String? { set.first(where: { $0.name == name })?.exactVersion }
        XCTAssertEqual(version("mlx-swift-lm", primary), "3.32.3")
        XCTAssertEqual(version("mlx-swift", primary), "0.32.3")
        XCTAssertEqual(version("swift-huggingface", primary), "1.0.0")
        XCTAssertEqual(version("swift-transformers", primary), "1.3.5")
        let fallback = MLXPins.packages(.fallback)
        XCTAssertEqual(version("mlx-swift-lm", fallback), "3.31.4")
        XCTAssertEqual(version("mlx-swift", fallback), "0.31.4")
        XCTAssertEqual(version("swift-transformers", fallback), "1.3.5")

        let yaml = MLXPins.xcodegenPackagesYAML()
        XCTAssertTrue(yaml.hasPrefix("packages:\n"))
        XCTAssertTrue(yaml.contains("  mlx-swift-lm:\n    url: https://github.com/ml-explore/mlx-swift-lm\n    exactVersion: 3.32.3"))
        XCTAssertTrue(yaml.contains("url: https://github.com/huggingface/swift-transformers"))
        XCTAssertTrue(MLXPins.xcodegenPackagesYAML(.fallback).contains("exactVersion: 0.31.4"))

        let deps = MLXPins.xcodegenDependenciesYAML(indent: 2)
        XCTAssertTrue(deps.contains("  - package: mlx-swift-lm\n    product: MLXVLM"))
        XCTAssertTrue(deps.contains("product: Tokenizers"))
        XCTAssertFalse(deps.contains("package: mlx-swift\n"), "mlx-swift is pinned, not linked directly")
    }
}

final class HostCapabilitiesTests: XCTestCase {
    private let gib: UInt64 = 1_073_741_824

    func testFits() throws {
        let small = try XCTUnwrap(LocalModelCatalog.byID("mlx-community/Qwen3-1.7B-4bit"))
        let big = try XCTUnwrap(LocalModelCatalog.byID("mlx-community/Qwen3-VL-8B-Instruct-4bit"))

        let mac8 = HostCapabilities(physicalMemoryBytes: 8 * gib, architecture: .arm64, isAppleSilicon: true,
                                    availableDiskBytes: 100_000_000_000)
        XCTAssertEqual(mac8.ramGB, 8)
        XCTAssertTrue(mac8.fits(model: small))
        XCTAssertFalse(mac8.fits(model: big))
        XCTAssertEqual(mac8.fitIssues(model: big), [.insufficientRAM(requiredGB: 24, availableGB: 8)])

        let mac32 = HostCapabilities(physicalMemoryBytes: 32 * gib, architecture: .arm64, isAppleSilicon: true)
        XCTAssertTrue(mac32.fits(model: big), "unknown disk space does not block")

        let intel = HostCapabilities(physicalMemoryBytes: 64 * gib, architecture: .x86_64, isAppleSilicon: false)
        XCTAssertEqual(intel.fitIssues(model: small), [.notAppleSilicon])
        XCTAssertTrue(intel.recommendedModels().isEmpty)

        let fullDisk = HostCapabilities(physicalMemoryBytes: 16 * gib, architecture: .arm64, isAppleSilicon: true,
                                        availableDiskBytes: 500_000_000)
        XCTAssertFalse(fullDisk.fits(model: small))
        guard case .insufficientDisk(let need, let have)? = fullDisk.fitIssues(model: small).first else {
            return XCTFail("expected a disk issue")
        }
        XCTAssertGreaterThan(need, small.sizeBytes)
        XCTAssertEqual(have, 500_000_000)
        XCTAssertFalse(fullDisk.fitIssues(model: small).first?.description.isEmpty ?? true)

        let mac16 = HostCapabilities(physicalMemoryBytes: 16 * gib, architecture: .arm64, isAppleSilicon: true)
        XCTAssertEqual(mac16.recommendedModels().first?.id, "mlx-community/Qwen3-4B-Instruct-2507-4bit")
    }

    func testCurrentMachine() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("zlocal-not-created-\(UUID().uuidString)/Models")
        let host = HostCapabilities.current(modelsRoot: tmp)
        XCTAssertGreaterThan(host.physicalMemoryBytes, 0)
        XCTAssertGreaterThan(host.processorCount, 0)
        XCTAssertNotNil(host.availableDiskBytes, "measured on the nearest existing parent")
        #if os(Linux)
        XCTAssertFalse(host.isAppleSilicon)
        #endif
        #if arch(x86_64)
        XCTAssertEqual(host.architecture, .x86_64)
        #elseif arch(arm64)
        XCTAssertEqual(host.architecture, .arm64)
        #endif
    }
}
