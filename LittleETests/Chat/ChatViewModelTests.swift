import XCTest
import LittleECore
@testable import LittleE

@MainActor
final class ChatViewModelTests: XCTestCase {

    // MARK: - Helpers

    /// In-memory preference store so tests don't touch `UserDefaults.standard`.
    private final class InMemoryStore: ChatBackendPreferenceStore, @unchecked Sendable {
        var storage: [String: String] = [:]
        func string(forKey key: String) -> String? { storage[key] }
        func set(_ value: String, forKey key: String) { storage[key] = value }
    }

    private struct ScriptedFactory: ChatSessionFactory {
        let script: FakeChatSession.Script
        func makeSession(for backend: ChatBackend) throws -> any ChatSession {
            FakeChatSession(script: script)
        }
    }

    private struct ThrowingFactory: ChatSessionFactory {
        struct BoomError: Error {}
        func makeSession(for backend: ChatBackend) throws -> any ChatSession {
            throw BoomError()
        }
    }

    private func makeVM(
        script: FakeChatSession.Script = .tokens([], perTokenDelay: .milliseconds(0)),
        store: ChatBackendPreferenceStore = InMemoryStore()
    ) -> ChatViewModel {
        ChatViewModel(
            factory: ScriptedFactory(script: script),
            preferenceStore: store
        )
    }

    /// Wait for a predicate on the view model to become true.
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

    func test_send_appendsUserAndStreamingAssistantMessages() async {
        let vm = makeVM(script: .tokens(["hi"], perTokenDelay: .milliseconds(0)))
        vm.input = "hello"

        vm.send()

        XCTAssertEqual(vm.messages.count, 2)
        XCTAssertEqual(vm.messages[0].role, .user)
        XCTAssertEqual(vm.messages[0].text, "hello")
        XCTAssertEqual(vm.messages[1].role, .assistant)
        XCTAssertTrue(vm.messages[1].isStreaming || vm.isStreaming)
        XCTAssertEqual(vm.input, "")
    }

    func test_tokenDeltas_growAssistantText() async {
        let vm = makeVM(script: .tokens(["Hel", "lo ", "world"], perTokenDelay: .milliseconds(0)))
        vm.input = "q"

        vm.send()
        await waitUntil { !vm.isStreaming }

        XCTAssertEqual(vm.messages.last?.text, "Hello world")
    }

    func test_intentDelta_attachesIntentToAssistantMessage() async {
        let intent = ToolUse.feed(FeedDraft(volumeMl: 120, source: .bottle))
        let vm = makeVM(script: .tokensWithIntent(
            ["ok"],
            intent: intent,
            perTokenDelay: .milliseconds(0)
        ))
        vm.input = "log 120ml"

        vm.send()
        await waitUntil { !vm.isStreaming }

        XCTAssertEqual(vm.messages.last?.intent, intent)
    }

    func test_doneDelta_clearsIsStreaming() async {
        let vm = makeVM(script: .tokens(["a"], perTokenDelay: .milliseconds(0)))
        vm.input = "q"

        vm.send()
        await waitUntil { !vm.isStreaming }

        XCTAssertFalse(vm.isStreaming)
        XCTAssertEqual(vm.messages.last?.isStreaming, false)
    }

    func test_errorPath_setsErrorAndClearsStreaming() async {
        struct Boom: Error {}
        let vm = makeVM(script: .failsAfter(0, error: Boom()))
        vm.input = "q"

        vm.send()
        await waitUntil { !vm.isStreaming }

        XCTAssertFalse(vm.isStreaming)
        if case .streamFailed = vm.error { } else { XCTFail("expected streamFailed, got \(String(describing: vm.error))") }
    }

    func test_factoryThrows_setsSessionUnavailableError() async {
        let vm = ChatViewModel(
            factory: ThrowingFactory(),
            preferenceStore: InMemoryStore()
        )
        vm.input = "q"

        vm.send()

        XCTAssertEqual(vm.error, .sessionUnavailable)
        XCTAssertFalse(vm.isStreaming)
    }

