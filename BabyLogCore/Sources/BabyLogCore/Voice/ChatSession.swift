import Foundation

/// Which backend is powering the Chat tab. Persisted by the iOS layer in
/// `UserDefaults`; Core only knows the enum so view models and tests can
/// reason about it without importing iOS frameworks.
public enum ChatBackend: String, Sendable, CaseIterable, Codable {
    /// Apple Foundation Models (iOS 26, on-device, zero download).
    case apple
    /// Gemma 4 E2B via MLX Swift, on-device — requires a one-time
    /// ~1.5 GB model download fetched by `mlx-swift-lm`'s built-in
    /// `Downloader`. Progress surfaces as `ChatDelta.modelLoading`.
    case gemma
    /// Qwen 3 4B via MLX Swift, on-device — requires a one-time
    /// ~2.3 GB model download. Fits comfortably on iPhone 15 (6 GB RAM).
    /// Progress surfaces as `ChatDelta.modelLoading`.
    case qwen
}

/// Streaming increment from a `ChatSession`. Backends emit these as the
/// model generates output. The Chat view model appends `.token` deltas to
/// the in-flight assistant message, attaches `.intent` to the same message
/// for the confirmation card, and seals the message on `.done`.
public enum ChatDelta: Equatable, Sendable {
    /// A chunk of assistant text. May be any size (a few characters to a
    /// whole sentence). Concatenation of all tokens yields the full reply.
    case token(String)
    /// The backend recognized a structured logging action. Sent at most
    /// once per reply, always before `.done`.
    case intent(ToolUse)
    /// The model has requested the chat layer execute a registered tool.
    /// `id` correlates this call with the matching `.toolResult`. `name`
    /// identifies the tool in the active `ToolRegistry`. `arguments`
    /// is the raw JSON-shaped argument blob the model produced.
    case toolCall(id: String, name: String, arguments: ToolArguments)
    /// The result of executing a tool, paired by `id` with a previous
    /// `.toolCall`. Emitted by the chat session after the host has run
    /// the tool and is feeding the result back into the model.
    case toolResult(id: String, result: ToolResult)
    /// Extended-thinking / chain-of-thought block produced by the
    /// assistant on this turn. `text` is the plain-text reasoning;
    /// `signature` is the opaque token the provider requires on
    /// round-trip. Emitted at most once per assistant turn, before
    /// `.done`. Backends that don't support CoT never emit this.
    case reasoning(text: String, signature: String)
    /// On-device model load / weights download progress in `[0, 1]`.
    /// Backends that need to fetch or page in weights before generation
    /// (e.g. Gemma 4 via MLX) emit these prior to any `.token`/`.intent`/
    /// `.toolCall`. Must not appear after `.done`. UI renders this as a
    /// progress bar, not a chat bubble.
    case modelLoading(Double)
    /// End of stream. No further deltas will arrive.
    case done
}

/// Abstraction over one conversational turn. Every backend adapter (Apple
/// Foundation Models, Claude, Gemma 4) implements this protocol so the
/// Chat view model can be swapped between them at runtime by the user.
///
/// Streaming is the default mode: `stream(_:)` returns an
/// `AsyncThrowingStream<ChatDelta, Error>` that the caller iterates to
/// receive live tokens. Backends that don't natively stream (e.g. an
/// older non-streaming HTTP impl) should still conform by emitting the
/// full reply as a single `.token` followed by `.done`.
public protocol ChatSession: Sendable {
    /// Streams a reply to `text` as an async sequence of deltas.
    ///
    /// Cancelling the returned stream (`Task` cancellation or explicit
    /// `cancel()`) must abort any in-flight network request or on-device
    /// generation.
    func stream(_ text: String) -> AsyncThrowingStream<ChatDelta, Error>

