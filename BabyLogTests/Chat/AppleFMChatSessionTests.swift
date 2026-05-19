import XCTest
import BabyLogCore
@testable import BabyLog

/// Tests the Apple FM `ChatSession` adapter layer without invoking the
/// real Foundation Models runtime. Uses a `FakeLanguageModelSession` that
/// replays scripted cumulative snapshots.
final class AppleFMChatSessionTests: XCTestCase {

    // MARK: - Test double

    final class FakeLanguageModelSession: LanguageModelSessionProtocol, @unchecked Sendable {
        enum Script {
            case snapshots([String])
            case throwsAfter(snapshots: [String], error: any Error)
            case empty
        }

        let script: Script
        init(script: Script) { self.script = script }

        func streamResponse(to prompt: String) -> AsyncThrowingStream<String, any Error> {
            AsyncThrowingStream { continuation in
                let script = self.script
                Task {
                    switch script {
                    case .snapshots(let values):
                        for value in values {
                            continuation.yield(value)
                        }
                        continuation.finish()
                    case .throwsAfter(let values, let error):
                        for value in values {
                            continuation.yield(value)
                        }
                        continuation.finish(throwing: error)
                    case .empty:
                        continuation.finish()
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func collect(_ session: AppleFMChatSession, prompt: String = "hi") async throws -> [ChatDelta] {
        var deltas: [ChatDelta] = []
        for try await delta in session.stream(prompt) {
            deltas.append(delta)
        }
        return deltas
    }

    // MARK: - Tests

    func test_stream_cumulativeSnapshots_convertedToDeltaTokens() async throws {
        let fake = FakeLanguageModelSession(script: .snapshots(["The", "The quick", "The quick brown fox"]))
        let session = AppleFMChatSession(session: fake)

        let deltas = try await collect(session)

        XCTAssertEqual(deltas, [
            .token("The"),
            .token(" quick"),
            .token(" brown fox"),
            .done,
        ])
    }

    func test_stream_singleSnapshot_emitsOneTokenThenDone() async throws {
        let fake = FakeLanguageModelSession(script: .snapshots(["hello"]))
        let session = AppleFMChatSession(session: fake)

        let deltas = try await collect(session)

        XCTAssertEqual(deltas, [.token("hello"), .done])
    }

    func test_stream_emptyUpstream_throwsEmptyResponse() async {
        let fake = FakeLanguageModelSession(script: .empty)
        let session = AppleFMChatSession(session: fake)

        do {
            _ = try await collect(session)
            XCTFail("expected error")
        } catch let error as AppleFMChatSessionError {
            XCTAssertEqual(error, .emptyResponse)
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func test_stream_upstreamError_propagatesWithoutDone() async {
        struct Boom: Error, Equatable {}
        let fake = FakeLanguageModelSession(script: .throwsAfter(snapshots: ["Hi"], error: Boom()))
        let session = AppleFMChatSession(session: fake)

        var deltas: [ChatDelta] = []
        do {
            for try await delta in session.stream("hi") {
                deltas.append(delta)
            }
            XCTFail("expected error")
        } catch is Boom {
            // expected
        } catch {
            XCTFail("unexpected: \(error)")
        }

        XCTAssertEqual(deltas, [.token("Hi")])
    }

    func test_stream_divergentSnapshot_emitsFullReplacement() async throws {
        // Simulates a speculative-decode rewrite: the second snapshot does
        // not start with the first. Adapter should emit the new snapshot
        // as a single token rather than silently dropping it.
        let fake = FakeLanguageModelSession(script: .snapshots(["Foo bar", "Different answer"]))
        let session = AppleFMChatSession(session: fake)

        let deltas = try await collect(session)

        XCTAssertEqual(deltas, [
            .token("Foo bar"),
            .token("Different answer"),
            .done,
        ])
    }

    func test_stream_duplicateSnapshotIsIgnored() async throws {
        // Two identical snapshots should not produce an empty-string token.
        let fake = FakeLanguageModelSession(script: .snapshots(["hi", "hi", "hi there"]))
        let session = AppleFMChatSession(session: fake)

        let deltas = try await collect(session)

        XCTAssertEqual(deltas, [.token("hi"), .token(" there"), .done])
    }

    func test_cancel_stopsInFlightStream() async throws {
        let fake = FakeLanguageModelSession(script: .snapshots(["a", "ab", "abc"]))
        let session = AppleFMChatSession(session: fake)

        // Consume one delta, then cancel; the stream should terminate
        // cleanly without throwing.
        var iterator = session.stream("hi").makeAsyncIterator()
        _ = try await iterator.next()
        session.cancel()
        // Drain the rest — should finish without error.
        while try await iterator.next() != nil {}
    }
}
