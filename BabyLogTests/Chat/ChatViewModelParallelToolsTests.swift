import XCTest
import LittleECore
@testable import BabyLog

/// Pins the parallel tool-call flow: a single assistant turn emits
/// multiple `.toolCall` deltas; the view model must interleave one
/// call/result pair per tool (in order), then request a follow-up
/// assistant turn. Regression guard for the Anthropic 400
/// "unexpected tool_use_id" bug where the bundler stomped multi-call
/// turns.
@MainActor
final class ChatViewModelParallelToolsTests: XCTestCase {

    // MARK: - Local fake session + factory

    /// Replays a fixed list of deltas, one session per factory call.
    /// `scripts[i]` feeds the i-th `stream(...)` call on a fresh session,
    /// so the view model's tool-loop (turn 1: tool calls, turn 2: text)
    /// gets deterministic input across the full loop.
    private final class ScriptedSession: ChatSession, @unchecked Sendable {
        let deltas: [ChatDelta]
        init(deltas: [ChatDelta]) { self.deltas = deltas }

        func stream(_ text: String) -> AsyncThrowingStream<ChatDelta, Error> {
            AsyncThrowingStream { continuation in
                for delta in deltas {
                    continuation.yield(delta)
                }
                continuation.finish()
            }
        }

        func cancel() {}
    }

    private final class MultiTurnFactory: ChatSessionFactory, @unchecked Sendable {
        var scripts: [[ChatDelta]]
        var turn = 0
        init(scripts: [[ChatDelta]]) { self.scripts = scripts }
        func makeSession(for backend: ChatBackend) throws -> any ChatSession {
            defer { turn = min(turn + 1, scripts.count - 1) }
            return ScriptedSession(deltas: scripts[turn])
        }
    }

    private final class CountingTool: ChatTool, @unchecked Sendable {
        let name: String
        let description = "Test tool."
        let requiresConfirmation = false
        var inputSchema: ToolInputSchema {
            ToolInputSchema(properties: [], required: [])
        }
        var calls: Int = 0
        init(name: String) { self.name = name }
        func execute(arguments: ToolArguments) async throws -> ToolResult {
            calls += 1
            return ToolResult(content: "\(name) ok", isError: false)
        }
    }

    private final class InMemoryStore: ChatBackendPreferenceStore, @unchecked Sendable {
        var storage: [String: String] = [:]
        func string(forKey key: String) -> String? { storage[key] }
        func set(_ value: String, forKey key: String) { storage[key] = value }
    }

    private func waitUntil(
        _ check: @escaping @MainActor () -> Bool,
        timeout: TimeInterval = 2.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if check() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("waitUntil timed out", file: file, line: line)
    }

    // MARK: - Tests

    func test_parallelToolCalls_executeAllToolsInOrder() async {
        let feed = CountingTool(name: "createFeedLog")
        let diaper = CountingTool(name: "createDiaperLog")
        let pump = CountingTool(name: "createPumpingSession")
        let registry = ToolRegistry([feed, diaper, pump])

        // Turn 1: the model emits three tool_use blocks in a single
        // assistant message, then `.done`. Turn 2: one short text
        // confirmation.
        let turn1: [ChatDelta] = [
            .toolCall(id: "a", name: "createFeedLog", arguments: ToolArguments([:])),
            .toolCall(id: "b", name: "createDiaperLog", arguments: ToolArguments([:])),
            .toolCall(id: "c", name: "createPumpingSession", arguments: ToolArguments([:])),
            .done,
        ]
        let turn2: [ChatDelta] = [.token("all logged"), .done]

        let factory = MultiTurnFactory(scripts: [turn1, turn2])
        let vm = ChatViewModel(
            factory: factory,
            preferenceStore: InMemoryStore(),
            tools: registry
        )
        vm.input = "log a feed, diaper, and pump"

        vm.send()
        await waitUntil { !vm.isStreaming }

        XCTAssertEqual(feed.calls, 1)
        XCTAssertEqual(diaper.calls, 1)
        XCTAssertEqual(pump.calls, 1)
    }

    func test_parallelToolCalls_produceInterleavedCallResultMessages() async {
        let feed = CountingTool(name: "createFeedLog")
        let diaper = CountingTool(name: "createDiaperLog")
        let registry = ToolRegistry([feed, diaper])

        let turn1: [ChatDelta] = [
            .toolCall(id: "f1", name: "createFeedLog", arguments: ToolArguments([:])),
            .toolCall(id: "d1", name: "createDiaperLog", arguments: ToolArguments([:])),
            .done,
        ]
        let turn2: [ChatDelta] = [.token("done"), .done]

        let factory = MultiTurnFactory(scripts: [turn1, turn2])
        let vm = ChatViewModel(
            factory: factory,
            preferenceStore: InMemoryStore(),
            tools: registry
        )
        vm.input = "both please"

        vm.send()
        await waitUntil { !vm.isStreaming }

        // Strip to tool-entry order only — ignore user + assistant bubbles.
        let toolEntries = vm.messages.compactMap(\.toolEntry)
        XCTAssertEqual(toolEntries.count, 4, "expected call,result,call,result")

        // Shape: call(f1) → result(f1) → call(d1) → result(d1)
        if case .call(let id, let name, _) = toolEntries[0] {
            XCTAssertEqual(id, "f1")
            XCTAssertEqual(name, "createFeedLog")
        } else { XCTFail("entry 0 not a call") }
        if case .result(let id, let name, let res) = toolEntries[1] {
            XCTAssertEqual(id, "f1")
            XCTAssertEqual(name, "createFeedLog")
            XCTAssertFalse(res.isError)
        } else { XCTFail("entry 1 not a result") }
        if case .call(let id, _, _) = toolEntries[2] {
            XCTAssertEqual(id, "d1")
        } else { XCTFail("entry 2 not a call") }
        if case .result(let id, _, _) = toolEntries[3] {
            XCTAssertEqual(id, "d1")
        } else { XCTFail("entry 3 not a result") }
    }

    func test_parallelToolCalls_unknownToolFailsGracefully() async {
        let feed = CountingTool(name: "createFeedLog")
        let registry = ToolRegistry([feed])

        let turn1: [ChatDelta] = [
            .toolCall(id: "f1", name: "createFeedLog", arguments: ToolArguments([:])),
            .toolCall(id: "x1", name: "nonexistentTool", arguments: ToolArguments([:])),
            .done,
        ]
        let turn2: [ChatDelta] = [.token("partial"), .done]

        let factory = MultiTurnFactory(scripts: [turn1, turn2])
        let vm = ChatViewModel(
            factory: factory,
            preferenceStore: InMemoryStore(),
            tools: registry
        )
        vm.input = "mixed"

        vm.send()
        await waitUntil { !vm.isStreaming }

        XCTAssertEqual(feed.calls, 1)
        // Both calls should still have produced a result row; the second
        // is an error row so the model can recover.
        let results = vm.messages.compactMap { msg -> ToolResult? in
            if case .result(_, _, let r)? = msg.toolEntry { return r }
            return nil
        }
        XCTAssertEqual(results.count, 2)
        XCTAssertFalse(results[0].isError)
        XCTAssertTrue(results[1].isError)
    }
}
