import XCTest
import BabyLogCore
@testable import BabyLog

/// iOS-test-target mirror of `ChatSessionParityHarness` (which lives in
/// the Core test target and cannot be imported here). Keep these two
/// helper sets in lock-step — any new invariant added to one must be
/// added to the other, otherwise the parity guarantee weakens silently.
///
/// See `BabyLogCore/Tests/BabyLogCoreTests/Voice/ChatSessionParityHarness.swift`
/// for the canonical doc-comment list of invariants.
enum ChatSessionParityHelpers {

    // MARK: - 1. Drain a session into an array

    static func collect(
        _ session: any ChatSession,
        prompt: String = "hi"
    ) async throws -> [ChatDelta] {
        var out: [ChatDelta] = []
        for try await delta in session.stream(prompt) {
            out.append(delta)
        }
        return out
    }

    // MARK: - 2 & 3. Success-path shape

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
        XCTAssertEqual(doneCount, 1, "expected exactly one `.done` delta", file: file, line: line)

        let intentIndices = deltas.indices.filter {
            if case .intent = deltas[$0] { return true } else { return false }
        }
        XCTAssertLessThanOrEqual(intentIndices.count, 1, "more than one `.intent` delta emitted", file: file, line: line)
        if let intentIdx = intentIndices.first {
            XCTAssertLessThan(intentIdx, deltas.count - 1, "`.intent` must precede `.done`", file: file, line: line)
        }

        // 9. `.modelLoading` deltas must all precede the first content
        // delta and never appear after `.done`. Mirror of the canonical
        // invariant in `ChatSessionParityHarness`.
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

    // MARK: - 6. Cancellation stops the stream promptly

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
            // Acceptable.
        } catch {
            // Acceptable — stream stopped via error.
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
}
