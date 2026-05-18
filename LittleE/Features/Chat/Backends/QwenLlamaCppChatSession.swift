import Foundation
import LittleECore
#if canImport(LlamaSwift)
import LlamaSwift
#endif

// MARK: - Typed errors

/// Narrow error domain for the Qwen on-device backend so the parity
/// harness and UI error copy can distinguish Qwen failures from Claude /
/// Gemma / Apple FM ones.
enum QwenLlamaCppChatSessionError: Error, Equatable {
    /// The `llama` SPM module isn't linked into the app yet. Today this
    /// is the only path the session ever takes — the whole backend is
    /// compiled in behind `#if canImport(LlamaSwift)` and this error is what
    /// `stream()` surfaces when that guard is unsatisfied.
    case llamaDependencyMissing
    case unsupportedDevice
    case modelLoadFailed(String)
    case generationFailed(String)
}

// MARK: - QwenToolCallStreamParser
//
// Pure text-processing state machine. Lives OUTSIDE any `canImport(LlamaSwift)`
// guard because it has no llama dependencies and is the primary thing we
// TDD today, while the rest of the session is stubbed.

/// Streaming parser that watches a Qwen 2.5 token stream for native
/// `<tool_call>...</tool_call>` XML envelopes and emits them as
/// structured `Event.toolCall` values, while forwarding any non-tagged
/// prose as `Event.text`.
///
/// Qwen 2.5 is trained to emit tool calls as:
///
///     <tool_call>
///     {"name": "createFeedLog", "arguments": {"volumeMl": 120}}
///     </tool_call>
///
/// Multiple back-to-back `<tool_call>` blocks are legal (parallel calls),
/// and the opening / closing tags may land in the middle of a streamed
/// chunk. The parser buffers partial tags until a full envelope arrives
/// so the UI never sees raw `<tool_call>` markers leak as plain text.
///
/// Malformed JSON inside an envelope is recovered by emitting a
/// `Event.malformedCall` event carrying the raw inner text so the host
/// can either ignore it or surface a diagnostic — the parser stays
/// forward-progressing and never throws.
struct QwenToolCallStreamParser {

    /// Events the parser emits as chunks are fed in. Mirrors the subset
    /// of `ChatDelta` cases the session cares about, without taking a
    /// dependency on `ChatDelta` so the parser stays trivially testable.
    enum Event: Equatable {
        /// A run of plain assistant prose, already stripped of any
        /// `<tool_call>` markers.
        case text(String)
        /// A complete, successfully decoded tool call.
        case toolCall(name: String, arguments: [String: JSONValue])
        /// A `<tool_call>` envelope whose inner JSON failed to decode.
        /// Raw inner text is preserved so the host can log it.
        case malformedCall(raw: String)
    }

    private static let openTag = "<tool_call>"
    private static let closeTag = "</tool_call>"

    /// Unconsumed buffer. Holds either: (a) plain text that might still
    /// be a prefix of `<tool_call>` (hence not safe to flush yet), or
    /// (b) the inside of an open envelope waiting on `</tool_call>`.
    private var buffer: String = ""
    private var insideToolCall: Bool = false

    /// Feed a streamed chunk into the parser. Returns zero or more events
    /// that are ready to emit immediately. Remaining partial state stays
    /// buffered for the next call to `feed` or `finish`.
    mutating func feed(_ chunk: String) -> [Event] {
        buffer += chunk
        var events: [Event] = []

        while true {
            if insideToolCall {
                guard let closeRange = buffer.range(of: Self.closeTag) else {
                    // Close tag hasn't arrived yet — keep buffering.
                    return events
                }
                let inner = String(buffer[buffer.startIndex..<closeRange.lowerBound])
                events.append(decode(inner: inner))
                buffer.removeSubrange(buffer.startIndex..<closeRange.upperBound)
                insideToolCall = false
                continue
            }

            if let openRange = buffer.range(of: Self.openTag) {
                // Flush any prose that sits before the open tag.
                let prose = String(buffer[buffer.startIndex..<openRange.lowerBound])
                if !prose.isEmpty {
                    events.append(.text(prose))
                }
                buffer.removeSubrange(buffer.startIndex..<openRange.upperBound)
                insideToolCall = true
                continue
            }

            // No open tag in the buffer. Flush everything EXCEPT a
            // trailing partial-tag prefix, otherwise we'd emit a stray
            // `<` that belongs to a yet-to-arrive `<tool_call>`.
            let safeEnd = Self.safePrefixEnd(of: buffer, partialOf: Self.openTag)
            if safeEnd > buffer.startIndex {
                let flushable = String(buffer[buffer.startIndex..<safeEnd])
                if !flushable.isEmpty {
                    events.append(.text(flushable))
                }
                buffer.removeSubrange(buffer.startIndex..<safeEnd)
            }
            return events
        }
    }

