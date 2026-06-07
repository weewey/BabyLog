import Foundation
import Observation
import BabyLogCore

/// Lightweight abstraction over `UserDefaults` so tests can inject an
/// in-memory backing store instead of the process-wide singleton.
public protocol ChatBackendPreferenceStore: Sendable {
    func string(forKey key: String) -> String?
    func set(_ value: String, forKey key: String)
}

/// Seam over `UIApplication.isIdleTimerDisabled` so the chat VM can keep the
/// screen awake *only* while an on-device reply is streaming. Auto-lock during
/// generation is a crash trigger: when the device sleeps mid-reply, iOS revokes
/// GPU access, the in-flight Metal command buffer fails, and MLX rethrows the
/// failure uncatchably on `com.Metal.CompletionQueueDispatch` (SIGABRT).
/// Injected so tests assert the toggle without touching UIKit.
@MainActor
public protocol IdleTimerControlling: AnyObject {
    var isIdleTimerDisabled: Bool { get set }
}

/// Thin wrapper around `UserDefaults.standard`. `nonisolated` + `Sendable`
/// because `UserDefaults` itself is thread-safe.
public struct UserDefaultsChatBackendStore: ChatBackendPreferenceStore {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }
    public func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }
    public func set(_ value: String, forKey key: String) {
        defaults.set(value, forKey: key)
    }
}

/// Chat tab view model. Owns the message list, the composer draft, the
/// selected backend, and the streaming lifecycle. Views are dumb projections
/// over this state.
@MainActor
@Observable
public final class ChatViewModel {

    public enum Error: Swift.Error, Equatable, Sendable {
        /// Thrown by the factory when a backend can't be constructed
        /// (e.g. Claude API key missing).
        case sessionUnavailable
        /// The backend stream threw mid-turn.
        case streamFailed(String)
        /// The tool-calling loop exceeded the iteration cap; surfaced so
        /// the UI can show the user that the model got stuck in a loop.
        case toolLoopLimitReached
        /// Voice dictation failed — either permission denied, recogniser
        /// unavailable, or the underlying stream threw. Payload is a
        /// human-readable summary suitable for the error alert.
        case dictationFailed(String)
        /// The user attached an image but the active backend doesn't
        /// accept multimodal input (e.g. Gemma 4 on-device). The
        /// attachment is kept pending so switching backends can recover.
        case attachmentNotSupported
    }

    /// Hard cap on tool-calling iterations per `send()`. Prevents a model
    /// that keeps asking for tools from burning through unbounded cost.
    public static let toolLoopLimit = 10

    // MARK: - Observable state

    public private(set) var messages: [ChatMessage] = []
    /// Per-backend message stash. When the user switches backends, the
    /// current `messages` are stashed under the outgoing backend and the
    /// incoming backend's history (if any) is restored. Each backend sees
    /// its own conversation.
    private var stashedMessages: [ChatBackend: [ChatMessage]] = [:]
    public var input: String = ""
    public private(set) var isStreaming: Bool = false {
        didSet {
            guard isStreaming != oldValue else { return }
            // Keep the screen awake while a reply streams so the phone can't
            // auto-lock mid-generation (which crashes the on-device MLX
            // backend). Restored the moment streaming ends — including via
            // cancel / suspendForBackground, which both flip this to false.
            idleTimer?.isIdleTimerDisabled = isStreaming
        }
    }
    public private(set) var selectedBackend: ChatBackend
    public private(set) var error: ChatViewModel.Error?
    /// `true` while a dictation session is actively feeding partial
    /// transcripts into `input`. Views flip the mic button's appearance
    /// off this flag.
    public private(set) var isListening: Bool = false
    /// Last on-device model-load progress reported by the active backend
    /// in `[0, 1]`, or `nil` when no load is in flight. Backends like
    /// Gemma 4 emit `.modelLoading` deltas before generation starts; the
    /// Chat UI projects this as a progress bar above the composer.
    public private(set) var modelLoadProgress: Double?
    /// Image the user has picked but not yet sent. Views render this as
    /// a thumbnail chip above the composer. Cleared after `send()` bundles
    /// it into the outgoing user message, or by `clearAttachment()`.
    public private(set) var pendingAttachment: ChatAttachment?

