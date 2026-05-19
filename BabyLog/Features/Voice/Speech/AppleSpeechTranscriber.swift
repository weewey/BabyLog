import Foundation
import AVFoundation
import Speech

/// `SpeechTranscriber` impl backed by `SFSpeechRecognizer` + `AVAudioEngine`.
/// Forces on-device recognition. Hard-cancels after `maxDuration` seconds.
final class AppleSpeechTranscriber: SpeechTranscriber, @unchecked Sendable {

    static let maxDuration: TimeInterval = 60

    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var stopTimer: Task<Void, Never>?

    init(locale: Locale = Locale(identifier: "en-US")) {
        self.recognizer = SFSpeechRecognizer(locale: locale)
    }

    func start() throws -> AsyncThrowingStream<String, any Error> {
        guard let recognizer, recognizer.isAvailable else {
            throw SpeechTranscriberError.unavailable
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.request = request

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            throw SpeechTranscriberError.audioEngineFailed
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
                continuation.finish(throwing: SpeechTranscriberError.maxDurationExceeded)
            }

            continuation.onTermination = { @Sendable [weak self] _ in
                self?.stop()
            }
        }
    }

    func stop() {
        stopTimer?.cancel()
        stopTimer = nil
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
    }
}
