import Foundation
import BabyLogCore
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Protocol surface

/// Minimal abstraction over the Apple Foundation Models streaming API so
/// `AppleFMChatSession` can be unit-tested without pulling the real
/// `LanguageModelSession` into the test target. Each element of the
/// returned stream is a **cumulative snapshot** of the response so far
/// — matching `LanguageModelSession.streamResponse(to:)`'s real shape.
protocol LanguageModelSessionProtocol: Sendable {
    /// Streams cumulative response snapshots for `prompt`. The final
    /// element is the complete response.
    func streamResponse(to prompt: String) -> AsyncThrowingStream<String, any Error>
}

/// Typed errors surfaced by the Apple FM backend.
enum AppleFMChatSessionError: Error, Equatable {
    /// `FoundationModels` is not available on this device / OS.
    case unavailable
    /// Underlying session produced no output at all.
    case emptyResponse
}

// MARK: - AppleFMChatSession

/// `ChatSession` implementation backed by Apple Foundation Models.
///
/// For this first cut, the session only emits `.token` deltas and `.done`
/// — intent routing via `@Generable` will be a follow-up commit. We adapt
/// cumulative snapshots from the upstream session into incremental
/// `ChatDelta.token` events by diffing each snapshot against the
/// previously-emitted prefix.
final class AppleFMChatSession: ChatSession, @unchecked Sendable {

    private let session: any LanguageModelSessionProtocol
    private var activeTask: Task<Void, Never>?

    /// Test / injection initializer. Production code uses `init()`, which
    /// wires up the real `LanguageModelSession` if `FoundationModels` is
    /// available on the current OS.
    init(session: any LanguageModelSessionProtocol) {
        self.session = session
    }

    #if canImport(FoundationModels)
    /// Production initializer. Throws `.unavailable` if the on-device
    /// model is missing (e.g. simulator, unsupported hardware, or a
    /// locale without model coverage).
    convenience init(instructions: String? = nil) throws {
        guard #available(iOS 26.0, macOS 26.0, *) else {
            throw AppleFMChatSessionError.unavailable
        }
        let adapter = try RealLanguageModelSession(instructions: instructions)
        self.init(session: adapter)
    }
    #endif

    /// Multi-turn override: Apple FM's `LanguageModelSession` takes a single
    /// prompt string, so we serialize the full history with role prefixes
    /// into one transcript. Without this override the default extension
    /// drops everything except the last user turn, leaving the model with
    /// zero conversational memory.
    func stream(
        messages: [ChatMessage],
        tools: ToolRegistry?
    ) -> AsyncThrowingStream<ChatDelta, any Error> {
        let transcript = Self.renderTranscript(messages)
        return stream(transcript)
    }

    static func renderTranscript(_ messages: [ChatMessage]) -> String {
        // Drop empty placeholder assistant messages (the in-flight bubble
        // `ChatViewModel.send()` appends before streaming starts).
        let rendered = messages
            .filter { !$0.text.isEmpty || $0.toolEntry != nil }
            .map { msg -> String in
                switch msg.role {
                case .user: return "User: \(msg.text)"
                case .assistant: return "Assistant: \(msg.text)"
                case .system: return "System: \(msg.text)"
                case .tool: return "" // Apple FM is text-only; skip tool turns
                }
            }
            .filter { !$0.isEmpty }
        return (rendered + ["Assistant:"]).joined(separator: "\n")
    }

    func stream(_ text: String) -> AsyncThrowingStream<ChatDelta, any Error> {
        AsyncThrowingStream { continuation in
            let upstream = session.streamResponse(to: text)
            let task = Task {
                var lastEmittedPrefix = ""
                var receivedAny = false
                do {
                    for try await snapshot in upstream {
                        try Task.checkCancellation()
                        receivedAny = true
                        if snapshot.hasPrefix(lastEmittedPrefix) {
                            let delta = String(snapshot.dropFirst(lastEmittedPrefix.count))
                            if !delta.isEmpty {
                                continuation.yield(.token(delta))
                                lastEmittedPrefix = snapshot
                            }
                        } else {
                            // Snapshot diverged — the model rewrote its
                            // prefix (rare but possible with speculative
                            // decoding). Emit the whole new snapshot as a
                            // single replacement token and reset state.
                            continuation.yield(.token(snapshot))
                            lastEmittedPrefix = snapshot
                        }
                    }
                    if !receivedAny {
                        continuation.finish(throwing: AppleFMChatSessionError.emptyResponse)
                        return
                    }
                    continuation.yield(.done)
                    continuation.finish()
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

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
    }
}

// MARK: - Real adapter

#if canImport(FoundationModels)
/// Bridges the real `LanguageModelSession` into our protocol surface.
@available(iOS 26.0, macOS 26.0, *)
final class RealLanguageModelSession: LanguageModelSessionProtocol, @unchecked Sendable {
    private let session: LanguageModelSession

    init(instructions: String?) throws {
        if let instructions {
            self.session = LanguageModelSession(instructions: instructions)
        } else {
            self.session = LanguageModelSession()
        }
    }

    func streamResponse(to prompt: String) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let responseStream = session.streamResponse(to: prompt)
                    for try await partial in responseStream {
                        // Apple's ResponseStream yields cumulative snapshots
                        // of the generated content. Extract `.content` — the
                        // default `String(describing:)` leaks the whole
                        // `Snapshot(content: "…")` debug description.
                        continuation.yield(partial.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
