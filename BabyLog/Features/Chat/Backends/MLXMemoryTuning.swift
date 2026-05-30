import Foundation
import MLX
import Metal

/// Centralised MLX GPU memory tuning for the on-device chat backends.
///
/// **Why this exists.** MLX's default `Memory.memoryLimit` is *1.5× the
/// device's recommended GPU working set*. On iOS that overshoots the GPU's
/// working-set ceiling: when generation allocates past it, the Metal command
/// buffer fails and MLX rethrows the failure on `com.Metal.CompletionQueueDispatch`
/// — outside any Swift `do/catch` — terminating the process with `SIGABRT`
/// (observed on TestFlight build 22, foreground, mid-generation). Capping the
/// limit *below* the recommended working set makes MLX wait on scheduled tasks
/// (freeing buffers) instead of over-allocating and crashing.
enum MLXMemoryTuning {

    /// Buffer-cache cap. Small so MLX returns memory to the system promptly;
    /// matches the value recommended in MLX's "Running on iOS" guide.
    static let cacheLimitBytes = 20 * 1024 * 1024

    /// Fraction of the device's recommended GPU working set MLX may use.
    /// Below 1.0 so we stay under the GPU ceiling the default (1.5×) blows past.
    /// 0.8 leaves comfortable headroom for a ~1.5 GB model + KV cache while
    /// keeping plenty of room above it for activations on a 6 GB+ phone.
    static let workingSetFraction = 0.8

    /// Compute the GPU memory limit (bytes) for a device whose recommended
    /// working set is `recommendedWorkingSet`. Pure + clamped so it is unit
    /// testable and never returns a negative value.
    static func memoryLimitBytes(recommendedWorkingSet: UInt64) -> Int {
        let scaled = Double(recommendedWorkingSet) * workingSetFraction
        guard scaled.isFinite, scaled > 0 else { return 0 }
        return Int(scaled)
    }

    /// Apply the cache + memory limits to MLX's global GPU allocator. Call once
    /// at model-load time (idempotent — safe to call on every load).
    static func apply() {
        Memory.cacheLimit = cacheLimitBytes
        if let device = MTLCreateSystemDefaultDevice() {
            let limit = memoryLimitBytes(
                recommendedWorkingSet: device.recommendedMaxWorkingSetSize
            )
            if limit > 0 {
                Memory.memoryLimit = limit
            }
        }
    }
}
