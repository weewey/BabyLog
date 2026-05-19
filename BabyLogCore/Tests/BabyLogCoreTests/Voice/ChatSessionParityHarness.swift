import XCTest
@testable import BabyLogCore
import Foundation

/// Shared "parity contract" harness that every `ChatSession` backend
/// (Apple Foundation Models, Claude, Gemma) must satisfy. The point is to
/// pin down the streaming invariants the `ChatSession` protocol implies
/// but does not enforce in the type system, so all three backends behave
/// identically from the `ChatViewModel`'s point of view.
///
/// Invariants derived strictly from the protocol docs in `ChatSession.swift`:
///
/// 1. **Tokens stream in order.** Concatenation of all `.token` payloads
///    matches what the backend was scripted to produce.
/// 2. **Streams terminate with exactly one `.done`** on the success path,
///    and `.done` is the **last** delta.
/// 3. **At most one `.intent`** per stream, appearing strictly before `.done`.
/// 4. **Failure path does not emit `.done`** — if the stream throws, the
///    caller never sees a sealed message.
/// 5. **Errors are typed** — the thrown error is of the backend's own
///    declared error enum, not a raw `NSError` or string.
/// 6. **Cancellation stops the stream promptly** — after `cancel()` is
///    called mid-stream, iteration finishes within a small grace period.
/// 7. **`cancel()` is idempotent** — safe to call twice or before any stream.
/// 8. **Tool-call / tool-result pairing** — every `.toolCall(id:)` is
///    followed by a matching `.toolResult(id:)` before `.done`, OR the
///    stream terminates without `.done` so the caller can resume out of
///    band. A clean `.done` between a call and its result is a violation.
enum ChatSessionParityHarness {

    // MARK: - 1. Token ordering

    static func assertEmitsTokensInOrderThenDone(
        _ session: any ChatSession,
        prompt: String = "hi",
        expectedTokens: [String],
        file: StaticString = #file,
        line: UInt = #line
    ) async throws {
        let deltas = try await collect(session, prompt: prompt)

        let tokens = deltas.compactMap { delta -> String? in
            if case let .token(text) = delta { return text } else { return nil }
        }
        XCTAssertEqual(tokens, expectedTokens, "token order/content mismatch", file: file, line: line)
        try assertWellFormedSuccess(deltas, file: file, line: line)
    }

    // MARK: - 2 & 3. Termination shape

    static func assertWellFormedSuccess(
        _ deltas: [ChatDelta],
        file: StaticString = #file,
        line: UInt = #line
    ) throws {
        guard let last = deltas.last else {
            XCTFail("expected at least a `.done` delta, got empty stream", file: file, line: line)
            return
        }
        XCTAssertEqual(last, .done, "last delta must be `.done`", file: file, line: line)

        let doneCount = deltas.filter { $0 == .done }.count
        XCTAssertEqual(doneCount, 1, "expected exactly one `.done` delta, got \(doneCount)", file: file, line: line)

        let intentIndices = deltas.indices.filter {
            if case .intent = deltas[$0] { return true } else { return false }
        }
        XCTAssertLessThanOrEqual(intentIndices.count, 1, "more than one `.intent` delta emitted", file: file, line: line)
        if let intentIdx = intentIndices.first {
            XCTAssertLessThan(intentIdx, deltas.count - 1, "`.intent` must precede `.done`", file: file, line: line)
        }

        // 9. `.modelLoading` deltas (if any) must all appear before the
        // first `.token`/`.intent`/`.toolCall`/`.toolResult`, and never
        // after `.done`. Progress is a pre-generation phase.
        let firstContent = deltas.firstIndex { delta in
            switch delta {
            case .token, .intent, .toolCall, .toolResult: return true
            case .modelLoading, .reasoning, .done: return false
            }
        }
        for (idx, delta) in deltas.enumerated() {
            guard case .modelLoading(let p) = delta else { continue }
            XCTAssertTrue((0.0...1.0).contains(p),
                "`.modelLoading` progress \(p) out of [0, 1]",
                file: file, line: line)
            if let firstContent {
                XCTAssertLessThan(idx, firstContent,
                    "`.modelLoading` must precede the first content delta",
                    file: file, line: line)
            }
            XCTAssertLessThan(idx, deltas.count - 1,
                "`.modelLoading` must precede `.done`",
                file: file, line: line)
        }
    }

