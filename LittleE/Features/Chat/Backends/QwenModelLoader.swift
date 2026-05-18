import Foundation
#if canImport(LlamaSwift)
import LlamaSwift
#endif

/// Opaque container holding a loaded llama.cpp `model` + `context` pair.
///
/// Holds raw `OpaquePointer`s to `llama_model` and `llama_context`. Ownership
/// is process-global — the session's static cache keeps a single instance
/// alive for the lifetime of the app and never frees it, matching the way
/// `Gemma4MLXChatSession` treats its `ModelContainer`.
struct QwenContainer: @unchecked Sendable {
    #if canImport(LlamaSwift)
    let model: OpaquePointer
    let context: OpaquePointer
    #else
    fileprivate let placeholder: Int = 0
    #endif
}

/// Errors surfaced by the Qwen loader. Kept narrow so the chat session
/// can translate them into user-facing copy without leaking llama.cpp
/// internals into the view layer.
enum QwenModelLoaderError: Error, Equatable {
    /// The llama.cpp SPM dependency has not been added to the Xcode
    /// project yet. Surfaced by every path when `canImport(LlamaSwift)` is
    /// false — the whole pipeline is a no-op until the owner wires it up.
    case llamaDependencyMissing
    case downloadFailed(String)
    case modelLoadFailed(String)
}

/// Seam for loading the Qwen 2.5 1.5B-Instruct GGUF weights into a
/// `QwenContainer`. Mirrors `Gemma4ModelLoader` so tests can substitute a
/// scripted fake that yields progress values and either succeeds with a
/// prebuilt container or throws — never touches real weights.
protocol QwenModelLoader: Sendable {
    func loadContainer(
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> QwenContainer
}

/// Production loader. Downloads `Qwen2.5-1.5B-Instruct-Q4_K_M.gguf` from
/// HuggingFace (`Qwen/Qwen2.5-1.5B-Instruct-GGUF`) to
/// `Application Support/qwen/` on first use, then hands the file path to
/// llama.cpp's `llama_model_load_from_file`. Subsequent calls reuse the
/// cached weights on disk, matching `LiveGemma4ModelLoader`'s pattern.
///
/// Today the entire load path short-circuits to
/// `QwenModelLoaderError.llamaDependencyMissing` because the llama.cpp
/// SPM dep hasn't been added to `LittleE.xcodeproj` yet. The download
/// plumbing stays compiled in so the first real commit after the dep
/// lands only needs to flip the `#if canImport(LlamaSwift)` branch.
struct LiveQwenModelLoader: QwenModelLoader {

    /// HuggingFace repo hosting the GGUF quantisation we target.
    /// Qwen3.5 2B uses the same native `<tool_call>` XML envelope as
    /// Qwen 2.5, so the stream parser and ChatML template are unchanged.
    static let repo = "unsloth/Qwen3.5-4B-GGUF"
    /// Specific file inside the repo. Q4_K_M is ~2.5 GB — larger cold
    /// start but meaningfully better tool-call reliability than the 2B.
    static let filename = "Qwen3.5-4B-Q4_K_M.gguf"

    func loadContainer(
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> QwenContainer {
        #if canImport(LlamaSwift)
        let url = try await Self.ensureWeightsOnDisk(progress: progress)

        // `llama_backend_init` is safe to call multiple times — llama.cpp
        // guards with a static flag. Doing it here avoids a separate app
        // launch hook.
        llama_backend_init()

        var mparams = llama_model_default_params()
        // Force CPU-only inference on the simulator. Two knobs are
        // needed because llama.cpp still enumerates every registered
        // backend during decode scheduling:
        //
        // 1. `n_gpu_layers = 0` — store all layers in CPU memory.
        // 2. `devices = [cpu, NULL]` — pin model tensors to the CPU
        //    backend device so the scheduler never asks Metal to run
        //    a graph split. Without this, llama.cpp hits `ggml_abort`
        //    inside `llama_context::decode` on the iOS simulator,
        //    where `ggml_metal_rsets_init` spins forever (there is no
        //    usable Metal compute surface).
        mparams.n_gpu_layers = 0
        guard let cpuDevice = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU) else {
            throw QwenModelLoaderError.modelLoadFailed("no CPU backend device registered")
        }
        var deviceList: [ggml_backend_dev_t?] = [cpuDevice, nil]
        let model: OpaquePointer? = deviceList.withUnsafeMutableBufferPointer { buf in
            mparams.devices = buf.baseAddress
            return url.path.withCString { path in
                llama_model_load_from_file(path, mparams)
            }
        }
        guard let model else {
            throw QwenModelLoaderError.modelLoadFailed(
                "llama_model_load_from_file returned null for \(url.lastPathComponent)"
            )
        }

        var cparams = llama_context_default_params()
        cparams.n_ctx = 4096
        cparams.n_batch = 512
        guard let context = llama_init_from_model(model, cparams) else {
            llama_model_free(model)
            throw QwenModelLoaderError.modelLoadFailed(
                "llama_init_from_model returned null"
            )
        }
        return QwenContainer(model: model, context: context)
        #else
        throw QwenModelLoaderError.llamaDependencyMissing
        #endif
    }

