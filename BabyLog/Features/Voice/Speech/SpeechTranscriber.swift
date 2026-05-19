import Foundation

/// Streams partial transcripts from a speech recognition source.
///
/// Implementations must enforce the 1-minute utterance cap and stop the
/// underlying engine when `stop()` returns or the stream finishes.
protocol SpeechTranscriber: Sendable {
    /// Starts a new recording session. The returned async stream yields
    /// partial transcripts (latest-best) and finishes when recording stops.
    func start() throws -> AsyncThrowingStream<String, any Error>

    /// Stops recording. Safe to call multiple times.
    func stop()
}

enum SpeechTranscriberError: Error, Equatable {
    case notAuthorized
    case unavailable
    case audioEngineFailed
    case maxDurationExceeded
}
