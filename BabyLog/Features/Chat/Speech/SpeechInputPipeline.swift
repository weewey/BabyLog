import Foundation
#if canImport(Speech)
import Speech
import AVFoundation
#endif

/// Protocol surface for streaming speech-to-text used by the Chat tab.
///
/// The real implementation is backed by `SFSpeechRecognizer` +
/// `SFSpeechAudioBufferRecognitionRequest` with `shouldReportPartialResults`
/// enabled so the Chat UI can echo the user's words while they're still
/// speaking. Tests inject `FakeSpeechInputPipeline` to avoid pulling the
/// Speech framework into the unit-test bundle.
public protocol SpeechRecognizing: Sendable {
    /// Starts a new recording session. The returned async stream yields
    /// partial transcripts (latest-best) and finishes when recording stops,
    /// the utterance cap is reached, or an error is encountered.
    func start() async throws -> AsyncThrowingStream<String, any Swift.Error>

    /// Stops recording. Idempotent.
    func stop()
}

/// Typed error surface for `SpeechRecognizing` implementations.
enum SpeechInputPipelineError: Error, Equatable {
    /// User has not granted speech-recognition permission.
    case notAuthorized
    /// Speech recognizer is unavailable on this device / locale.
    case unavailable
    /// `AVAudioEngine` failed to start.
    case audioEngineFailed
    /// The utterance exceeded the hard duration cap.
    case maxDurationExceeded
}

// MARK: - Authorization

/// Abstracts the tiny slice of `SFSpeechRecognizer` authorization we need,
/// so tests can pre-set any state without touching the real singleton.
protocol SpeechAuthorizing: Sendable {
    /// Current authorization status as a raw int (matches
    /// `SFSpeechRecognizerAuthorizationStatus.rawValue`).
    func currentStatus() -> Int
    /// Requests authorization from the user, returning the resulting raw
    /// status once the callback fires.
    func request() async -> Int
}

#if canImport(Speech)
struct SystemSpeechAuthorizer: SpeechAuthorizing {
    func currentStatus() -> Int {
        Int(SFSpeechRecognizer.authorizationStatus().rawValue)
    }

    func request() async -> Int {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: Int(status.rawValue))
            }
        }
    }
}
#endif

/// Raw values of `SFSpeechRecognizerAuthorizationStatus`, exposed here so
/// tests can refer to them without importing Speech.
enum SpeechAuthStatus {
    static let notDetermined = 0
    static let denied = 1
    static let restricted = 2
    static let authorized = 3
}

/// Resolves the current speech-auth status, requesting if needed, and maps
/// to a typed error on denial / restriction. Pure w.r.t. the injected
/// authorizer so it's fully testable.
func ensureSpeechAuthorized(_ authorizer: SpeechAuthorizing) async throws {
    let current = authorizer.currentStatus()
    let resolved: Int
    if current == SpeechAuthStatus.notDetermined {
        resolved = await authorizer.request()
    } else {
        resolved = current
    }
    switch resolved {
    case SpeechAuthStatus.authorized:
        return
    default:
        throw SpeechInputPipelineError.notAuthorized
    }
}

// MARK: - Real implementation

#if canImport(Speech)
/// Streaming STT backed by `SFSpeechRecognizer` + `AVAudioEngine`, forcing
/// on-device recognition and emitting partial results. Shape mirrors
/// `AppleSpeechTranscriber` used by the Voice capture feature, but this
/// pipeline is owned by the Chat tab and has no duration cap event — it
/// keeps streaming until `stop()` is called by the Chat view model.
final class SpeechInputPipeline: SpeechRecognizing, @unchecked Sendable {

    /// Hard safety cap: a single dictation turn is bounded so a stuck
    /// recognizer can never run forever.
    static let maxDuration: TimeInterval = 120

    private let recognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var stopTimer: Task<Void, Never>?

    init(locale: Locale = Locale(identifier: "en-US")) {
        self.recognizer = SFSpeechRecognizer(locale: locale)
    }

    func start() async throws -> AsyncThrowingStream<String, any Error> {
        guard let recognizer, recognizer.isAvailable else {
            throw SpeechInputPipelineError.unavailable
        }
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    cont.resume(throwing: SpeechInputPipelineError.unavailable)
                    return
                }
                do {
                    let stream = try self._startOffMain(recognizer: recognizer)
                    cont.resume(returning: stream)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func _startOffMain(recognizer: SFSpeechRecognizer) throws -> AsyncThrowingStream<String, any Error> {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let engine = AVAudioEngine()
        self.audioEngine = engine
        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)
        let format = inputNode.inputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw SpeechInputPipelineError.audioEngineFailed
        }

        return AsyncThrowingStream { continuation in
            self.task = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    continuation.yield(result.bestTranscription.formattedString)
                    if result.isFinal {
                        continuation.finish()
                    }
                }
                if let error {
                    continuation.finish(throwing: error)
                }
            }

            self.stopTimer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.maxDuration * 1_000_000_000))
                self?.stop()
                continuation.finish(throwing: SpeechInputPipelineError.maxDurationExceeded)
            }

            continuation.onTermination = { @Sendable [weak self] _ in
                self?.stop()
            }
        }
    }

    func stop() {
        stopTimer?.cancel()
        stopTimer = nil
        if let engine = audioEngine, engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
    }
}
#endif
