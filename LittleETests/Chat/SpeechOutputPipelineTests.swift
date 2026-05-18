import XCTest
@testable import LittleE

/// Pure tests for `SpeechOutputPipeline.chunkIntoSentences(_:buffer:)`.
/// AVSpeechSynthesizer isn't invoked here — we exercise the sentence
/// boundary logic that drives the streaming TTS loop.
final class SpeechOutputPipelineTests: XCTestCase {

    func test_chunk_noTerminator_bufferAccumulates() {
        let result = SpeechOutputPipeline.chunkIntoSentences("hello", buffer: "")

        XCTAssertEqual(result.utterances, [])
        XCTAssertEqual(result.remainder, "hello")
    }

    func test_chunk_singleSentence_emitsOneUtterance() {
        let result = SpeechOutputPipeline.chunkIntoSentences("Hello world.", buffer: "")

        XCTAssertEqual(result.utterances, ["Hello world."])
        XCTAssertEqual(result.remainder, "")
    }

    func test_chunk_acrossCalls_flushesWhenPeriodArrives() {
        let first = SpeechOutputPipeline.chunkIntoSentences("Hello", buffer: "")
        XCTAssertEqual(first.utterances, [])
        XCTAssertEqual(first.remainder, "Hello")

        let second = SpeechOutputPipeline.chunkIntoSentences(" world.", buffer: first.remainder)
        XCTAssertEqual(second.utterances, ["Hello world."])
        XCTAssertEqual(second.remainder, "")
    }

    func test_chunk_multipleSentencesInOneToken_emitsAllAndKeepsTail() {
        let result = SpeechOutputPipeline.chunkIntoSentences(
            "One. Two! Three? Four",
            buffer: ""
        )

        XCTAssertEqual(result.utterances, ["One.", "Two!", "Three?"])
        XCTAssertEqual(result.remainder, " Four")
    }

    func test_chunk_newlineIsSentenceBoundary() {
        let result = SpeechOutputPipeline.chunkIntoSentences("Line one\nLine two", buffer: "")

        XCTAssertEqual(result.utterances, ["Line one"])
        XCTAssertEqual(result.remainder, "Line two")
    }

    func test_chunk_trimsLeadingWhitespaceOnEachSentence() {
        let result = SpeechOutputPipeline.chunkIntoSentences("   Hi.  There.", buffer: "")

        XCTAssertEqual(result.utterances, ["Hi.", "There."])
        XCTAssertEqual(result.remainder, "")
    }

    func test_chunk_whitespaceOnlyAfterTerminatorNotEmitted() {
        // A period followed only by whitespace: still one sentence ("."),
        // not an empty second one.
        let result = SpeechOutputPipeline.chunkIntoSentences("Done.   ", buffer: "")

        XCTAssertEqual(result.utterances, ["Done."])
        XCTAssertEqual(result.remainder, "   ")
    }

    func test_chunk_terminalPunctuationInBufferAlone_emitsImmediately() {
        let result = SpeechOutputPipeline.chunkIntoSentences(".", buffer: "This is it")

        XCTAssertEqual(result.utterances, ["This is it."])
        XCTAssertEqual(result.remainder, "")
    }

    func test_chunk_streamedTokens_integrationWalkthrough() {
        // Simulates how the real speak() loop threads state through calls.
        let tokens = ["The ", "baby ", "is ", "fine. ", "All ", "good!", " Next?", " Fragment"]
        var buffer = ""
        var spoken: [String] = []
        for token in tokens {
            let result = SpeechOutputPipeline.chunkIntoSentences(token, buffer: buffer)
            buffer = result.remainder
            spoken.append(contentsOf: result.utterances)
        }

        XCTAssertEqual(spoken, ["The baby is fine.", "All good!", "Next?"])
        XCTAssertEqual(buffer, " Fragment")
    }
}
