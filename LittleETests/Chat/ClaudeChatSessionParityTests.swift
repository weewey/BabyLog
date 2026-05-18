import XCTest
import LittleECore
@testable import LittleE

/// Drives the shared `ChatSession` parity contract against
/// `ClaudeChatSession`. Uses the same `MockSSEURLProtocol` infrastructure
/// as `ClaudeChatSessionTests` — no real network. See
/// `ChatSessionParityHelpers` for the invariant definitions and the
/// matching Core harness in
/// `LittleECore/Tests/LittleECoreTests/Voice/ChatSessionParityHarness.swift`.
final class ClaudeChatSessionParityTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        MockSSEURLProtocol.reset()
    }

    // MARK: - Fixtures

    private static let happyPathSSE = """
    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" Ethan"}}

    event: message_stop
    data: {"type":"message_stop"}

    """

    private func makeSessionWithMockProtocol(apiKey: String? = "test-key") -> ClaudeChatSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockSSEURLProtocol.self]
        let urlSession = URLSession(configuration: config)
        return ClaudeChatSession(
            opener: { request in try await urlSession.bytes(for: request) },
            apiKeyProvider: { apiKey }
        )
    }

    // MARK: - 1. Tokens stream in order

    func test_parity_claude_emitsTokensInOrderThenDone() async throws {
        MockSSEURLProtocol.stub(status: 200, body: Self.happyPathSSE)
        let session = makeSessionWithMockProtocol()

        let deltas = try await ChatSessionParityHelpers.collect(session)

        let tokens = deltas.compactMap { delta -> String? in
            if case let .token(text) = delta { return text } else { return nil }
        }
        XCTAssertEqual(tokens, ["Hello", " Ethan"])
        try ChatSessionParityHelpers.assertWellFormedSuccess(deltas)
    }

    // MARK: - 2 & 3. Termination shape

    func test_parity_claude_terminatesWithSingleDoneAndAtMostOneIntent() async throws {
        MockSSEURLProtocol.stub(status: 200, body: Self.happyPathSSE)
        let session = makeSessionWithMockProtocol()

        let deltas = try await ChatSessionParityHelpers.collect(session)

        try ChatSessionParityHelpers.assertWellFormedSuccess(deltas)
    }

    // MARK: - 4 & 5. Failure path is typed and unsealed

    func test_parity_claude_unauthenticatedThrowsTypedErrorWithoutDone() async {
        MockSSEURLProtocol.stub(status: 401, body: "")
        let session = makeSessionWithMockProtocol()

        await ChatSessionParityHelpers.assertThrowsTypedErrorWithoutDone(
            session,
            expectedErrorType: ChatSessionError.self
        )
    }

    func test_parity_claude_missingApiKeyThrowsTypedErrorWithoutDone() async {
        let session = ClaudeChatSession(
            opener: { _ in
                XCTFail("opener should not be invoked when key is missing")
                throw ChatSessionError.network
            },
            apiKeyProvider: { nil }
        )

        await ChatSessionParityHelpers.assertThrowsTypedErrorWithoutDone(
            session,
            expectedErrorType: ChatSessionError.self
        )
    }

    // MARK: - 6. Cancellation

    func test_parity_claude_cancelStopsStreamPromptly() async throws {
        // Opener blocks forever — cancellation must unblock it.
        let session = ClaudeChatSession(
            opener: { _ in
                try await Task.sleep(for: .seconds(60))
                throw ChatSessionError.network
            },
            apiKeyProvider: { "test-key" }
        )

        // Specialized cancellation flow because the stream emits zero
        // deltas before cancel: the standard helper requires observing at
        // least one delta first. Use a timer to cancel after a short
        // delay and assert iteration finishes cleanly.
        let stream = session.stream("hi")
        let iterationTask = Task<Int, Error> {
            var count = 0
            for try await _ in stream { count += 1 }
            return count
        }

        try await Task.sleep(for: .milliseconds(20))
        session.cancel()

        let count = try await iterationTask.value
        XCTAssertEqual(count, 0)
    }

    // MARK: - 7. cancel() idempotency

    func test_parity_claude_cancelIsIdempotent() {
        let session = makeSessionWithMockProtocol()

        ChatSessionParityHelpers.assertCancelIsIdempotent(session)
    }
}