    func test_cancel_stopsStreamAndSealsMessage() async {
        let vm = makeVM(script: .tokens(
            Array(repeating: "x", count: 200),
            perTokenDelay: .milliseconds(20)
        ))
        vm.input = "q"

        vm.send()
        // Let at least one token land.
        try? await Task.sleep(for: .milliseconds(30))
        vm.cancel()

        XCTAssertFalse(vm.isStreaming)
        XCTAssertEqual(vm.messages.last?.isStreaming, false)
    }

    func test_switchBackend_persistsToStore() async {
        let store = InMemoryStore()
        let vm = makeVM(store: store)

        vm.switchBackend(.apple)

        XCTAssertEqual(vm.selectedBackend, .apple)
        XCTAssertEqual(store.storage["chat.selectedBackend"], "apple")
    }

    func test_init_readsPersistedBackend() {
        let store = InMemoryStore()
        store.storage["chat.selectedBackend"] = "gemma"

        let vm = makeVM(store: store)

        XCTAssertEqual(vm.selectedBackend, .gemma)
    }

    func test_clearError_resetsErrorState() async {
        struct Boom: Error {}
        let vm = makeVM(script: .failsAfter(0, error: Boom()))
        vm.input = "q"
        vm.send()
        await waitUntil { vm.error != nil }

        vm.clearError()

        XCTAssertNil(vm.error)
    }

    func test_send_whenInputEmpty_doesNothing() {
        let vm = makeVM()
        vm.input = "   "

        vm.send()

        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertFalse(vm.isStreaming)
    }

    // MARK: - Tool-loop tests

    /// Records every history the fake session is invoked with so the
    /// error-path test can assert the tool result is fed back to the model.
    private final class RecordingToolSession: ChatSession, @unchecked Sendable {

        enum TurnEvent: Sendable {
            case tokens([String])
            case toolCall(id: String, name: String, arguments: ToolArguments)
            case assistant(String)
        }

        /// Scripted turns — one entry per `stream(messages:tools:)` call.
        let turns: [[TurnEvent]]
        private(set) var receivedHistories: [[ChatMessage]] = []
        private var turnIndex = 0
        private let lock = NSLock()

        init(turns: [[TurnEvent]]) {
            self.turns = turns
        }

        func stream(_ text: String) -> AsyncThrowingStream<ChatDelta, Error> {
            stream(messages: [], tools: nil)
        }

        func stream(
            messages: [ChatMessage],
            tools: ToolRegistry?
        ) -> AsyncThrowingStream<ChatDelta, Error> {
            lock.lock()
            receivedHistories.append(messages)
            let events = turnIndex < turns.count ? turns[turnIndex] : []
            turnIndex += 1
            lock.unlock()

            return AsyncThrowingStream { continuation in
                Task {
                    for event in events {
                        switch event {
                        case let .tokens(ts):
                            for t in ts { continuation.yield(.token(t)) }
                        case let .toolCall(id, name, args):
                            continuation.yield(.toolCall(id: id, name: name, arguments: args))
                        case let .assistant(text):
                            continuation.yield(.token(text))
                        }
                    }
                    continuation.yield(.done)
                    continuation.finish()
                }
            }
        }

        func cancel() {}
    }

    private struct RecordingFactory: ChatSessionFactory {
        let session: RecordingToolSession
        func makeSession(for backend: ChatBackend) throws -> any ChatSession {
            session
        }
    }

    /// Always emits a tool call for the given tool name — used to drive the
    /// loop-cap test.
    private final class AlwaysToolCallSession: ChatSession, @unchecked Sendable {
        let toolName: String
        init(toolName: String) { self.toolName = toolName }
        func stream(_ text: String) -> AsyncThrowingStream<ChatDelta, Error> {
            stream(messages: [], tools: nil)
        }
        func stream(
            messages: [ChatMessage],
            tools: ToolRegistry?
        ) -> AsyncThrowingStream<ChatDelta, Error> {
            AsyncThrowingStream { continuation in
                Task {
                    continuation.yield(.toolCall(
                        id: UUID().uuidString,
                        name: toolName,
                        arguments: ToolArguments([
                            "volumeMl": .int(50),
                            "source": .string("bottle"),
                        ])
                    ))
                    continuation.yield(.done)
                    continuation.finish()
                }
            }
        }
        func cancel() {}
    }

