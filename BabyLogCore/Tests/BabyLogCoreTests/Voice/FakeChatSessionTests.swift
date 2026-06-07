import XCTest
@testable import BabyLogCore

final class FakeChatSessionTests: XCTestCase {

    func test_supportsImageInput_defaultsFalseViaProtocolExtension() {
        let session = FakeChatSession(script: .tokens(["hi"], perTokenDelay: .milliseconds(1)))

        XCTAssertFalse(session.supportsImageInput)
    }

    func test_executesToolsInternally_defaultsFalseViaProtocolExtension() {
        let session = FakeChatSession(script: .tokens(["hi"], perTokenDelay: .milliseconds(1)))

        XCTAssertFalse(session.executesToolsInternally)
    }

    func test_tokensScript_emitsEachTokenThenDone() async throws {
        let session = FakeChatSession(script: .tokens(
            ["Hello", " ", "world"],
            perTokenDelay: .milliseconds(1)
        ))

        var received: [ChatDelta] = []
        for try await delta in session.stream("hi") {
            received.append(delta)
        }

        XCTAssertEqual(received, [
            .token("Hello"),
            .token(" "),
            .token("world"),
            .done,
        ])
    }

    func test_tokensWithIntent_emitsIntentBeforeDone() async throws {
        let intent = ToolUse.feed(FeedDraft(volumeMl: 120, source: .bottle))
        let session = FakeChatSession(script: .tokensWithIntent(
            ["Logged", " 120ml"],
            intent: intent,
            perTokenDelay: .milliseconds(1)
        ))

        var received: [ChatDelta] = []
        for try await delta in session.stream("120ml bottle") {
            received.append(delta)
        }

        XCTAssertEqual(received.count, 4)
        XCTAssertEqual(received[0], .token("Logged"))
        XCTAssertEqual(received[1], .token(" 120ml"))
        XCTAssertEqual(received[2], .intent(intent))
        XCTAssertEqual(received[3], .done)
    }

    func test_failsAfter_throwsAfterEmittingTokens() async {
        struct BoomError: Error, Equatable {}
        let session = FakeChatSession(script: .failsAfter(3, error: BoomError()))

        var received: [ChatDelta] = []
        var thrown: (any Error)?
        do {
            for try await delta in session.stream("x") {
                received.append(delta)
            }
        } catch {
            thrown = error
        }

        XCTAssertEqual(received.count, 3)
        XCTAssertNotNil(thrown as? BoomError)
    }

    func test_cancel_stopsInFlightStream() async throws {
        let session = FakeChatSession(script: .tokens(
            Array(repeating: "x", count: 100),
            perTokenDelay: .milliseconds(10)
        ))

        let task = Task {
            var count = 0
            for try await _ in session.stream("x") {
                count += 1
                if count == 3 { session.cancel() }
            }
            return count
        }

        let count = try await task.value
        // Cancellation is cooperative — we should see a small number of
        // deltas, far less than the scripted 100.
        XCTAssertLessThan(count, 20)
    }
}
