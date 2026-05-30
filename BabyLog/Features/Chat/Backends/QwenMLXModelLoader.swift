import Foundation
import MLX
import MLXLMCommon
import MLXLLM
import MLXHuggingFace
import HuggingFace
import Hub
import Tokenizers

/// Seam for loading the Qwen MLX `ModelContainer`. Tests inject a fake;
/// production uses `LiveQwenMLXModelLoader`.
protocol QwenMLXModelLoader: Sendable {
    func loadContainer(
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> ModelContainer
}

/// Production loader. Uses `LLMModelFactory.shared` with a registered
/// `LLMRegistry` configuration. Qwen3 4B 4-bit (~2.3 GB) fits comfortably
/// within iPhone 15's 6 GB RAM budget; the 9B variant (~5 GB) caused OOM
/// crashes on devices with ≤6 GB RAM.
struct LiveQwenMLXModelLoader: QwenMLXModelLoader {

    nonisolated init() {}

    nonisolated func loadContainer(
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> ModelContainer {
        // Cap GPU cache + memory limit. The default memoryLimit (1.5x the
        // device's recommended working set) overshoots the GPU ceiling on iOS
        // and crashes mid-generation — see MLXMemoryTuning.
        MLXMemoryTuning.apply()

        return try await LLMModelFactory.shared.loadContainer(
            from: #hubDownloader(),
            using: #huggingFaceTokenizerLoader(),
            configuration: LLMRegistry.qwen3_4b_4bit
        ) { p in
            progress(p.fractionCompleted)
        }
    }
}