    private struct AlwaysToolCallFactory: ChatSessionFactory {
        let toolName: String
        func makeSession(for backend: ChatBackend) throws -> any ChatSession {
            AlwaysToolCallSession(toolName: toolName)
        }
    }

    func test_toolLoop_executesToolAndContinuesUntilDone() async throws {
        let repo = InMemoryFeedLogRepository()
        let tool = CreateFeedLogTool(repository: repo, clock: SystemClock())
        let tools = ToolRegistry([tool])
        let session = RecordingToolSession(turns: [
            [
                .tokens(["Logging ", "that ", "feed."]),
                .toolCall(
                    id: "call-1",
                    name: "createFeedLog",
                    arguments: ToolArguments([
                        "volumeMl": .int(120),
                        "source": .string("bottle"),
                    ])
                ),
            ],
            [
                .assistant("Done — 120 ml bottle feed saved."),
            ],
        ])
        let vm = ChatViewModel(
            factory: RecordingFactory(session: session),
            preferenceStore: InMemoryStore(),
            tools: tools
        )
        vm.input = "Ethan had 120ml bottle"

        vm.send()
        await waitUntil { !vm.isStreaming }

        // Message order: user, assistant(turn1), tool-call, tool-result, assistant(turn2).
        XCTAssertGreaterThanOrEqual(vm.messages.count, 5)
        XCTAssertEqual(vm.messages[0].role, .user)
        XCTAssertEqual(vm.messages[1].role, .assistant)
        XCTAssertTrue(vm.messages[1].text.contains("Logging"))

        let toolCall = vm.messages.first { msg in
            if case .call = msg.toolEntry { return true } else { return false }
        }
        XCTAssertNotNil(toolCall)
        if case let .call(_, name, _) = toolCall?.toolEntry {
            XCTAssertEqual(name, "createFeedLog")
        } else { XCTFail("expected tool call entry") }

        let toolResult = vm.messages.first { msg in
            if case .result = msg.toolEntry { return true } else { return false }
        }
        XCTAssertNotNil(toolResult)
        if case let .result(_, _, r) = toolResult?.toolEntry {
            XCTAssertFalse(r.isError)
            XCTAssertTrue(r.content.contains("120 ml"))
        } else { XCTFail("expected tool result entry") }

        XCTAssertEqual(vm.messages.last?.role, .assistant)
        XCTAssertFalse(vm.messages.last?.isStreaming ?? true)

        let feeds = try await repo.all()
        XCTAssertEqual(feeds.count, 1)
        XCTAssertEqual(feeds.first?.volumeMl, 120)
        XCTAssertEqual(feeds.first?.source, .bottle)
    }