    // MARK: - 4 & 5. Failure path is typed and unsealed

    static func assertThrowsTypedErrorWithoutDone<E: Error>(
        _ session: any ChatSession,
        prompt: String = "hi",
        expectedErrorType: E.Type,
        file: StaticString = #file,
        line: UInt = #line
    ) async {
        var received: [ChatDelta] = []
        var thrown: (any Error)?
        do {
            for try await delta in session.stream(prompt) {
                received.append(delta)
            }
        } catch {
            thrown = error
        }

        XCTAssertNotNil(thrown, "expected stream to throw but it completed cleanly", file: file, line: line)
        if let thrown {
            XCTAssertTrue(
                thrown is E,
                "expected error of type \(E.self), got \(type(of: thrown)): \(thrown)",
                file: file,
                line: line
            )
        }
        XCTAssertFalse(
            received.contains(.done),
            "failure path must not emit `.done`",
            file: file,
            line: line
        )
    }

    // MARK: - 6. Prompt cancellation

    static func assertCancelStopsStreamPromptly(
        _ session: any ChatSession,
        prompt: String = "hi",
        cancellationGracePeriod: Int = 20,
        file: StaticString = #file,
        line: UInt = #line
    ) async throws {
        let cancelAfter = 1
        var count = 0
        var didCancel = false
        do {
            for try await _ in session.stream(prompt) {
                count += 1
                if count == cancelAfter, !didCancel {
                    session.cancel()
                    didCancel = true
                }
            }
        } catch is CancellationError {
            // Acceptable — cooperative cancellation.
        } catch {
            // Other errors are also acceptable as long as the stream stopped.
        }

        XCTAssertTrue(didCancel, "test must observe at least one delta before cancelling", file: file, line: line)
        XCTAssertLessThanOrEqual(
            count,
            cancelAfter + cancellationGracePeriod,
            "stream emitted \(count) deltas after cancel; expected ≤ \(cancelAfter + cancellationGracePeriod)",
            file: file,
            line: line
        )
    }

    // MARK: - 7. cancel() idempotency

    static func assertCancelIsIdempotent(_ session: any ChatSession) {
        session.cancel()
        session.cancel()
        session.cancel()
    }

    // MARK: - 8. Tool-call / tool-result pairing

    /// Outcome of running the tool-pairing invariant over a delta sequence.
    enum ToolPairingResult: Equatable {
        case ok
        /// `.toolCall(id:)` had no matching `.toolResult` AND the stream
        /// ended cleanly with `.done` — backends that defer execution
        /// out-of-band must NOT emit `.done` until the result arrives.
        case unmatchedToolCall(id: String)
        /// `.toolResult(id:)` arrived without a preceding `.toolCall(id:)`.
        case orphanedToolResult(id: String)
        /// `.done` appeared between a `.toolCall(id:)` and its matching
        /// `.toolResult(id:)`. Streams may end early via cancel/error,
        /// but never via a clean `.done` while a tool is in flight.
        case doneBetweenCallAndResult(id: String)
    }

    /// Validate the tool-call / tool-result invariants on a recorded
    /// delta sequence. See `ToolPairingResult` cases for the rules.
    static func validateToolPairing(_ deltas: [ChatDelta]) -> ToolPairingResult {
        var pending: [String] = []
        var seenCall: Set<String> = []
        var sawDone = false

        for delta in deltas {
            switch delta {
            case .toolCall(let id, _, _):
                if sawDone {
                    return .doneBetweenCallAndResult(id: id)
                }
                pending.append(id)
                seenCall.insert(id)

            case .toolResult(let id, _):
                guard seenCall.contains(id) else {
                    return .orphanedToolResult(id: id)
                }
                if let idx = pending.firstIndex(of: id) {
                    pending.remove(at: idx)
                }

            case .done:
                if let openId = pending.first {
                    return .doneBetweenCallAndResult(id: openId)
                }
                sawDone = true

            case .token, .intent, .modelLoading, .reasoning:
                continue
            }
        }

        if let openId = pending.first {
            if sawDone {
                return .doneBetweenCallAndResult(id: openId)
            }
            return .unmatchedToolCall(id: openId)
        }
        return .ok
    }

