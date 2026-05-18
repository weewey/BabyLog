import XCTest
import LittleECore
@testable import LittleE

/// Pure-logic tests for `pairToolMessages(_:)` — the transform that folds
/// a flat `[ChatMessage]` stream into presentation rows where each
/// `.call` / `.result` pair collapses into a single `ToolInvocation`
/// (pending while the result hasn't arrived yet, resolved once it has).
final class ChatPresentationPairingTests: XCTestCase {

    // MARK: - Fixtures

    private func user(_ text: String) -> ChatMessage {
        ChatMessage(role: .user, text: text)
    }

    private func assistant(_ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, text: text)
    }

    private func toolCall(id: String, name: String, args: [String: JSONValue] = [:]) -> ChatMessage {
        ChatMessage(
            role: .tool,
            toolEntry: .call(id: id, name: name, arguments: ToolArguments(args))
        )
    }

    private func toolResult(id: String, name: String, content: String, isError: Bool = false) -> ChatMessage {
        ChatMessage(
            role: .tool,
            toolEntry: .result(
                id: id,
                name: name,
                result: ToolResult(content: content, isError: isError)
            )
        )
    }

    // MARK: - Empty & plain

    func test_pair_emptyReturnsEmpty() {
        XCTAssertTrue(pairToolMessages([]).isEmpty)
    }

    func test_pair_plainMessagesPassThroughUnchanged() {
        let messages = [user("hi"), assistant("hello")]
        let rows = pairToolMessages(messages)
        XCTAssertEqual(rows.count, 2)
        if case .message(let m0) = rows[0] { XCTAssertEqual(m0.text, "hi") } else { XCTFail() }
        if case .message(let m1) = rows[1] { XCTAssertEqual(m1.text, "hello") } else { XCTFail() }
    }

    // MARK: - Call → result pairing

    func test_pair_callFollowedByResult_collapsesToSingleResolvedInvocation() {
        let call = toolCall(id: "t1", name: "createFeedLog", args: ["volumeMl": .int(60)])
        let result = toolResult(id: "t1", name: "createFeedLog", content: "id=abc")
        let rows = pairToolMessages([user("log 60"), call, result])

        XCTAssertEqual(rows.count, 2, "user message + one tool invocation row")
        guard case let .toolInvocation(inv) = rows[1] else {
            return XCTFail("expected toolInvocation, got \(rows[1])")
        }
        XCTAssertEqual(inv.name, "createFeedLog")
        XCTAssertEqual(inv.toolId, "t1")
        XCTAssertFalse(inv.isPending)
        XCTAssertEqual(inv.result?.content, "id=abc")
        XCTAssertEqual(inv.arguments.values["volumeMl"], .int(60))
    }

    func test_pair_callWithoutResult_isPending() {
        let call = toolCall(id: "t1", name: "createFeedLog", args: ["volumeMl": .int(60)])
        let rows = pairToolMessages([call])

        XCTAssertEqual(rows.count, 1)
        guard case let .toolInvocation(inv) = rows[0] else {
            return XCTFail("expected toolInvocation")
        }
        XCTAssertTrue(inv.isPending)
        XCTAssertNil(inv.result)
    }

    // MARK: - Error + parallel

    func test_pair_errorResultFlagsIsError() {
        let rows = pairToolMessages([
            toolCall(id: "t1", name: "createFeedLog"),
            toolResult(id: "t1", name: "createFeedLog", content: "volumeOutOfRange", isError: true),
        ])
        guard case let .toolInvocation(inv) = rows[0] else { return XCTFail() }
        XCTAssertTrue(inv.isError)
        XCTAssertFalse(inv.isPending)
    }

    func test_pair_parallelCalls_thenParallelResults_preservesCallOrder() {
        let messages = [
            toolCall(id: "a", name: "createFeedLog"),
            toolCall(id: "b", name: "createDiaperLog"),
            toolResult(id: "a", name: "createFeedLog", content: "ok-a"),
            toolResult(id: "b", name: "createDiaperLog", content: "ok-b"),
        ]
        let rows = pairToolMessages(messages)

        XCTAssertEqual(rows.count, 2)
        guard case let .toolInvocation(first) = rows[0],
              case let .toolInvocation(second) = rows[1] else {
            return XCTFail()
        }
        XCTAssertEqual(first.toolId, "a")
        XCTAssertEqual(first.result?.content, "ok-a")
        XCTAssertEqual(second.toolId, "b")
        XCTAssertEqual(second.result?.content, "ok-b")
    }

    func test_pair_interleavedAssistantTextAroundTool() {
        let messages = [
            user("log 60"),
            assistant("Sure, logging that now."),
            toolCall(id: "t1", name: "createFeedLog"),
            toolResult(id: "t1", name: "createFeedLog", content: "ok"),
            assistant("Done. Today: 3 feeds."),
        ]
        let rows = pairToolMessages(messages)

        XCTAssertEqual(rows.count, 4)
        // user, assistant pre, tool, assistant post
        if case .message = rows[0] {} else { XCTFail("row 0 should be .message") }
        if case .message = rows[1] {} else { XCTFail("row 1 should be .message") }
        if case .toolInvocation = rows[2] {} else { XCTFail("row 2 should be .toolInvocation") }
        if case .message = rows[3] {} else { XCTFail("row 3 should be .message") }
    }

    // MARK: - Orphan result

    func test_pair_orphanResult_stillEmittedAsInvocationRow() {
        // No prior call with this id → should not be silently dropped;
        // it gets its own row with empty args so the user still sees it.
        let rows = pairToolMessages([
            toolResult(id: "stray", name: "createFeedLog", content: "id=xyz"),
        ])
        XCTAssertEqual(rows.count, 1)
        guard case let .toolInvocation(inv) = rows[0] else { return XCTFail() }
        XCTAssertEqual(inv.toolId, "stray")
        XCTAssertFalse(inv.isPending)
    }
}