    /// Whether the VM was constructed with a non-empty tool registry.
    /// Views use this to surface a hint when the selected backend can't
    /// dispatch tool calls (e.g. Apple FM is text-only in v1).
    public var hasTools: Bool { !tools.all.isEmpty }

    /// Whether the currently selected backend accepts image attachments on
    /// user turns. Views hide the attach-image button when this is `false`.
    /// Implemented by asking the factory to construct a probe session —
    /// cheap for every existing backend (Claude / Gemma / Fake) since none
    /// do network I/O in their initializer.
    public var supportsImageInput: Bool {
        guard let probe = try? factory.makeSession(for: selectedBackend) else {
            return false
        }
        return probe.supportsImageInput
    }

    // MARK: - Dependencies

    private let factory: ChatSessionFactory
    private let preferenceStore: ChatBackendPreferenceStore
    private let tools: ToolRegistry
    private let speechRecognizer: (any SpeechRecognizing)?
    private let idleTimer: (any IdleTimerControlling)?
    private var currentSession: (any ChatSession)?
    private var streamTask: Task<Void, Never>?
    private var dictationTask: Task<Void, Never>?
    /// Text already committed to `input` before dictation started. Partial
    /// transcripts are appended to this prefix so earlier typed content
    /// isn't lost when speech recognition emits updated best-guesses.
    private var dictationPrefix: String = ""

    private static let backendDefaultsKey = "chat.selectedBackend"

    // MARK: - Init

    public init(
        factory: ChatSessionFactory,
        preferenceStore: ChatBackendPreferenceStore = UserDefaultsChatBackendStore(),
        defaultBackend: ChatBackend = .gemma,
        tools: ToolRegistry = ToolRegistry([]),
        speechRecognizer: (any SpeechRecognizing)? = nil,
        idleTimer: (any IdleTimerControlling)? = nil
    ) {
        self.factory = factory
        self.preferenceStore = preferenceStore
        self.tools = tools
        self.speechRecognizer = speechRecognizer
        self.idleTimer = idleTimer
        if let raw = preferenceStore.string(forKey: Self.backendDefaultsKey),
           let stored = ChatBackend(rawValue: raw) {
            self.selectedBackend = stored
        } else {
            self.selectedBackend = defaultBackend
        }
    }

    // MARK: - Actions

    /// Attach an image to the next outgoing user message. Replaces any
    /// previously pending attachment.
    public func attach(_ attachment: ChatAttachment) {
        pendingAttachment = attachment
    }

    /// Drop the currently pending attachment without sending it.
    public func clearAttachment() {
        pendingAttachment = nil
    }

