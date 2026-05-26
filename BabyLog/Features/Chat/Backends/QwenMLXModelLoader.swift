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

/// Production loader. Uses `LLMModelFactory.shared` (the pattern from the
/// mlx-swift-examples reference) with a custom `HubClient` configured for
/// large-shard timeouts. First call triggers a ~5 GB download;
/// subsequent calls reuse the cached weights on disk.
///
struct LiveQwenMLXModelLoader: QwenMLXModelLoader {

    nonisolated init() {}

    nonisolated func loadContainer(
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> ModelContainer {
        // Limit GPU cache so MLX doesn't OOM on the 9B weights (ref: MLXChatExample).
        Memory.cacheLimit = 20 * 1024 * 1024

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600        // 10 min idle ceiling per shard
        config.timeoutIntervalForResource = 60 * 60   // 1 hour total per resource
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config)
        let hubClient = HubClient(session: session)

        // mlx-community/Qwen3.5-9B-MLX-4bit is not in LLMRegistry, so we
        // use ModelConfiguration(id:) directly as the reference does for
        // community models outside the curated list.
        let configuration = ModelConfiguration(id: "mlx-community/Qwen3.5-9B-MLX-4bit")

        return try await LLMModelFactory.shared.loadContainer(
            from: #hubDownloader(hubClient),
            using: #huggingFaceTokenizerLoader(),
            configuration: configuration
        ) { p in
            progress(p.fractionCompleted)
        }
    }
}
