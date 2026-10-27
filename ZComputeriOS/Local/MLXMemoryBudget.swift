#if ZC_MLX
import Foundation
import MLX

/// MLX settings for a phone's memory limit (pattern from Synapse): a small buffer cache keeps the GPU allocator
/// well under the app's limit, so the weights and the KV cache get the room.
enum MLXMemoryBudget {
    static func applyForPhone() {
        Memory.cacheLimit = 20 * 1024 * 1024
    }

    /// Releases cached GPU buffers (when the app is backgrounded or memory runs low).
    static func trim() {
        Memory.clearCache()
    }
}
#endif