    public func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }

        // If the user attached an image but the selected backend can't
        // handle images, surface an error and keep the attachment pending
        // so they can switch backends without losing it.
        if pendingAttachment != nil && !supportsImageInput {
            error = .attachmentNotSupported
            return
        }

        let outgoingAttachments: [ChatAttachment] = pendingAttachment.map { [$0] } ?? []
        let userMsg = ChatMessage(role: .user, text: text, attachments: outgoingAttachments)
        messages.append(userMsg)
        pendingAttachment = nil

        // Append the assistant placeholder synchronously so tests and the
        // UI observe a streaming bubble immediately after `send()` returns.
        let firstAssistantId = UUID()
        let firstAssistant = ChatMessage(
            id: firstAssistantId,
            role: .assistant,
            text: "",
            isStreaming: true
        )
        messages.append(firstAssistant)

        input = ""
        isStreaming = true
        error = nil

        // Resolve the session up-front so factory failures surface
        // synchronously — several existing tests assert this.
        let session: any ChatSession
        do {
            session = try factory.makeSession(for: selectedBackend)
        } catch {
            failAssistant(id: firstAssistantId, error: .sessionUnavailable)
            return
        }
        currentSession = session

        streamTask = Task { [weak self] in
            await self?.runToolLoop(initialAssistantId: firstAssistantId, initialSession: session)
        }
    }

    public func cancel() {
        streamTask?.cancel()
        currentSession?.cancel()
        streamTask = nil
        // Seal the last streaming assistant message synchronously so tests
        // and the UI observe the wind-down immediately.
        if let idx = messages.lastIndex(where: { $0.isStreaming }) {
            messages[idx].isStreaming = false
        }
        isStreaming = false
        currentSession = nil
    }

    /// Stop any in-flight generation when the app leaves the foreground.
    ///
    /// On-device backends (Gemma 4 via MLX) submit Metal command buffers
    /// while generating. Once the app is backgrounded or the device locks,
    /// iOS fails those command buffers; MLX's completion handler then throws
    /// a C++ exception on `com.Metal.CompletionQueueDispatch` — outside any
    /// Swift `do/catch` — which terminates the process with `SIGABRT`.
    /// Driven from the scene-phase `.inactive`/`.background` transition, this
    /// cancels generation while the app is *still* foreground-allowed, so no
    /// new command buffers are submitted into the backgrounded state. No-op
    /// when nothing is streaming.
    public func suspendForBackground() {
        guard isStreaming else { return }
        cancel()
    }

    public func switchBackend(_ backend: ChatBackend) {
        guard backend != selectedBackend else { return }
        if isStreaming {
            cancel()
        }
        stashedMessages[selectedBackend] = messages
        messages = stashedMessages[backend] ?? []
        error = nil
        selectedBackend = backend
        preferenceStore.set(backend.rawValue, forKey: Self.backendDefaultsKey)
    }

    public func clearError() {
        error = nil
    }

    // MARK: - Dictation

    /// Tap-to-toggle entry point used by the mic button.
    public func toggleDictation() {
        if isListening {
            stopDictation()
        } else {
            startDictation()
        }
    }

    /// Begin streaming partial transcripts into `input`. No-ops if a
    /// recognizer wasn't injected (e.g. the composing root forgot to pass
    /// one) or if a session is already active. Failures surface via
    /// `ChatViewModel.Error.dictationFailed`.
    public func startDictation() {
        guard !isListening else { return }
        guard let recognizer = speechRecognizer else {
            error = .dictationFailed("Voice dictation is not available on this device.")
            return
        }
        let existing = input
        if existing.isEmpty || existing.hasSuffix(" ") {
            dictationPrefix = existing
        } else {
            dictationPrefix = existing + " "
        }
        isListening = true
        error = nil

        dictationTask = Task { [weak self] in
            guard let self else { return }
            let stream: AsyncThrowingStream<String, any Swift.Error>
            do {
                stream = try await recognizer.start()
            } catch let err as SpeechInputPipelineError {
                self.error = .dictationFailed(self.copy(for: err))
                self.isListening = false
                self.dictationTask = nil
                return
            } catch {
                self.error = .dictationFailed(String(describing: error))
                self.isListening = false
                self.dictationTask = nil
                return
            }
            await self.drainDictation(stream: stream)
        }
    }

    /// Stop the active dictation session. Idempotent.
    public func stopDictation() {
        guard isListening else { return }
        speechRecognizer?.stop()
        dictationTask?.cancel()
        dictationTask = nil
        isListening = false
    }

    private func drainDictation(stream: AsyncThrowingStream<String, any Swift.Error>) async {
        do {
            for try await partial in stream {
                if Task.isCancelled { break }
                // Latest-best semantics: replace everything after the prefix.
                input = dictationPrefix + partial
            }
            isListening = false
            dictationTask = nil
        } catch let err as SpeechInputPipelineError {
            self.error = .dictationFailed(copy(for: err))
            isListening = false
            dictationTask = nil
        } catch is CancellationError {
            isListening = false
            dictationTask = nil
        } catch {
            self.error = .dictationFailed(String(describing: error))
            isListening = false
            dictationTask = nil
        }
    }

    private func copy(for error: SpeechInputPipelineError) -> String {
        switch error {
        case .notAuthorized:
            return "Speech recognition permission was denied. Enable it in Settings to dictate."
        case .unavailable:
            return "Speech recognition is unavailable on this device or locale."
        case .audioEngineFailed:
            return "The microphone could not be started."
        case .maxDurationExceeded:
            return "Dictation stopped after the maximum duration."
        }
    }

    #if DEBUG
    /// Seed the message list for SwiftUI previews without having to drive
    /// a full streaming session. Debug-only so production code can't reach
    /// past `private(set)`.
    public func previewSeed(_ seeded: [ChatMessage]) {
        self.messages = seeded
    }
    #endif

    // MARK: - Tool loop

    private func runToolLoop(
        initialAssistantId: UUID,
        initialSession: any ChatSession
    ) async {
        var iterations = 0
        var assistantId = initialAssistantId
        var session: any ChatSession = initialSession
        while iterations < Self.toolLoopLimit {
            iterations += 1

            if iterations > 1 {
                // Fresh assistant bubble for the next turn.
                assistantId = UUID()
                let assistant = ChatMessage(
                    id: assistantId,
                    role: .assistant,
                    text: "",
                    isStreaming: true
                )
                messages.append(assistant)
                do {
                    session = try factory.makeSession(for: selectedBackend)
                } catch {
                    failAssistant(id: assistantId, error: .sessionUnavailable)
                    return
                }
                currentSession = session
            }

            let history = messages.filter { $0.role != .tool || $0.toolEntry != nil }
            let turnOutcome = await drain(
                stream: session.stream(messages: history, tools: tools),
                assistantId: assistantId,
                executesToolsInternally: session.executesToolsInternally
            )

            switch turnOutcome {
            case .done:
                if let idx = messages.firstIndex(where: { $0.id == assistantId }) {
                    // A turn can finish without ever producing visible text —
                    // e.g. a cold first generation that stops short of relaying.
                    // Drop the empty shell instead of sealing it as a blank
                    // bubble; keep it only if it carries reasoning or an intent
                    // (those render even when the bubble text is empty).
                    let shell = messages[idx]
                    if shell.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && shell.intent == nil
                        && shell.reasoning == nil {
                        messages.remove(at: idx)
                    } else {
                        messages[idx].isStreaming = false
                    }
                }
                finishStreaming()
                return
            case .failed(let err):
                failAssistant(id: assistantId, error: err)
                return
            case .cancelled:
                seal(id: assistantId)
                return
            case .toolsRequested:
                // Claude frequently emits a `tool_use` block with no
                // preceding text, so the placeholder assistant bubble we
                // appended in `send()` never receives a token. Drop the
                // empty shell instead of leaving it on screen; otherwise
                // seal it so it stops showing the typing indicator.
                if let idx = messages.firstIndex(where: { $0.id == assistantId }) {
                    let shell = messages[idx]
                    if shell.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && shell.intent == nil && shell.reasoning == nil {
                        messages.remove(at: idx)
                    } else {
                        messages[idx].isStreaming = false
                    }
                }
                continue
            }
        }

        // Exceeded the loop cap.
        self.error = .toolLoopLimitReached
        if let idx = messages.lastIndex(where: { $0.isStreaming }) {
            messages[idx].isStreaming = false
        }
        finishStreaming()
    }

    private enum TurnOutcome {
        case done
        case toolsRequested
        case failed(ChatViewModel.Error)
        case cancelled
    }

    private func drain(
        stream: AsyncThrowingStream<ChatDelta, Swift.Error>,
        assistantId: UUID,
        executesToolsInternally: Bool
    ) async -> TurnOutcome {
        var sawToolCall = false
        // Maps a `.toolCall` id to its tool name so a backend-emitted
        // `.toolResult` (which carries only the id) can be recorded with the
        // right name. Only used when the backend executes tools internally.
        var toolNamesById: [String: String] = [:]
        do {
            for try await delta in stream {
                if Task.isCancelled { return .cancelled }
                switch delta {
                case let .token(chunk):
                    modelLoadProgress = nil
                    appendToken(chunk, to: assistantId)
                case let .intent(intent):
                    modelLoadProgress = nil
                    attachIntent(intent, to: assistantId)
                case let .reasoning(text, signature):
                    modelLoadProgress = nil
                    if let idx = messages.firstIndex(where: { $0.id == assistantId }) {
                        // Backends stream reasoning incrementally: text
                        // chunks append to the existing block, signatures
                        // arrive separately and replace whatever was
                        // there (empty string = no update).
                        var existing = messages[idx].reasoning
                            ?? ChatMessage.Reasoning(text: "", signature: "")
                        existing.text += text
                        if !signature.isEmpty {
                            existing.signature = signature
                        }
                        messages[idx].reasoning = existing
                    }
                case let .toolCall(id, name, arguments):
                    modelLoadProgress = nil
                    sawToolCall = true
                    appendToolCallMessage(id: id, name: name, arguments: arguments)
                    if executesToolsInternally {
                        // The backend (Apple FM) runs the tool itself and
                        // emits the matching `.toolResult` delta below. Just
                        // record the call card and remember the name.
                        toolNamesById[id] = name
                    } else {
                        let result = await executeTool(name: name, arguments: arguments)
                        appendToolResultMessage(id: id, name: name, result: result)
                    }
                case let .toolResult(id, result):
                    if executesToolsInternally {
                        // Pair the backend-executed result with its call card.
                        appendToolResultMessage(
                            id: id,
                            name: toolNamesById[id] ?? "",
                            result: result
                        )
                    }
                    // Host-driven backends don't emit these; the VM produces
                    // them locally, so any that arrive there are ignored.
                case let .modelLoading(progress):
                    modelLoadProgress = max(0, min(1, progress))
                case .done:
                    modelLoadProgress = nil
                    return (sawToolCall && !executesToolsInternally) ? .toolsRequested : .done
                }
            }
            // Stream ended without .done — treat like normal completion.
            return (sawToolCall && !executesToolsInternally) ? .toolsRequested : .done
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(.streamFailed(String(describing: error)))
        }
    }

    private func executeTool(
        name: String,
        arguments: ToolArguments
    ) async -> ToolResult {
        guard let tool = tools.tool(named: name) else {
            return ToolResult(
                content: "Unknown tool: \(name)",
                isError: true
            )
        }
        do {
            return try await tool.execute(arguments: arguments)
        } catch {
            return ToolResult(
                content: "Tool '\(name)' failed: \(error)",
                isError: true
            )
        }
    }

    // MARK: - Private helpers

    private func appendToken(_ chunk: String, to id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].text.append(chunk)
    }

    private func attachIntent(_ intent: ToolUse, to id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].intent = intent
    }

    private func appendToolCallMessage(
        id: String,
        name: String,
        arguments: ToolArguments
    ) {
        let msg = ChatMessage(
            role: .tool,
            text: "",
            toolEntry: .call(id: id, name: name, arguments: arguments)
        )
        messages.append(msg)
    }

    private func appendToolResultMessage(
        id: String,
        name: String,
        result: ToolResult
    ) {
        let msg = ChatMessage(
            role: .tool,
            text: "",
            toolEntry: .result(id: id, name: name, result: result)
        )
        messages.append(msg)
    }

    private func finishStreaming() {
        isStreaming = false
        currentSession = nil
        streamTask = nil
        modelLoadProgress = nil
    }

    private func seal(id: UUID) {
        if let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].isStreaming = false
        }
        finishStreaming()
    }

    private func failAssistant(id: UUID, error: ChatViewModel.Error) {
        if let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].isStreaming = false
        }
        self.error = error
        finishStreaming()
    }
}