    // MARK: - 9. Image attachment capability

    /// Outcome of validating a history routed to a session.
    enum AttachmentRoutingResult: Equatable {
        case ok
        /// A message carried `.attachments` but the session reports
        /// `supportsImageInput == false`. This is a programming error —
        /// the UI layer must hide the attach affordance for backends
        /// that can't accept images.
        case attachmentsOnUnsupportedSession
    }

    static func validateAttachmentRouting(
        history: [ChatMessage],
        session: any ChatSession
    ) -> AttachmentRoutingResult {
        let anyAttachments = history.contains { !$0.attachments.isEmpty }
        if anyAttachments && !session.supportsImageInput {
            return .attachmentsOnUnsupportedSession
        }
        return .ok
    }

    // MARK: - Helpers

    static func collect(
        _ session: any ChatSession,
        prompt: String
    ) async throws -> [ChatDelta] {
        var out: [ChatDelta] = []
        for try await delta in session.stream(prompt) {
            out.append(delta)
        }
        return out
    }
}

// MARK: - Self-tests for the tool-pairing validator

final class ChatSessionParityHarnessToolPairingTests: XCTestCase {

    func test_validate_returnsOkForPlainTokenStream() {
        let result = ChatSessionParityHarness.validateToolPairing([
            .token("hi"), .token(" there"), .done,
        ])
        XCTAssertEqual(result, .ok)
    }

    func test_validate_returnsOkForCallThenResultThenDone() {
        let args = ToolArguments(["volumeMl": .int(120)])
        let result = ChatSessionParityHarness.validateToolPairing([
            .token("ok"),
            .toolCall(id: "1", name: "createFeedLog", arguments: args),
            .toolResult(id: "1", result: ToolResult(content: "logged")),
            .done,
        ])
        XCTAssertEqual(result, .ok)
    }

    func test_validate_flagsDoneBetweenCallAndResult() {
        let args = ToolArguments([:])
        let result = ChatSessionParityHarness.validateToolPairing([
            .toolCall(id: "x", name: "createDiaperLog", arguments: args),
            .done,
        ])
        XCTAssertEqual(result, .doneBetweenCallAndResult(id: "x"))
    }

    func test_validate_flagsOrphanedToolResult() {
        let result = ChatSessionParityHarness.validateToolPairing([
            .toolResult(id: "ghost", result: ToolResult(content: "?")),
            .done,
        ])
        XCTAssertEqual(result, .orphanedToolResult(id: "ghost"))
    }

    func test_validateAttachmentRouting_okWhenNoAttachments() {
        let session = FakeChatSession(script: .tokens(["hi"], perTokenDelay: .milliseconds(1)))
        let history = [ChatMessage(role: .user, text: "hi")]

        let result = ChatSessionParityHarness.validateAttachmentRouting(
            history: history,
            session: session
        )

        XCTAssertEqual(result, .ok)
    }

    func test_validateAttachmentRouting_flagsAttachmentsOnUnsupportedSession() throws {
        let attachment = try ChatAttachment(
            mimeType: "image/jpeg",
            data: Data([0x01]),
            widthPx: 1,
            heightPx: 1
        )
        let session = FakeChatSession(script: .tokens(["hi"], perTokenDelay: .milliseconds(1)))
        let history = [ChatMessage(role: .user, text: "look", attachments: [attachment])]

        let result = ChatSessionParityHarness.validateAttachmentRouting(
            history: history,
            session: session
        )

        XCTAssertEqual(result, .attachmentsOnUnsupportedSession)
    }

    func test_validate_flagsUnmatchedToolCallWhenStreamEndsWithoutDone() {
        let args = ToolArguments([:])
        let result = ChatSessionParityHarness.validateToolPairing([
            .toolCall(id: "a", name: "createFeedLog", arguments: args),
        ])
        XCTAssertEqual(result, .unmatchedToolCall(id: "a"))
    }
}
