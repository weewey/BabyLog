import Foundation
import BabyLogCore
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Upstream seam

/// One event from the underlying Apple FM generation. Text snapshots are
/// **cumulative** (matching `LanguageModelSession.streamResponse(to:)`); tool
/// events are interleaved in generation order. Routing text and tool output
/// through a single ordered stream (rather than a return value + a side
/// channel) keeps the deltas the chat layer sees in the order they happened.
enum AppleFMEvent: Sendable {
    case text(String)
    case toolCall(id: String, name: String, arguments: ToolArguments)
    case toolResult(id: String, result: ToolResult)
}

/// Minimal abstraction over an Apple FM session so `AppleFMChatSession` can be
/// unit-tested without the real `LanguageModelSession`. The real adapter is
/// `RealLanguageModelSession`; tests inject a fake that replays scripted
/// events.
protocol LanguageModelSessionProtocol: Sendable {
    /// Stream the model's response to `prompt`, executing any of `tools` the
    /// model decides to call and interleaving the resulting tool events.
    func streamEvents(
        prompt: String,
        tools: [any ChatTool]
    ) -> AsyncThrowingStream<AppleFMEvent, any Error>
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
/// Apple's `LanguageModelSession` owns the tool loop: its adapters execute our
/// `ChatTool`s and feed the results back into the same generation. So this
/// backend sets `executesToolsInternally = true` — it emits both `.toolCall`
/// and `.toolResult` deltas (for the invocation card) and the host records
/// them without re-executing or starting another turn. Text arrives as
/// cumulative snapshots, which we diff into incremental `.token` deltas.
final class AppleFMChatSession: ChatSession, @unchecked Sendable {

    /// Builds a per-turn upstream session wired with `tools`.
    typealias UpstreamFactory = @Sendable () -> any LanguageModelSessionProtocol

    private let makeUpstream: UpstreamFactory
    private var activeTask: Task<Void, Never>?

    var executesToolsInternally: Bool { true }

    /// Designated initializer. `makeUpstream` builds a fresh upstream per
    /// `stream` call.
    init(makeUpstream: @escaping UpstreamFactory) {
        self.makeUpstream = makeUpstream
    }

    /// Test / injection initializer using a fixed upstream session.
    convenience init(session: any LanguageModelSessionProtocol) {
        self.init(makeUpstream: { session })
    }

    #if canImport(FoundationModels)
    /// Production initializer. Throws `.unavailable` on pre-iOS-26 systems.
    /// Model availability (simulator, unsupported hardware, undownloaded
    /// model) surfaces as a thrown `GenerationError` at stream time.
    convenience init(instructions: String? = nil) throws {
        guard #available(iOS 26.0, macOS 26.0, *) else {
            throw AppleFMChatSessionError.unavailable
        }
        self.init(makeUpstream: {
            RealLanguageModelSession(instructions: instructions)
        })
    }
    #endif

    /// Multi-turn override: Apple FM's session takes a single prompt string,
    /// so we serialize the full history (including prior tool calls/results)
    /// with role prefixes into one transcript.
    func stream(
        messages: [ChatMessage],
        tools: ToolRegistry?
    ) -> AsyncThrowingStream<ChatDelta, any Error> {
        let transcript = Self.renderTranscript(messages)
        return streamInternal(prompt: transcript, tools: tools?.all ?? [])
    }

    func stream(_ text: String) -> AsyncThrowingStream<ChatDelta, any Error> {
        streamInternal(prompt: text, tools: [])
    }

    private func streamInternal(
        prompt: String,
        tools: [any ChatTool]
    ) -> AsyncThrowingStream<ChatDelta, any Error> {
        AsyncThrowingStream { continuation in
            let upstream = makeUpstream()
            let task = Task {
                var lastEmittedPrefix = ""
                var receivedAnyText = false
                var sawToolEvent = false
                do {
                    for try await event in upstream.streamEvents(prompt: prompt, tools: tools) {
                        try Task.checkCancellation()
                        switch event {
                        case let .text(snapshot):
                            receivedAnyText = true
                            if snapshot.hasPrefix(lastEmittedPrefix) {
                                let delta = String(snapshot.dropFirst(lastEmittedPrefix.count))
                                if !delta.isEmpty {
                                    continuation.yield(.token(delta))
                                    lastEmittedPrefix = snapshot
                                }
                            } else {
                                // Snapshot diverged (speculative-decode rewrite):
                                // emit the whole new snapshot and reset state.
                                continuation.yield(.token(snapshot))
                                lastEmittedPrefix = snapshot
                            }
                        case let .toolCall(id, name, arguments):
                            sawToolEvent = true
                            continuation.yield(.toolCall(id: id, name: name, arguments: arguments))
                        case let .toolResult(id, result):
                            sawToolEvent = true
                            continuation.yield(.toolResult(id: id, result: result))
                        }
                    }
                    if !receivedAnyText && !sawToolEvent {
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

    static func renderTranscript(_ messages: [ChatMessage]) -> String {
        let rendered = messages.compactMap { msg -> String? in
            // Render prior tool calls/results so a re-streamed transcript
            // carries the action context forward.
            if let entry = msg.toolEntry {
                switch entry {
                case let .call(_, name, arguments):
                    let args = renderArguments(arguments)
                    return "Assistant called tool \(name)(\(args))"
                case let .result(_, name, result):
                    return "Tool \(name) returned: \(result.content)"
                }
            }
            // Drop empty placeholder assistant messages (the in-flight bubble
            // appended before streaming starts).
            guard !msg.text.isEmpty else { return nil }
            switch msg.role {
            case .user: return "User: \(msg.text)"
            case .assistant: return "Assistant: \(msg.text)"
            case .system: return "System: \(msg.text)"
            case .tool: return nil
            }
        }
        return (rendered + ["Assistant:"]).joined(separator: "\n")
    }

    private static func renderArguments(_ arguments: ToolArguments) -> String {
        guard let data = try? JSONEncoder().encode(arguments.values),
              let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return json
    }
}

// MARK: - Real adapter

#if canImport(FoundationModels)
/// Bridges the real `LanguageModelSession` into our event seam. Builds an
/// `AppleFMToolAdapter` per registered tool so Apple drives the tool loop, and
/// forwards both text snapshots and tool events through one ordered stream.
@available(iOS 26.0, macOS 26.0, *)
final class RealLanguageModelSession: LanguageModelSessionProtocol, @unchecked Sendable {
    private let instructions: String?

    init(instructions: String?) {
        self.instructions = instructions
    }

    func streamEvents(
        prompt: String,
        tools: [any ChatTool]
    ) -> AsyncThrowingStream<AppleFMEvent, any Error> {
        AsyncThrowingStream { continuation in
            // Adapters emit tool events directly into this stream. Apple runs
            // each `call` synchronously within the generation it is awaiting,
            // so the events land in order relative to the text snapshots.
            let adapters: [any FoundationModels.Tool] = tools.compactMap { tool in
                try? AppleFMToolAdapter(chatTool: tool, emit: { event in
                    continuation.yield(event)
                })
            }

            let session: LanguageModelSession
            if let instructions {
                session = LanguageModelSession(tools: adapters, instructions: instructions)
            } else {
                session = LanguageModelSession(tools: adapters)
            }

            let task = Task {
                do {
                    for try await partial in session.streamResponse(to: prompt) {
                        // `partial.content` is the cumulative generated text.
                        continuation.yield(.text(partial.content))
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
