import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Streaming text-to-speech that consumes an `AsyncThrowingStream<String>`
/// of LLM tokens and speaks sentences out loud as soon as each sentence
/// boundary is reached, so the user hears the beginning of the reply while
/// the model is still generating the tail.
///
/// The sentence-chunking logic lives in a pure static function
/// (`chunkIntoSentences(_:buffer:)`) so it can be tested without touching
/// `AVSpeechSynthesizer`. The real pipeline just pumps chunks into
/// synthesised utterances.
final class SpeechOutputPipeline: @unchecked Sendable {

    /// Characters we consider sentence terminators. A sentence is emitted
    /// when any of these is appended — this is deliberately simple (no
    /// abbreviation detection) because we're optimising for latency, not
    /// perfect prosody, and over-chunking is recoverable.
    static let sentenceTerminators: Set<Character> = [".", "!", "?", "\n"]

    /// Result of a single pass of the sentence chunker.
    ///
    /// - `utterances`: complete sentences ready to be spoken right away.
    /// - `remainder`: in-flight text that has not yet seen a terminator and
    ///   should be held until the next token arrives.
    struct ChunkResult: Equatable {
        var utterances: [String]
        var remainder: String
    }

    /// Splits the concatenation of `buffer + newText` into complete
    /// sentences (everything up to and including the last terminator) and
    /// a remainder (everything after the last terminator). Pure function.
    ///
    /// Whitespace-only utterances are filtered out. Leading whitespace on
    /// each sentence is trimmed so sentences don't start with an awkward
    /// space from the tokenizer.
    static func chunkIntoSentences(_ newText: String, buffer: String) -> ChunkResult {
        let combined = buffer + newText
        var utterances: [String] = []
        var current = ""
        var lastTerminatorEnd: String.Index? = nil

        for index in combined.indices {
            let character = combined[index]
            current.append(character)
            if sentenceTerminators.contains(character) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    utterances.append(trimmed)
                }
                current = ""
                lastTerminatorEnd = combined.index(after: index)
            }
        }

        let remainder: String
        if let lastTerminatorEnd {
            remainder = String(combined[lastTerminatorEnd...])
        } else {
            remainder = combined
        }

        return ChunkResult(utterances: utterances, remainder: remainder)
    }

    #if canImport(AVFoundation)
    private let synthesizer: AVSpeechSynthesizer
    private let voiceIdentifier: String?

    init(synthesizer: AVSpeechSynthesizer = AVSpeechSynthesizer(), voiceIdentifier: String? = nil) {
        self.synthesizer = synthesizer
        self.voiceIdentifier = voiceIdentifier
    }

    /// Consumes a stream of text chunks and speaks them out loud. Returns
    /// once the input stream finishes; throws if the stream throws.
    func speak(tokens: AsyncThrowingStream<String, any Error>) async throws {
        var buffer = ""
        do {
            for try await token in tokens {
                let result = Self.chunkIntoSentences(token, buffer: buffer)
                buffer = result.remainder
                for utterance in result.utterances {
                    enqueue(utterance)
                }
            }
            // Flush the tail — a final sentence without terminator.
            let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty {
                enqueue(tail)
            }
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    private func enqueue(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        if let voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        }
        synthesizer.speak(utterance)
    }
    #endif
}