    /// Flush any remaining buffered text at end-of-stream. Called by the
    /// session right before emitting `.done`. If we're still inside a
    /// `<tool_call>` at this point, the envelope was never closed — we
    /// surface it as `malformedCall` carrying the raw buffered inside.
    mutating func finish() -> [Event] {
        var events: [Event] = []
        if insideToolCall {
            events.append(.malformedCall(raw: buffer))
            buffer.removeAll()
            insideToolCall = false
        } else if !buffer.isEmpty {
            events.append(.text(buffer))
            buffer.removeAll()
        }
        return events
    }

    // MARK: - Internals

    /// Decode the inner JSON of a `<tool_call>` envelope into a
    /// `(name, arguments)` pair. Returns `.malformedCall` on decode
    /// failure instead of throwing — the stream must keep flowing.
    private func decode(inner: String) -> Event {
        let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else {
            return .malformedCall(raw: inner)
        }
        do {
            let payload = try JSONDecoder().decode(QwenToolCallPayload.self, from: data)
            let args: [String: JSONValue]
            switch payload.arguments {
            case .some(.object(let dict)): args = dict
            case .some(.null), .none: args = [:]
            default:
                return .malformedCall(raw: inner)
            }
            return .toolCall(name: payload.name, arguments: args)
        } catch {
            return .malformedCall(raw: inner)
        }
    }

    /// Returns the index up to which `buffer` can be safely emitted as
    /// plain text without accidentally splitting a not-yet-complete
    /// `<tool_call>` open tag. If the tail of `buffer` happens to match
    /// a prefix of `partialOf`, we have to hold those bytes back.
    private static func safePrefixEnd(
        of buffer: String,
        partialOf target: String
    ) -> String.Index {
        // Walk shrinking tail lengths until the tail matches a prefix of
        // the target (or hits zero). Max tail length is target.count - 1.
        let maxTail = target.count - 1
        let limit = min(maxTail, buffer.count)
        for tailLen in stride(from: limit, through: 1, by: -1) {
            let tailStart = buffer.index(buffer.endIndex, offsetBy: -tailLen)
            let tail = buffer[tailStart..<buffer.endIndex]
            let prefix = target.prefix(tailLen)
            if tail == prefix {
                return tailStart
            }
        }
        return buffer.endIndex
    }
}

/// Wire shape of a Qwen 2.5 tool-call payload. `arguments` is decoded
/// permissively as a `JSONValue` and re-validated as an object by the
/// parser so type mismatches become `malformedCall`, not decode throws.
private struct QwenToolCallPayload: Decodable {
    let name: String
    let arguments: JSONValue?
}

// MARK: - QwenLlamaCppChatSession

/// Qwen 2.5 1.5B-Instruct backend driven by `llama.cpp`.
///
/// This is a scaffolding commit: the entire llama-dependent code path is
/// guarded behind `#if canImport(LlamaSwift)` because the llama.cpp SPM
/// package has not yet been added to `LittleE.xcodeproj` (an off-limits
/// file for managed agents — the human owner flips it on). Today,
/// `stream()` always throws `QwenLlamaCppChatSessionError.llamaDependencyMissing`
/// so the Chat tab surfaces a "not configured" error instead of hanging.
///
/// Mirrors the shape of `Gemma4MLXChatSession` so the swap is minimal
/// once the dep lands:
/// - Static `NSLock`-guarded container cache + `inFlightTask` so
///   generation is serialized process-wide (llama.cpp contexts aren't
///   reentrant).
/// - `warmUp()` hook for launch-time preload.
/// - Per-turn `stream(messages:tools:)` builds the chat template from
///   history, runs inference, pipes raw chunks through
///   `QwenToolCallStreamParser`, and emits `.toolCall` / `.token` deltas.
final class QwenLlamaCppChatSession: LittleECore.ChatSession, @unchecked Sendable {

    // MARK: - Shared process state

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedContainer: QwenContainer?
    nonisolated(unsafe) private static var inFlightTask: Task<Void, Never>?

    private static func loadedContainer() -> QwenContainer? {
        lock.lock(); defer { lock.unlock() }
        return cachedContainer
    }

    private static func storeContainer(_ container: QwenContainer) {
        lock.lock(); defer { lock.unlock() }
        cachedContainer = container
    }

