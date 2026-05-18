import XCTest
import LittleECore
@testable import LittleE

/// Drives the shared `ChatSession` parity contract against
/// `AppleFMChatSession`. The harness lives in the Core test target
/// (`LittleECoreTests/Voice/ChatSessionParityHarness.swift`); this file
/// re-implements the same invariants here because the iOS test target
/// cannot import `@testable LittleECoreTests`. Keep the assertions in
/// lock-step with `ChatSessionParityHarness` — if you change one, change
/// both.
///
/// Backed by `FakeLanguageModelSession` (defined in
/// `AppleFMChatSessionTests.swift`) so no real Foundation Models runtime
/// is involved.
final class AppleFMChatSessionParityTests: XCTestCase {

    // MARK: - 1. Tokens stream in order

    func test_parity_appleFM_emitsTokensInOrderThenDone() async throws {
        let fake = AppleFMChatSessionTests.FakeLanguageModelSession(
            script: .snapshots(["The", "The quick", "The quick brown fox"])
        )
        let session = AppleFMChatSession(session: fake)

        let deltas = try await ChatSessionParityHelpers.collect(session)

        let tokens = deltas.compactMap { delta -> String? in
            if case let .token(text) = delta { return text } else { return nil }
        }
        XCTAssertEqual(tokens.joined(), "The quick brown fox")
        try ChatSessionParityHelpers.assertWellFormedSuccess(deltas)
    }

    // MARK: - 2 & 3. Termination shape

    func test_parity_appleFM_terminatesWithSingleDoneAndNoIntent() async throws {
        let fake = AppleFMChatSessionTests.FakeLanguageModelSession(
            script: .snapshots(["hello"])
        )
        let session = AppleFMChatSession(session: fake)

        let deltas = try await ChatSessionParityHelpers.collect(session)

        try ChatSessionParityHelpers.assertWellFormedSuccess(deltas)
    }

    // MARK: - 4 & 5. Failure path is typed and unsealed

    func test_parity_appleFM_emptyResponseThrowsTypedErrorWithoutDone() async {
        let fake = AppleFMChatSessionTests.FakeLanguageModelSession(script: .empty)
        let session = AppleFMChatSession(session: fake)

        await ChatSessionParityHelpers.assertThrowsTypedErrorWithoutDone(
            session,
            expectedErrorType: AppleFMChatSessionError.self
        )
    }

    // MARK: - 6. Cancellation

    func test_parity_appleFM_cancelStopsStreamPromptly() async throws {
        // Long stream of cumulative snapshots so we have something to cancel.
        let snapshots = (1...200).map { String(repeating: "x", count: $0) }
        let fake = AppleFMChatSessionTests.FakeLanguageModelSession(
            script: .snapshots(snapshots)
        )
        let session = AppleFMChatSession(session: fake)

        try await ChatSessionParityHelpers.assertCancelStopsStreamPromptly(session)
    }

    // MARK: - 7. cancel() idempotency

    func test_parity_appleFM_cancelIsIdempotent() {
        let fake = AppleFMChatSessionTests.FakeLanguageModelSession(script: .snapshots(["x"]))
        let session = AppleFMChatSession(session: fake)

        ChatSessionParityHelpers.assertCancelIsIdempotent(session)
    }
}