    /// Multi-turn streaming with conversation history and optional tools.
    /// Backends that support tool use translate `tools` into their native
    /// tool-use payload and emit `.toolCall` deltas as the model requests
    /// invocations. The caller (typically `ChatViewModel`) owns the history
    /// array, appends `.toolResult` entries after executing each tool, and
    /// re-invokes this method with the updated history until a turn ends
    /// without any pending tool calls.
    ///
    /// Default implementation below forwards to the legacy `stream(_:)`
    /// using the last user message — good enough for backends that don't
    /// yet support tool use. Adapter implementations override this.
    func stream(
        messages: [ChatMessage],
        tools: ToolRegistry?
    ) -> AsyncThrowingStream<ChatDelta, Error>

    /// Stops the currently-streaming turn, if any. Idempotent.
    func cancel()

    /// Whether this backend accepts `ChatMessage.attachments` on user
    /// turns. Defaults to `false`; only backends with native image input
    /// (currently just Claude) override to `true`. The UI hides the
    /// attach-image affordance when this is `false`, and the parity
    /// harness asserts no attachments are routed to a session that
    /// can't handle them.
    var supportsImageInput: Bool { get }

    /// Whether this backend runs tool calls itself inside a single
    /// `stream(messages:tools:)` turn, rather than emitting `.toolCall`
    /// deltas for the host to execute and feed back.
    ///
    /// Host-driven backends (Gemma, the Fake) leave this `false`: they emit
    /// a `.toolCall`, the `ChatViewModel` executes the tool from its
    /// `ToolRegistry`, records the result, and re-invokes the backend with
    /// the updated history. Apple Foundation Models instead owns the loop —
    /// its tool adapters execute the tool and feed the result straight back
    /// into the same generation — so it sets this `true`. When `true` the
    /// view model records both the `.toolCall` and the `.toolResult` deltas
    /// the backend emits (for the invocation card) without re-executing the
    /// tool or starting another turn.
    var executesToolsInternally: Bool { get }
}

extension ChatSession {
    /// Fallback: ignore tools, take the last user message, forward to the
    /// string-based `stream`. Adapters that support tool use override this.
    public func stream(
        messages: [ChatMessage],
        tools: ToolRegistry?
    ) -> AsyncThrowingStream<ChatDelta, Error> {
        let lastUser = messages.last(where: { $0.role == .user })?.text ?? ""
        return stream(lastUser)
    }

    public var supportsImageInput: Bool { false }

    public var executesToolsInternally: Bool { false }
}

// MARK: - FakeChatSession

/// Test double that replays a scripted sequence of deltas, one per call.
/// Used by `ChatViewModel` tests and by the Chat tab UI preview so SwiftUI
/// previews render a realistic streaming animation without hitting a real
/// backend.
public final class FakeChatSession: ChatSession, @unchecked Sendable {

    public enum Script: Sendable {
        /// Emit each token with a small delay, then `.done`.
        case tokens([String], perTokenDelay: Duration = .milliseconds(20))
        /// Emit tokens, then an intent, then `.done`.
        case tokensWithIntent([String], intent: ToolUse, perTokenDelay: Duration = .milliseconds(20))
        /// Throw an error after the given number of tokens.
        case failsAfter(Int, error: any Error)
    }

    private let script: Script
    private var activeTask: Task<Void, Never>?

    public init(script: Script) {
        self.script = script
    }

    public func stream(_ text: String) -> AsyncThrowingStream<ChatDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [script] in
                do {
                    switch script {
                    case let .tokens(tokens, delay):
                        for token in tokens {
                            try Task.checkCancellation()
                            continuation.yield(.token(token))
                            try await Task.sleep(for: delay)
                        }
                        continuation.yield(.done)
                        continuation.finish()
                    case let .tokensWithIntent(tokens, intent, delay):
                        for token in tokens {
                            try Task.checkCancellation()
                            continuation.yield(.token(token))
                            try await Task.sleep(for: delay)
                        }
                        continuation.yield(.intent(intent))
                        continuation.yield(.done)
                        continuation.finish()
                    case let .failsAfter(count, error):
                        for i in 0..<count {
                            try Task.checkCancellation()
                            continuation.yield(.token("t\(i)"))
                        }
                        continuation.finish(throwing: error)
                    }
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            self.activeTask = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func cancel() {
        activeTask?.cancel()
        activeTask = nil
    }
}
