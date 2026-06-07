import XCTest
import BabyLogCore
@testable import BabyLog

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

    /// Replays a fixed list of deltas once per `stream` call. Used to drive
    /// the `executesToolsInternally` path where the backend itself emits
    /// both `.toolCall` and `.toolResult`.
    private final class DeltaSession: ChatSession, @unchecked Sendable {
        let deltas: [ChatDelta]
        let executesToolsInternally: Bool
        /// When set, the stream finishes by throwing this after emitting all
        /// deltas (simulates a late generation failure).
        let throwAfter: (any Error)?
        init(deltas: [ChatDelta], executesToolsInternally: Bool, throwAfter: (any Error)? = nil) {
            self.deltas = deltas
            self.executesToolsInternally = executesToolsInternally
            self.throwAfter = throwAfter
        }
        func stream(_ text: String) -> AsyncThrowingStream<ChatDelta, any Error> {
            AsyncThrowingStream { continuation in
                for delta in deltas { continuation.yield(delta) }
                if let throwAfter {
                    continuation.finish(throwing: throwAfter)
                } else {
                    continuation.finish()
                }
            }
        }
        func cancel() {}
    }

    private struct DeltaFactory: ChatSessionFactory {
        let make: @Sendable () -> any ChatSession
        func makeSession(for backend: ChatBackend) throws -> any ChatSession { make() }
    }

    /// Records whether the host executed it. For internal-execution backends
    /// the host must never call this.
    private final class SpyTool: ChatTool, @unchecked Sendable {
        let name = "spyTool"
        let description = "spy"
        let inputSchema = ToolInputSchema(properties: [], required: [])
        let requiresConfirmation = false
        private(set) var executeCount = 0
        func execute(arguments: ToolArguments) async throws -> ToolResult {
            executeCount += 1
            return ToolResult(content: "host-executed")
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

    func test_suspendForBackground_cancelsInFlightStreaming() async {
        // Long-running on-device-style stream. If this keeps generating
        // after the app backgrounds, MLX submits Metal command buffers that
        // iOS fails once suspended → uncatchable C++ throw → SIGABRT.
        let vm = makeVM(script: .tokens(
            Array(repeating: "x", count: 200),
            perTokenDelay: .milliseconds(20)
        ))
        vm.input = "q"
        vm.send()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(vm.isStreaming)

        vm.suspendForBackground()

        XCTAssertFalse(vm.isStreaming)
        XCTAssertEqual(vm.messages.last?.isStreaming, false)
    }

    func test_emptyAssistantTurn_isRemoved_notLeftAsEmptyBubble() async {
        // A turn that completes with no tokens (e.g. a cold first turn that
        // fails to relay) must not leave a blank assistant bubble on screen.
        let vm = makeVM(script: .tokens([], perTokenDelay: .milliseconds(0)))
        vm.input = "hi"

        vm.send()
        await waitUntil { !vm.isStreaming }

        XCTAssertFalse(
            vm.messages.contains { $0.role == .assistant && $0.text.isEmpty },
            "empty assistant placeholder should be removed, not sealed as a blank bubble"
        )
        XCTAssertEqual(vm.messages.count, 1)
        XCTAssertEqual(vm.messages.first?.role, .user)
    }

    func test_suspendForBackground_whenIdle_isNoOp() {
        let vm = makeVM()

        vm.suspendForBackground()

        XCTAssertFalse(vm.isStreaming)
        XCTAssertTrue(vm.messages.isEmpty)
    }

    // MARK: - Idle timer (prevent auto-lock during on-device generation)

    /// Records the most recent `isIdleTimerDisabled` value the VM set, so we
    /// can assert the screen is kept awake only while a reply streams.
    @MainActor
    private final class SpyIdleTimer: IdleTimerControlling {
        var isIdleTimerDisabled: Bool = false
    }

    private func makeVM(
        idleTimer: any IdleTimerControlling,
        script: FakeChatSession.Script
    ) -> ChatViewModel {
        ChatViewModel(
            factory: ScriptedFactory(script: script),
            preferenceStore: InMemoryStore(),
            idleTimer: idleTimer
        )
    }

    func test_idleTimer_disabledWhileStreaming_restoredWhenDone() async {
        let timer = SpyIdleTimer()
        let vm = makeVM(
            idleTimer: timer,
            script: .tokens(Array(repeating: "x", count: 40), perTokenDelay: .milliseconds(10))
        )
        vm.input = "q"

        vm.send()
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertTrue(vm.isStreaming)
        XCTAssertTrue(timer.isIdleTimerDisabled, "screen should stay awake while a reply streams")

        await waitUntil { !vm.isStreaming }
        XCTAssertFalse(timer.isIdleTimerDisabled, "idle timer should be restored once streaming ends")
    }

    func test_idleTimer_restoredOnSuspendForBackground() async {
        let timer = SpyIdleTimer()
        let vm = makeVM(
            idleTimer: timer,
            script: .tokens(Array(repeating: "x", count: 200), perTokenDelay: .milliseconds(20))
        )
        vm.input = "q"

        vm.send()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(timer.isIdleTimerDisabled)

        vm.suspendForBackground()

        XCTAssertFalse(timer.isIdleTimerDisabled, "backgrounding must re-enable auto-lock")
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
        vm.input = "Baby had 120ml bottle"

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
        vm.input = "Baby"

        vm.startDictation()
        await waitUntil { vm.input == "Baby fed 120ml" }

        XCTAssertEqual(vm.input, "Baby fed 120ml")
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

    // MARK: - Internal tool execution (Apple FM)

    func test_internalToolExecution_recordsCardsWithoutHostExecutingTool() async {
        let spy = SpyTool()
        let session = DeltaSession(
            deltas: [
                .toolCall(id: "call-1", name: "spyTool", arguments: ToolArguments()),
                .toolResult(id: "call-1", result: ToolResult(content: "logged 120 ml")),
                .token("Done!"),
                .done,
            ],
            executesToolsInternally: true
        )
        let vm = ChatViewModel(
            factory: DeltaFactory(make: { session }),
            preferenceStore: InMemoryStore(),
            tools: ToolRegistry([spy])
        )
        vm.input = "log a feed"

        vm.send()
        await waitUntil { !vm.isStreaming }

        // The host must not execute the tool — the backend already did.
        XCTAssertEqual(spy.executeCount, 0)

        // Both the call and result cards are recorded, paired by id.
        let callEntry = vm.messages.compactMap { msg -> String? in
            if case let .call(id, name, _)? = msg.toolEntry, id == "call-1" { return name }
            return nil
        }
        let resultContent = vm.messages.compactMap { msg -> String? in
            if case let .result(id, _, result)? = msg.toolEntry, id == "call-1" { return result.content }
            return nil
        }
        XCTAssertEqual(callEntry, ["spyTool"])
        XCTAssertEqual(resultContent, ["logged 120 ml"])

        // The assistant's summary text lands (the bubble precedes the tool
        // cards in the array under single-turn internal execution).
        let assistantText = vm.messages.first(where: { $0.role == .assistant })?.text
        XCTAssertEqual(assistantText, "Done!")
        XCTAssertFalse(vm.isStreaming)
    }

    func test_internalToolExecution_lateGenerationError_sealsInsteadOfErroring() async {
        struct LateGenError: Error {}
        // Tool ran + reply streamed, then generation throws (mirrors Apple FM's
        // late token-generation GenerationError). The turn should seal with the
        // partial reply and NOT surface an error modal.
        let session = DeltaSession(
            deltas: [
                .toolCall(id: "c", name: "spyTool", arguments: ToolArguments()),
                .toolResult(id: "c", result: ToolResult(content: "summary")),
                .token("Everything looks good!"),
            ],
            executesToolsInternally: true,
            throwAfter: LateGenError()
        )
        let vm = ChatViewModel(
            factory: DeltaFactory(make: { session }),
            preferenceStore: InMemoryStore(),
            tools: ToolRegistry([SpyTool()])
        )
        vm.input = "today's total"

        vm.send()
        await waitUntil { !vm.isStreaming }

        XCTAssertNil(vm.error, "a late error after usable output must not surface a modal")
        let assistantText = vm.messages.first(where: { $0.role == .assistant })?.text
        XCTAssertEqual(assistantText, "Everything looks good!")
    }

    func test_internalToolExecution_earlyError_noOutput_stillSurfacesError() async {
        struct EarlyError: Error {}
        // Error before any usable output → user should still be told.
        let session = DeltaSession(
            deltas: [],
            executesToolsInternally: true,
            throwAfter: EarlyError()
        )
        let vm = ChatViewModel(
            factory: DeltaFactory(make: { session }),
            preferenceStore: InMemoryStore(),
            tools: ToolRegistry([SpyTool()])
        )
        vm.input = "hi"

        vm.send()
        await waitUntil { !vm.isStreaming }

        XCTAssertNotNil(vm.error, "an error with no produced output should surface")
    }

    func test_internalToolExecution_doneIsTerminalDespiteToolCall() async {
        // A second factory call would mean the host re-looped (host-driven
        // semantics). With internal execution, `.done` ends the turn, so the
        // factory is asked for exactly one session.
        let callCount = LockedInt()
        let vm = ChatViewModel(
            factory: DeltaFactory(make: {
                callCount.increment()
                return DeltaSession(
                    deltas: [
                        .toolCall(id: "c", name: "spyTool", arguments: ToolArguments()),
                        .toolResult(id: "c", result: ToolResult(content: "ok")),
                        .done,
                    ],
                    executesToolsInternally: true
                )
            }),
            preferenceStore: InMemoryStore(),
            tools: ToolRegistry([SpyTool()])
        )
        vm.input = "log"

        vm.send()
        await waitUntil { !vm.isStreaming }

        XCTAssertEqual(callCount.value, 1)
    }

    /// Tiny thread-safe counter for the factory-call assertion above.
    private final class LockedInt: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
        func increment() { lock.lock(); _value += 1; lock.unlock() }
    }
}