    func test_toolLoop_unknownTool_producesErrorResultAndContinues() async {
        let session = RecordingToolSession(turns: [
            [.toolCall(id: "x", name: "doesNotExist", arguments: ToolArguments([:]))],
            [.assistant("ok")],
        ])
        let vm = ChatViewModel(
            factory: RecordingFactory(session: session),
            preferenceStore: InMemoryStore(),
            tools: ToolRegistry([])
        )
        vm.input = "q"

        vm.send()
        await waitUntil { !vm.isStreaming }

        let toolResult = vm.messages.first { msg in
            if case .result = msg.toolEntry { return true } else { return false }
        }
        guard case let .result(_, _, r)? = toolResult?.toolEntry else {
            XCTFail("expected tool result entry")
            return
        }
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.content.contains("Unknown tool"))
    }

    func test_toolLoop_toolExecutionError_isErrorResultAndHistoryIncludesIt() async {
        // volumeMl=9999 is out of range → CreateFeedLogTool throws.
        let repo = InMemoryFeedLogRepository()
        let tools = ToolRegistry([CreateFeedLogTool(repository: repo, clock: SystemClock())])
        let session = RecordingToolSession(turns: [
            [.toolCall(
                id: "e1",
                name: "createFeedLog",
                arguments: ToolArguments([
                    "volumeMl": .int(9999),
                    "source": .string("bottle"),
                ])
            )],
            [.assistant("sorry, that failed")],
        ])
        let vm = ChatViewModel(
            factory: RecordingFactory(session: session),
            preferenceStore: InMemoryStore(),
            tools: tools
        )
        vm.input = "log 9999ml"

        vm.send()
        await waitUntil { !vm.isStreaming }

        let toolResult = vm.messages.first { msg in
            if case .result = msg.toolEntry { return true } else { return false }
        }
        guard case let .result(_, _, r)? = toolResult?.toolEntry else {
            XCTFail("expected error result entry")
            return
        }
        XCTAssertTrue(r.isError)

        // The second turn must have been invoked with a history that
        // contains the tool-result entry.
        XCTAssertEqual(session.receivedHistories.count, 2)
        let secondHistory = session.receivedHistories[1]
        let hasToolResult = secondHistory.contains { msg in
            if case .result = msg.toolEntry { return true } else { return false }
        }
        XCTAssertTrue(hasToolResult, "second turn's history must include the tool result")
    }

    // MARK: - Dictation tests

    /// Scripted fake recogniser: emits a pre-canned sequence of partial
    /// transcripts, waiting briefly between each so the VM has time to
    /// observe intermediate states. `stop()` finishes the stream.
    private final class ScriptedRecognizer: SpeechRecognizing, @unchecked Sendable {
        let scripted: [String]
        let throwOnStart: (any Error)?
        let throwMidStream: (any Error)?
        let holdOpen: Bool
        private(set) var stopCallCount = 0
        private var continuation: AsyncThrowingStream<String, any Error>.Continuation?

        init(
            scripted: [String],
            throwOnStart: (any Error)? = nil,
            throwMidStream: (any Error)? = nil,
            holdOpen: Bool = false
        ) {
            self.scripted = scripted
            self.throwOnStart = throwOnStart
            self.throwMidStream = throwMidStream
            self.holdOpen = holdOpen
        }

        func start() async throws -> AsyncThrowingStream<String, any Error> {
            if let throwOnStart { throw throwOnStart }
            return AsyncThrowingStream { continuation in
                self.continuation = continuation
                let scripted = self.scripted
                let throwMidStream = self.throwMidStream
                let holdOpen = self.holdOpen
                Task {
                    for partial in scripted {
                        continuation.yield(partial)
                        try? await Task.sleep(for: .milliseconds(5))
                    }
                    if let throwMidStream {
                        continuation.finish(throwing: throwMidStream)
                    } else if !holdOpen {
                        continuation.finish()
                    }
                    // When `holdOpen` is true, leave the continuation open so
                    // the VM is forced to stop it explicitly — simulates a
                    // real recognizer that keeps listening.
                }
            }
        }

        func stop() {
            stopCallCount += 1
            continuation?.finish()
        }
    }

    private func makeDictationVM(
        recognizer: any SpeechRecognizing
    ) -> ChatViewModel {
        ChatViewModel(
            factory: ScriptedFactory(script: .tokens([], perTokenDelay: .milliseconds(0))),
            preferenceStore: InMemoryStore(),
            speechRecognizer: recognizer
        )
    }

    func test_startDictation_setsIsListeningTrue() async {
        let recognizer = ScriptedRecognizer(scripted: ["hello"])
        let vm = makeDictationVM(recognizer: recognizer)

        vm.startDictation()

        XCTAssertTrue(vm.isListening)
    }

    func test_dictation_streamsPartialsIntoInput() async {
        let recognizer = ScriptedRecognizer(scripted: ["hel", "hello", "hello world"])
        let vm = makeDictationVM(recognizer: recognizer)

        vm.startDictation()
        await waitUntil { vm.input == "hello world" }

        XCTAssertEqual(vm.input, "hello world")
    }

    func test_dictation_preservesTypedPrefix() async {
        let recognizer = ScriptedRecognizer(scripted: ["fed 120ml"])
        let vm = makeDictationVM(recognizer: recognizer)
        vm.input = "Ethan"

        vm.startDictation()
        await waitUntil { vm.input == "Ethan fed 120ml" }

        XCTAssertEqual(vm.input, "Ethan fed 120ml")
    }

    func test_stopDictation_clearsIsListeningAndCallsStop() async {
        let recognizer = ScriptedRecognizer(scripted: ["hi"], holdOpen: true)
        let vm = makeDictationVM(recognizer: recognizer)
        vm.startDictation()
        await waitUntil { vm.input == "hi" }

        vm.stopDictation()

        XCTAssertFalse(vm.isListening)
        XCTAssertGreaterThanOrEqual(recognizer.stopCallCount, 1)
    }

    func test_toggleDictation_togglesListeningState() async {
        let recognizer = ScriptedRecognizer(scripted: ["hi"], holdOpen: true)
        let vm = makeDictationVM(recognizer: recognizer)

        vm.toggleDictation()
        XCTAssertTrue(vm.isListening)

        vm.toggleDictation()
        XCTAssertFalse(vm.isListening)
    }

    func test_dictation_naturalFinish_leavesFinalTranscriptAndClearsListening() async {
        let recognizer = ScriptedRecognizer(scripted: ["done"])
        let vm = makeDictationVM(recognizer: recognizer)

        vm.startDictation()
        await waitUntil { !vm.isListening }

        XCTAssertEqual(vm.input, "done")
        XCTAssertFalse(vm.isListening)
    }

    func test_dictation_recognizerThrowsOnStart_surfacesDictationFailed() async {
        let recognizer = ScriptedRecognizer(
            scripted: [],
            throwOnStart: SpeechInputPipelineError.unavailable
        )
        let vm = makeDictationVM(recognizer: recognizer)

        vm.startDictation()
        await waitUntil { vm.error != nil }

        XCTAssertFalse(vm.isListening)
        if case .dictationFailed = vm.error {} else {
            XCTFail("expected dictationFailed, got \(String(describing: vm.error))")
        }
    }

    func test_dictation_streamError_surfacesDictationFailed() async {
        let recognizer = ScriptedRecognizer(
            scripted: ["hi"],
            throwMidStream: SpeechInputPipelineError.audioEngineFailed
        )
        let vm = makeDictationVM(recognizer: recognizer)

        vm.startDictation()
        await waitUntil { vm.error != nil }

        XCTAssertFalse(vm.isListening)
        if case let .dictationFailed(detail) = vm.error {
            XCTAssertFalse(detail.isEmpty)
        } else {
            XCTFail("expected dictationFailed, got \(String(describing: vm.error))")
        }
    }

    func test_startDictation_withoutRecognizer_surfacesDictationFailed() {
        let vm = makeVM()  // No recognizer injected.

        vm.startDictation()

        XCTAssertFalse(vm.isListening)
        if case .dictationFailed = vm.error {} else {
            XCTFail("expected dictationFailed, got \(String(describing: vm.error))")
        }
    }

    func test_toolLoop_exceedsIterationCap_surfacesLimitReachedError() async {
        let vm = ChatViewModel(
            factory: AlwaysToolCallFactory(toolName: "createFeedLog"),
            preferenceStore: InMemoryStore(),
            tools: ToolRegistry([
                CreateFeedLogTool(
                    repository: InMemoryFeedLogRepository(),
                    clock: SystemClock()
                )
            ])
        )
        vm.input = "spam"

        vm.send()
        await waitUntil({ !vm.isStreaming }, timeout: 5.0)

        XCTAssertEqual(vm.error, .toolLoopLimitReached)
        XCTAssertFalse(vm.isStreaming)
    }
}
