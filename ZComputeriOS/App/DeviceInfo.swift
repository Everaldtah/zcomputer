import Foundation
import os
import ZLocal

/// What this iPhone or iPad can run: ZLocal's `HostCapabilities` adjusted for iOS, and the app's memory budget.
enum DeviceInfo {
    /// `HostCapabilities` for this device. Every device that runs iOS 17 has an Apple GPU that MLX can use
    /// (ZLocal's detection only answers yes on Macs).
    static func capabilities(modelsRoot: URL) -> HostCapabilities {
        var host = HostCapabilities.current(modelsRoot: modelsRoot)
        #if targetEnvironment(simulator)
        host.isAppleSilicon = host.architecture == .arm64
        #else
        host.isAppleSilicon = true
        #endif
        return host
    }

    /// Memory this app may still allocate before iOS ends it (with the increased-memory-limit entitlement this is
    /// a few GB on recent iPhones; 0 when unknown, e.g. in the simulator).
    static var availableMemoryBytes: Int64 {
        Int64(os_proc_available_memory())
    }

    /// The working budget for an in-app model: what the app may allocate now plus what it already uses would be the
    /// cap; we only know "available now", which is what matters before loading.
    static func memoryWarning(forModelBytes bytes: Int64) -> String? {
        let available = availableMemoryBytes
        guard available > 0 else { return nil }
        // Weights plus KV cache and activations: about 1.3x the download, plus 0.5 GB for the app and a machine.
        let needed = Int64(Double(bytes) * 1.3) + 500_000_000
        guard needed > available else { return nil }
        return "Likely too large for this device right now: needs about \(Format.bytes(needed)), the app can use "
            + "\(Format.bytes(available)). Stop running machines or pick a smaller model."
    }

    static var deviceKind: String {
        #if targetEnvironment(simulator)
        return "Simulator"
        #else
        return ProcessInfo.processInfo.isiOSAppOnMac ? "Mac" : "iPhone or iPad"
        #endif
    }
}