    /// Downloads the GGUF file to `Application Support/qwen/<filename>`
    /// if missing, otherwise returns the cached URL.
    ///
    /// Resumable: on any error (network failure, user cancel, timeout),
    /// the `URLSessionDownloadTask` emits `NSURLSessionDownloadTaskResumeData`
    /// which we persist to `<filename>.resume` next to the target. The
    /// next call reads it back and hands it to
    /// `downloadTask(withResumeData:)` so the transfer picks up where it
    /// left off — important for a ~2.5 GB file on cellular or flaky
    /// wifi. If the resume data is stale (server file rotated, too much
    /// wall-clock elapsed), the system automatically falls back to a
    /// fresh download.
    ///
    /// Progress is reported via the delegate `didWriteData` callback
    /// (0..1 of `totalBytesExpectedToWrite`), so the Settings row can
    /// render a live percent instead of the 0→100 jump the old
    /// `URLSession.download(from:)` one-shot gave.
    ///
    /// Not yet wired for hard app kills — those use a normal session, so
    /// if the OS terminates the process mid-transfer, resume data is
    /// never written and the next launch starts from byte 0. Would need
    /// a background `URLSessionConfiguration` to cover that case; punted
    /// to a follow-up since iOS-26 background tasks require `BGTaskScheduler`
    /// plumbing that's out of scope for this change.
    static func ensureWeightsOnDisk(
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("qwen", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(Self.filename)
        let resumeURL = dir.appendingPathComponent(Self.filename + ".resume")
        if fm.fileExists(atPath: dest.path) {
            progress(1.0)
            return dest
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 3600
        config.waitsForConnectivity = true

        let url = URL(
            string: "https://huggingface.co/\(Self.repo)/resolve/main/\(Self.filename)"
        )!

        let taskBox = QwenDownloadTaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                let delegate = QwenDownloadDelegate(
                    destURL: dest,
                    resumeURL: resumeURL,
                    progress: progress,
                    continuation: cont
                )
                let session = URLSession(
                    configuration: config,
                    delegate: delegate,
                    delegateQueue: nil
                )
                let task: URLSessionDownloadTask
                if let resumeData = try? Data(contentsOf: resumeURL), !resumeData.isEmpty {
                    task = session.downloadTask(withResumeData: resumeData)
                } else {
                    task = session.downloadTask(with: url)
                }
                taskBox.task = task
                task.resume()
            }
        } onCancel: {
            // Persist resume data so the next call can continue from the
            // same byte offset. Callback form is the only way to get at
            // it — the synchronous `cancel()` path discards it.
            taskBox.task?.cancel(byProducingResumeData: { data in
                if let data, !data.isEmpty {
                    try? data.write(to: resumeURL, options: .atomic)
                }
            })
        }
    }
}

/// Mutable cross-actor box for a download task reference so the
/// `onCancel:` closure in `withTaskCancellationHandler` can reach it.
/// `URLSessionDownloadTask` is not `Sendable`, so the box is
/// `@unchecked Sendable` and only mutated from the main continuation
/// body before `resume()` — the cancel closure only reads.
private final class QwenDownloadTaskBox: @unchecked Sendable {
    nonisolated(unsafe) var task: URLSessionDownloadTask?
}

/// `URLSessionDownloadDelegate` that bridges a single download task to a
/// `CheckedContinuation<URL, Error>` and writes resume data on failure.
///
/// Owned for the lifetime of one `ensureWeightsOnDisk` call. The
/// `URLSession` retains its delegate, so we only need the caller to
/// `invalidateAndCancel()` in the finally path — we do it from
/// `finish(...)` so the session is torn down exactly once.
private final class QwenDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private let destURL: URL
    private let resumeURL: URL
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private let lock = NSLock()

    init(
        destURL: URL,
        resumeURL: URL,
        progress: @Sendable @escaping (Double) -> Void,
        continuation: CheckedContinuation<URL, Error>
    ) {
        self.destURL = destURL
        self.resumeURL = resumeURL
        self.progress = progress
        self.continuation = continuation
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        progress(min(max(fraction, 0), 1))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.moveItem(at: location, to: destURL)
            try? fm.removeItem(at: resumeURL)
            progress(1.0)
            finish(with: .success(destURL), session: session)
        } catch {
            finish(with: .failure(error), session: session)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return } // success path already handled
        let nsError = error as NSError
        if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
           !resumeData.isEmpty {
            try? resumeData.write(to: resumeURL, options: .atomic)
        }
        finish(with: .failure(error), session: session)
    }

    private func finish(with result: Result<URL, Error>, session: URLSession) {
        lock.lock()
        guard let cont = continuation else {
            lock.unlock()
            return
        }
        continuation = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        switch result {
        case .success(let url): cont.resume(returning: url)
        case .failure(let err): cont.resume(throwing: err)
        }
    }
}
