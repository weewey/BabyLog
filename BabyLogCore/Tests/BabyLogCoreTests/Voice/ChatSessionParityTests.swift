import XCTest
@testable import BabyLogCore

/// Drives `ChatSessionParityHarness` against `FakeChatSession`. This is the
/// canonical "parity contract" test the other two backends (Apple FM,
/// Claude) must also pass — see `BabyLogTests/Chat/*ParityTests.swift`.
///
/// Gemma is intentionally omitted: WT-D is still blocked, and its only
/// implementation today is `FakeChatSessionFactory` returning a
/// `FakeChatSession`, which is already covered here. When the real Gemma
/// backend lands, it must add its own `GemmaChatSessionParityTests`
/// driving these same harness helpers.
// TODO(WT-D): add `GemmaChatSessionParityTests` once the MLX backend ships.
final class ChatSessionParityTests: XCTestCase {

    // MARK: - 1. Tokens stream in order, then `.done`

    func test_parity_fake_emitsTokensInOrderThenDone() async throws {
        let tokens = ["Hello", " ", "world"]
        let session = FakeChatSession(script: .tokens(tokens, perTokenDelay: .milliseconds(1)))

        try await ChatSessionParityHarness.assertEmitsTokensInOrderThenDone(
            session,
            expectedTokens: tokens
        )
    }

    // MARK: - 2 & 3. Termination shape with intent

    func test_parity_fake_intentPrecedesDoneAndAppearsAtMostOnce() async throws {
        let intent = ToolUse.feed(FeedDraft(volumeMl: 120, source: .bottle))
        let session = FakeChatSession(script: .tokensWithIntent(
            ["Logged"],
            intent: intent,
            perTokenDelay: .milliseconds(1)
        ))

        let deltas = try await ChatSessionParityHarness.collect(session, prompt: "120ml")

        try ChatSessionParityHarness.assertWellFormedSuccess(deltas)
        XCTAssertEqual(deltas.filter {
            if case .intent = $0 { return true } else { return false }
        }.count, 1)
    }

    // MARK: - 4 & 5. Failure path is typed and unsealed

    func test_parity_fake_throwsTypedErrorWithoutDone() async {
        let session = FakeChatSession(script: .failsAfter(2, error: ParityFakeError.boom))

        await ChatSessionParityHarness.assertThrowsTypedErrorWithoutDone(
            session,
            expectedErrorType: ParityFakeError.self
        )
    }

    // MARK: - 6. Cancellation stops the stream promptly

    func test_parity_fake_cancelStopsStreamPromptly() async throws {
        let session = FakeChatSession(script: .tokens(
            Array(repeating: "x", count: 200),
            perTokenDelay: .milliseconds(5)
        ))

        try await ChatSessionParityHarness.assertCancelStopsStreamPromptly(session)
    }

    // MARK: - 7. cancel() idempotency

    func test_parity_fake_cancelIsIdempotent() {
        let session = FakeChatSession(script: .tokens(["a"], perTokenDelay: .milliseconds(1)))

        ChatSessionParityHarness.assertCancelIsIdempotent(session)
    }

    // MARK: - Empty-prompt consistency

    /// The protocol does not say empty prompts must succeed — only that
    /// they must be handled without crashing and with a well-formed
    /// stream (either successful with `.done`, or a typed error). Each
    /// backend chooses; this test pins the Fake's behavior so that
    /// changing it would be a deliberate choice.
    func test_parity_fake_emptyPromptProducesWellFormedStream() async throws {
        let session = FakeChatSession(script: .tokens(["ok"], perTokenDelay: .milliseconds(1)))

        let deltas = try await ChatSessionParityHarness.collect(session, prompt: "")

        try ChatSessionParityHarness.assertWellFormedSuccess(deltas)
    }
}

// MARK: - Test fixtures

enum ParityFakeError: Error, Equatable {
    case boom
}
