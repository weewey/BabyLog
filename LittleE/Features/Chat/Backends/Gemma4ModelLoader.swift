import Foundation
import MLXLMCommon
import MLXLLM
import MLXHuggingFace
import HuggingFace
import Hub
import Tokenizers

/// Seam for loading the Gemma 4 E2B `ModelContainer`. Tests inject a fake
/// that yields a scripted sequence of progress values and then either
/// succeeds with a prebuilt container or throws — never touches real
/// weights. Production uses `LiveGemma4ModelLoader`.
protocol Gemma4ModelLoader: Sendable {
    func loadContainer(
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> ModelContainer
}

/// Production loader. Delegates to `mlx-swift-lm`'s
/// `#huggingFaceLoadModelContainer` macro which wires up the built-in
/// `Downloader` + `TokenizerLoader` against `mlx-community/gemma-4-e2b-it-4bit`.
/// First call triggers a ~1.5 GB download; subsequent calls reuse the
/// cached weights on disk.
struct LiveGemma4ModelLoader: Gemma4ModelLoader {

    func loadContainer(
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> ModelContainer {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600        // 10 min idle ceiling per request
        config.timeoutIntervalForResource = 60 * 60   // 1 hour total per resource
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config)
        let hubClient = HubClient(session: session)

        // We parse tool calls ourselves from the raw text stream using
        // Google's documented ```tool_code``` markdown-block format
        // (see `GemmaToolCallStreamParser`). Intentionally leave
        // `toolCallFormat` at its default so mlx-swift-lm's private
        // `GemmaFunctionParser` — which targets FunctionGemma's token
        // syntax, not base Gemma 3/4 — does not intercept the stream.
        let configuration = LLMRegistry.gemma4_e2b_it_4bit

        return try await loadModelContainer(
            from: #hubDownloader(hubClient),
            using: #huggingFaceTokenizerLoader(),
            configuration: configuration,
            progressHandler: { p in
                progress(p.fractionCompleted)
            }
        )
    }
}