    private static func setInFlight(_ task: Task<Void, Never>?) {
        lock.lock(); defer { lock.unlock() }
        inFlightTask = task
    }

    private static func currentInFlight() -> Task<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        return inFlightTask
    }

    /// Preload and cache the Qwen container so the first real `stream()`
    /// call skips the model-load phase. Safe to call from app launch on
    /// a detached Task — it's a no-op if the container is already cached
    /// and swallows loader errors (best-effort warmup).
    static func warmUp(
        loader: any QwenModelLoader = LiveQwenModelLoader()
    ) async {
        if loadedContainer() != nil { return }
        guard let container = try? await loader.loadContainer(progress: { _ in }) else {
            return
        }
        storeContainer(container)
    }

    // MARK: - Instance

    private let loader: any QwenModelLoader
    private var activeTask: Task<Void, Never>?

    init(loader: any QwenModelLoader = LiveQwenModelLoader()) throws {
        // In principle llama.cpp can run on the CPU path anywhere, but
        // the `mattt/llama.swift` xcframework ships with Metal enabled
        // and its residency-set init (`ggml_metal_rsets_init`) hangs
        // on the iOS simulator — iOS 26 simulator Metal doesn't
        // implement `MTLResidencySet`. The hang surfaces as a
        // `ggml_abort` deep inside `llama_decode`, not as an init-time
        // error, so gating here is the cleanest way to keep Chat
        // usable on the sim. Real devices have a working Metal stack
        // and are unaffected.
        #if targetEnvironment(simulator)
        throw QwenLlamaCppChatSessionError.unsupportedDevice
        #else
        self.loader = loader
        #endif
    }

    // MARK: - ChatSession

    func stream(_ text: String) -> AsyncThrowingStream<ChatDelta, Error> {
        stream(
            messages: [ChatMessage(role: .user, text: text)],
            tools: nil
        )
    }

    func stream(
        messages: [ChatMessage],
        tools: ToolRegistry?
    ) -> AsyncThrowingStream<ChatDelta, Error> {
        AsyncThrowingStream { continuation in
            #if canImport(LlamaSwift)
            let loader = self.loader
            let prior = Self.currentInFlight()
            let task = Task {
                if let prior {
                    _ = await prior.value
                }
                do {
                    let container = try await Self.ensureContainer(
                        loader: loader,
                        continuation: continuation
                    )
                    try await Self.runGeneration(
                        container: container,
                        messages: messages,
                        tools: tools,
                        continuation: continuation
                    )
                    continuation.yield(.done)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let erased = Task { _ = await task.value }
            Self.setInFlight(erased)
            self.activeTask = erased
            continuation.onTermination = { _ in task.cancel() }
            #else
            // llama.cpp SPM dep isn't wired yet. Surface the condition
            // as a typed error so the UI can render a "not configured"
            // alert instead of hanging. No background work is spawned.
            continuation.finish(
                throwing: QwenLlamaCppChatSessionError.llamaDependencyMissing
            )
            #endif
        }
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
    }

    // MARK: - llama.cpp wiring (guarded)

    #if canImport(LlamaSwift)

    /// Ensure the shared `QwenContainer` is loaded, streaming progress
    /// through to the caller as `.modelLoading` deltas. Returns the
    /// cached container on subsequent calls.
    private static func ensureContainer(
        loader: any QwenModelLoader,
        continuation: AsyncThrowingStream<ChatDelta, Error>.Continuation
    ) async throws -> QwenContainer {
        if let cached = loadedContainer() {
            return cached
        }
        let container = try await loader.loadContainer { progress in
            continuation.yield(.modelLoading(progress))
        }
        storeContainer(container)
        return container
    }

    /// Runs a single turn of llama.cpp inference against the cached
    /// container, piping raw chunks through `QwenToolCallStreamParser`
    /// and emitting `.token` / `.toolCall` deltas into `continuation`.
    ///
    /// Greedy sampler, 512-token budget. Qwen 2.5 ChatML template
    /// (`<|im_start|>role\n...<|im_end|>`) is rendered from
    /// `ProjectedHistory` and tokenized with special-token parsing on so
    /// the im_start/im_end markers become single tokens.
    private static func runGeneration(
        container: QwenContainer,
        messages: [ChatMessage],
        tools: ToolRegistry?,
        continuation: AsyncThrowingStream<ChatDelta, Error>.Continuation
    ) async throws {
        let model = container.model
        let ctx = container.context
        guard let vocab = llama_model_get_vocab(model) else {
            throw QwenLlamaCppChatSessionError.generationFailed("null vocab")
        }

        let history = Self.splitHistory(messages: messages, tools: tools)
        let prompt = Self.renderChatMLPrompt(history: history)

        let tokens = try Self.tokenize(prompt: prompt, vocab: vocab)
        if tokens.isEmpty {
            throw QwenLlamaCppChatSessionError.generationFailed("empty tokenization")
        }

        // Decode the prompt in a single batch. `llama_batch_get_one`
        // returns a struct that borrows the token pointer — llama_decode
        // must be called while the buffer is still live, so everything
        // stays inside the withUnsafeMutableBufferPointer closure.
        var promptTokens = tokens
        let promptDecode: Int32 = promptTokens.withUnsafeMutableBufferPointer { buf in
            let batch = llama_batch_get_one(buf.baseAddress, Int32(buf.count))
            return llama_decode(ctx, batch)
        }
        if promptDecode != 0 {
            throw QwenLlamaCppChatSessionError.generationFailed("decode(prompt) failed")
        }

        // Build a greedy sampler chain.
        let sparams = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(sparams) else {
            throw QwenLlamaCppChatSessionError.generationFailed("sampler_chain_init failed")
        }
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        let eos = llama_vocab_eos(vocab)
        var parser = QwenToolCallStreamParser()
        var generated: Int32 = 0
        let maxNew: Int32 = 512

        while generated < maxNew {
            if Task.isCancelled { throw CancellationError() }

            let token = llama_sampler_sample(sampler, ctx, -1)
            if token == eos { break }

            if let piece = Self.pieceString(vocab: vocab, token: token) {
                for event in parser.feed(piece) {
                    Self.yield(event: event, into: continuation)
                }
            }

            var next: [llama_token] = [token]
            let stepDecode: Int32 = next.withUnsafeMutableBufferPointer { buf in
                let batch = llama_batch_get_one(buf.baseAddress, 1)
                return llama_decode(ctx, batch)
            }
            if stepDecode != 0 {
                throw QwenLlamaCppChatSessionError.generationFailed("decode(step) failed")
            }
            generated += 1
        }

        for event in parser.finish() {
            Self.yield(event: event, into: continuation)
        }
    }

    /// Tokenize `prompt` with `parse_special = true` so ChatML markers
    /// collapse into their dedicated vocab ids. Two-pass: first call with
    /// a null buffer to learn the required length, then allocate and
    /// fill. Matches the llama.cpp reference examples.
    private static func tokenize(
        prompt: String,
        vocab: OpaquePointer
    ) throws -> [llama_token] {
        let byteCount = Int32(prompt.utf8.count)
        let needed: Int32 = prompt.withCString { cstr in
            -llama_tokenize(vocab, cstr, byteCount, nil, 0, true, true)
        }
        if needed <= 0 {
            throw QwenLlamaCppChatSessionError.generationFailed(
                "tokenize probe returned \(needed)"
            )
        }
        var out = [llama_token](repeating: 0, count: Int(needed))
        let written: Int32 = prompt.withCString { cstr in
            out.withUnsafeMutableBufferPointer { buf in
                llama_tokenize(vocab, cstr, byteCount, buf.baseAddress, Int32(buf.count), true, true)
            }
        }
        if written < 0 {
            throw QwenLlamaCppChatSessionError.generationFailed(
                "tokenize fill returned \(written)"
            )
        }
        return Array(out.prefix(Int(written)))
    }

    /// Convert a single token id to its UTF-8 piece. Returns `nil` when
    /// `llama_token_to_piece` emits a fragment that isn't valid UTF-8 on
    /// its own — the next token will usually complete the glyph, and the
    /// dropped bytes are acceptable for streaming to the parser.
    private static func pieceString(
        vocab: OpaquePointer,
        token: llama_token
    ) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        let n = buf.withUnsafeMutableBufferPointer { ptr in
            llama_token_to_piece(vocab, token, ptr.baseAddress, Int32(ptr.count), 0, false)
        }
        if n <= 0 { return nil }
        let bytes = buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func yield(
        event: QwenToolCallStreamParser.Event,
        into continuation: AsyncThrowingStream<ChatDelta, Error>.Continuation
    ) {
        switch event {
        case .text(let text):
            continuation.yield(.token(text))
        case .toolCall(let name, let arguments):
            continuation.yield(
                .toolCall(
                    id: UUID().uuidString,
                    name: name,
                    arguments: ToolArguments(arguments)
                )
            )
        case .malformedCall(let raw):
            continuation.yield(.token("[malformed tool_call: \(raw)]"))
        }
    }

    #endif

    /// Render a `ProjectedHistory` in Qwen 2.5's ChatML layout. Qwen's
    /// tokenizer adds `<|im_start|>` / `<|im_end|>` as single special
    /// tokens when `parse_special` is on, so the line breaks between
    /// segments are part of the canonical template.
    ///
    /// Kept outside the `#if canImport(LlamaSwift)` guard so it can be
    /// unit-tested without the llama.cpp dependency — this is the
    /// primary way we exercise template correctness on the simulator
    /// now that `stream()` is device-only.
    static func renderChatMLPrompt(history: ProjectedHistory) -> String {
        var out = "<|im_start|>system\n\(history.system)<|im_end|>\n"
        for turn in history.turns {
            out += "<|im_start|>\(turn.role.rawValue)\n\(turn.text)<|im_end|>\n"
        }
        out += "<|im_start|>assistant\n"
        return out
    }

    // MARK: - History projection
    //
    // Kept outside the `#if canImport(LlamaSwift)` guard so it's reachable
    // from future unit tests once we start exercising the chat template
    // independently of llama inference.

    /// Projects a `ChatMessage` history into the Qwen 2.5 chat-template
    /// shape llama.cpp's tokenizer expects: a system message listing
    /// available tools, followed by alternating user / assistant turns.
    ///
    /// Tool results produced by the host are reflected back as
    /// `<tool_response>{"name": "...", "content": "..."}</tool_response>`
    /// blocks inside a user turn, matching Qwen 2.5's training format so
    /// the model can condition on prior tool outputs.
    struct ProjectedHistory: Equatable {
        var system: String
        var turns: [Turn]
        struct Turn: Equatable {
            enum Role: String, Equatable { case user, assistant }
            var role: Role
            var text: String
        }
    }

    static func splitHistory(
        messages: [ChatMessage],
        tools: ToolRegistry?
    ) -> ProjectedHistory {
        let system = Self.systemPrompt(tools: tools)
        var turns: [ProjectedHistory.Turn] = []
        for message in messages {
            switch message.role {
            case .system:
                continue
            case .user:
                turns.append(.init(role: .user, text: message.text))
            case .assistant:
                turns.append(.init(role: .assistant, text: message.text))
            case .tool:
                // Host-executed tool results become a user-side
                // `<tool_response>` block on the preceding user turn.
                if case let .result(_, name, result) = message.toolEntry {
                    let payload = Self.toolResponseEnvelope(name: name, result: result)
                    if let last = turns.last, last.role == .user {
                        turns[turns.count - 1].text += "\n" + payload
                    } else {
                        turns.append(.init(role: .user, text: payload))
                    }
                }
            }
        }
        return ProjectedHistory(system: system, turns: turns)
    }

    private static func systemPrompt(tools: ToolRegistry?) -> String {
        let stamp = ClaudeChatSession.todayDateFormatter.string(from: Date())
        let tz = TimeZone.current
        let tzName = tz.localizedName(for: .shortGeneric, locale: .current) ?? tz.identifier
        let offsetSeconds = tz.secondsFromGMT()
        let sign = offsetSeconds >= 0 ? "+" : "-"
        let absOffset = abs(offsetSeconds)
        let tzOffset = String(format: "UTC%@%02d:%02d", sign, absOffset / 3600, (absOffset % 3600) / 60)
        var lines = [
            "You are the LittleE Assistant, an on-device helper that logs baby activities.",
            "Today: \(stamp). Timezone: \(tzName) (\(tzOffset)).",
            "All timestamps must be local time without Z suffix (e.g. 2026-04-19T14:30:00).",
            "When a user asks to log data, call the appropriate tool using Qwen's native format:",
            "<tool_call>{\"name\": \"...\", \"arguments\": {...}}</tool_call>"
        ]
        if let tools, !tools.all.isEmpty {
            lines.append("Available tools:")
            for tool in tools.all {
                lines.append("- \(tool.name): \(tool.description)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func toolResponseEnvelope(name: String, result: ToolResult) -> String {
        // Keep the envelope byte-for-byte identical to Qwen 2.5's
        // training distribution. `content` is always a string on the
        // wire; we serialize the structured result summary into it.
        let escaped = result.content.replacingOccurrences(of: "\"", with: "\\\"")
        return "<tool_response>{\"name\": \"\(name)\", \"content\": \"\(escaped)\"}</tool_response>"
    }
}
