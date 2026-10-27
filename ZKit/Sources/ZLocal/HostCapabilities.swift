import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// What this machine can run locally: memory, CPU, Apple silicon, free disk where models live.
public struct HostCapabilities: Sendable, Hashable, Codable {
    public enum Architecture: String, Sendable, Hashable, Codable {
        case arm64
        case x86_64
        case other
    }

    /// Why a model does not fit.
    public enum FitIssue: Sendable, Hashable, CustomStringConvertible {
        /// MLX runs on Apple-silicon GPUs only.
        case notAppleSilicon
        case insufficientRAM(requiredGB: Int, availableGB: Int)
        case insufficientDisk(requiredBytes: Int64, availableBytes: Int64)

        public var description: String {
            switch self {
            case .notAppleSilicon:
                return "Needs an Apple-silicon Mac"
            case .insufficientRAM(let need, let have):
                return "Needs \(need) GB of memory (this Mac has \(have) GB)"
            case .insufficientDisk(let need, let have):
                return String(format: "Needs %.1f GB of free disk (%.1f GB free)", Double(need) / 1e9, Double(have) / 1e9)
            }
        }
    }

    public var physicalMemoryBytes: UInt64
    /// Architecture this process runs as (x86_64 under Rosetta).
    public var architecture: Architecture
    /// True on Apple-silicon Macs, also when this process runs under Rosetta.
    public var isAppleSilicon: Bool
    public var processorCount: Int
    /// Free bytes on the volume holding the models root, when known.
    public var availableDiskBytes: Int64?

    public init(physicalMemoryBytes: UInt64, architecture: Architecture, isAppleSilicon: Bool,
                processorCount: Int = 1, availableDiskBytes: Int64? = nil) {
        self.physicalMemoryBytes = physicalMemoryBytes; self.architecture = architecture
        self.isAppleSilicon = isAppleSilicon; self.processorCount = processorCount; self.availableDiskBytes = availableDiskBytes
    }

    /// Memory in GiB, rounded to the nearest whole number (what Apple sells as "16 GB" reads 16).
    public var ramGB: Int { Int((Double(physicalMemoryBytes) / 1_073_741_824).rounded()) }

    /// Extra free disk demanded beyond the model's download size (temp files, partial downloads).
    public static let diskHeadroomFactor = 1.1

    /// Reasons `model` cannot run here; empty when it fits.
    public func fitIssues(model: LocalModelSpec) -> [FitIssue] {
        var issues: [FitIssue] = []
        if !isAppleSilicon { issues.append(.notAppleSilicon) }
        if ramGB < model.minRAMGB { issues.append(.insufficientRAM(requiredGB: model.minRAMGB, availableGB: ramGB)) }
        if let free = availableDiskBytes {
            let need = Int64((Double(model.sizeBytes) * Self.diskHeadroomFactor).rounded(.up))
            if free < need { issues.append(.insufficientDisk(requiredBytes: need, availableBytes: free)) }
        }
        return issues
    }

    /// True when the model can be downloaded and run on this Mac.
    public func fits(model: LocalModelSpec) -> Bool { fitIssues(model: model).isEmpty }

    /// Curated models that fit this machine, best first.
    public func recommendedModels(includeExperimental: Bool = false) -> [LocalModelSpec] {
        LocalModelCatalog.recommended(forRAMGB: ramGB, includeExperimental: includeExperimental).filter { fits(model: $0) }
    }

    /// Reads the current machine. `modelsRoot` (or its nearest existing parent) is where free disk is measured.
    public static func current(modelsRoot: URL? = nil) -> HostCapabilities {
        HostCapabilities(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                         architecture: currentArchitecture,
                         isAppleSilicon: detectAppleSilicon(),
                         processorCount: ProcessInfo.processInfo.processorCount,
                         availableDiskBytes: modelsRoot.flatMap(availableDiskSpace(at:)))
    }

    static var currentArchitecture: Architecture {
        #if arch(arm64)
        return .arm64
        #elseif arch(x86_64)
        return .x86_64
        #else
        return .other
        #endif
    }

    static func detectAppleSilicon() -> Bool {
        #if os(macOS)
        #if arch(arm64)
        return true
        #else
        // x86_64 build: Apple silicon under Rosetta still reports hw.optional.arm64 = 1.
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
        #endif
        #else
        return false
        #endif
    }

    /// Free bytes on the volume containing `url` (walks up to the nearest existing directory).
    public static func availableDiskSpace(at url: URL) -> Int64? {
        let fm = FileManager.default
        var dir = url.standardizedFileURL
        while !fm.fileExists(atPath: dir.path) {
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
        #if os(macOS)
        if let values = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let important = values.volumeAvailableCapacityForImportantUsage {
            return important
        }
        #endif
        guard let attrs = try? fm.attributesOfFileSystem(forPath: dir.path) else { return nil }
        let free = LocalModelStore.int64(attrs[.systemFreeSize])
        return free > 0 ? free : nil
    }
}
