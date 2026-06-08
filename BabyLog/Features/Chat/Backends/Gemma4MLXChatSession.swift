import Foundation
import BabyLogCore
import MLXLMCommon

/// Typed errors surfaced by the Gemma 4 on-device backend. Kept narrow so
/// the parity harness can assert the failure path is a Gemma-owned error
/// rather than a raw framework throw.
enum Gemma4MLXChatSessionError: Error, Equatable {
    case unsupportedDevice
    case modelLoadFailed(String)
    case generationFailed(String)
}

/// Gemma 4 E2B backend using `mlx-swift-lm`.
///
/// Key invariants (all bug-fix driven):
/// - **Container is cached process-wide.** The MLX `ModelContainer` is
///   loaded once and reused across every `Gemma4MLXChatSession` instance,
///   so the "Loading Gemma 4…" bar only shows on first use, not on every
///   `send()`. `ChatViewModel` creates a fresh session per turn; without
///   a shared cache the old instance cache was useless.
/// - **MLX generation is serialized.** Only one inference may run against
///   the container at a time. A new `stream()` awaits the prior task
///   before starting its own MLX call, which fixes a crash when the user
///   switches backends mid-generation (old task still running, new
///   Claude/Gemma session stomping shared Metal state).
/// - **Tool tokens are parsed locally.** `mlx-swift-lm`'s
///   `GemmaFunctionParser` does not always intercept `<|tool_call>...`
///   markers — especially on Gemma 4 where `ToolCallFormat.infer()` reads
///   the wrong `model_type`. We run a sliding-window parser over the
///   streamed chunks so raw tool-call markers never leak as plain text.
final class Gemma4MLXChatSession: BabyLogCore.ChatSession, @unchecked Sendable {

    // MARK: - Shared process state

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedContainer: ModelContainer?
    nonisolated(unsafe) private static var inFlightTask: Task<Void, Never>?

    private static func loadedContainer() -> ModelContainer? {
        lock.lock(); defer { lock.unlock() }
        return cachedContainer
    }

    private static func storeContainer(_ container: ModelContainer) {
        lock.lock(); defer { lock.unlock() }
        cachedContainer = container
    }

    // Gemma is loaded lazily on the first `stream()` that uses it (see
    // `ensureContainer`) — there is no launch-time warm-up. `inFlightTask`
    // still serializes in-flight generations so two MLX inferences never run
    // at once (which crashes MLX).

    private static func setInFlight(_ task: Task<Void, Never>?) {
        lock.lock(); defer { lock.unlock() }
        inFlightTask = task
    }

    private static func currentInFlight() -> Task<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        return inFlightTask
    }


    // MARK: - Instance

    private let loader: any Gemma4ModelLoader
    private let childProfile: ChildProfile?

    init(
        loader: any Gemma4ModelLoader = LiveGemma4ModelLoader(),
        childProfile: ChildProfile? = nil
    ) throws {
        #if targetEnvironment(simulator)
        throw Gemma4MLXChatSessionError.unsupportedDevice
        #else
        self.loader = loader
        self.childProfile = childProfile
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
            let loader = self.loader
            let childProfile = self.childProfile
            // Capture the prior task *before* publishing our own handle,
            // otherwise the new task sees itself as the "prior" task and
            // deadlocks awaiting its own completion.
            let prior = Self.currentInFlight()
            var recorder = GemmaTelemetryRecorder(historyCount: messages.count)
            let task = Task {
                if let prior {
                    _ = await prior.value
                }
                do {
                    let container = try await Self.ensureContainer(
                        loader: loader,
                        continuation: continuation,
                        recorder: &recorder
                    )
                    try await Self.runGeneration(
                        container: container,
                        messages: messages,
                        tools: tools,
                        childProfile: childProfile,
                        continuation: continuation,
                        recorder: &recorder
                    )
                    continuation.yield(.done)
                    continuation.finish()
                    recorder.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                Self.setInFlight(nil)
            }
            Self.setInFlight(task)
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func cancel() {
        Self.currentInFlight()?.cancel()
        // Drain the GPU so any already-committed command buffer completes while
        // the app is still foreground-eligible. Without this, a buffer in flight
        // when the screen locks fails and MLX rethrows it uncatchably (SIGABRT).
        MLXMemoryTuning.drainGPU()
    }

    // MARK: - Load + progress

    private static func ensureContainer(
        loader: any Gemma4ModelLoader,
        continuation: AsyncThrowingStream<ChatDelta, Error>.Continuation,
        recorder: inout GemmaTelemetryRecorder
    ) async throws -> ModelContainer {
        if let cached = loadedContainer() { return cached }
        recorder.markLoadStart()
        continuation.yield(.modelLoading(0))
        do {
            let container = try await loader.loadContainer { progress in
                continuation.yield(.modelLoading(progress))
            }
            storeContainer(container)
            recorder.markLoadEnd()
            return container
        } catch {
            throw Gemma4MLXChatSessionError.modelLoadFailed(
                String(describing: error)
            )
        }
    }

    // MARK: - Core run loop

    private static func runGeneration(
        container: ModelContainer,
        messages: [ChatMessage],
        tools: ToolRegistry?,
        childProfile: ChildProfile?,
        continuation: AsyncThrowingStream<ChatDelta, Error>.Continuation,
        recorder: inout GemmaTelemetryRecorder
    ) async throws {
        // Defensive: the UI hides the attach-image affordance for
        // non-Claude backends (`ChatSession.supportsImageInput == false`
        // for Gemma), so attachments should never reach this path.
        // Assert loudly in debug builds; drop silently in release.
        if messages.contains(where: { !$0.attachments.isEmpty }) {
            assertionFailure("Gemma backend received image attachments — should be gated in UI")
        }

        let toolList: [any ChatTool] = Self.filterToolsForOnDevice(tools?.all ?? [])
        let (history, lastUser) = splitHistory(
            messages,
            today: Date(),
            tools: toolList,
            childProfile: childProfile
        )
        guard let lastUser else { return }

        // Tool definitions are rendered as compact text in the system
        // prompt (~15 tokens/tool) rather than passed via the structured
        // `tools:` parameter (~200 tokens/tool in full JSON schema form).
        // On a 2B model running on-device, the ~5,000-token overhead of
        // 25 structured ToolSpecs dominated prefill time (~5.7s TTF).
        // Dropping them cuts prompt size by >60%. Our parser handles
        // both ```tool_code``` fences and native `<|tool_call>` envelopes
        // so the model can emit whichever format it chooses.
        let thinkingEnabled = UserDefaults.standard.bool(forKey: "chat.enableThinking")
        let session = MLXLMCommon.ChatSession(
            container,
            history: history,
            additionalContext: ["enable_thinking": thinkingEnabled]
        )

        var parser = GemmaToolCallStreamParser()
        recorder.markGenerationStart()

        do {
            for try await gen in session.streamDetails(
                to: lastUser,
                images: [],
                videos: []
            ) {
                try Task.checkCancellation()
                switch gen {
                case .chunk(let piece):
                    recorder.markChunk()
                    for delta in parser.consume(piece) {
                        if !thinkingEnabled, case .reasoning(let text, _) = delta {
                            continuation.yield(.token(text))
                        } else {
                            continuation.yield(delta)
                        }
                    }
                case .toolCall(let call):
                    recorder.markToolCall()
                    let args = Gemma4ToolMapping.toolArguments(
                        from: call.function.arguments
                    )
                    continuation.yield(
                        .toolCall(
                            id: UUID().uuidString,
                            name: call.function.name,
                            arguments: args
                        )
                    )
                case .info:
                    continue
                }
            }
            for delta in parser.flush() {
                if !thinkingEnabled, case .reasoning(let text, _) = delta {
                    continuation.yield(.token(text))
                } else {
                    continuation.yield(delta)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Gemma4MLXChatSessionError.generationFailed(
                String(describing: error)
            )
        }
    }

    // MARK: - History projection

    /// Split `ChatViewModel`'s interleaved user / assistant / tool
    /// messages into the shape MLX wants: `(history, lastUserPrompt)`.
    ///
    /// Tool-loop invariant: on iteration 2+ the messages array ends with
    /// Tools exposed to the on-device Gemma 4 model. Tools are rendered
    /// in compact one-line form (~15 tokens each) rather than full JSON
    /// schema (~200 tokens each), keeping prefill fast. Full CRUD is
    /// included — edit/delete require the model to call listRecent* first
    /// to obtain a valid id, which the system prompt enforces.
    private static let onDeviceToolAllowlist: Set<String> = [
        // Feed logs
        "createFeedLog", "updateFeedLog", "deleteFeedLog",
        "listRecentFeedLogs", "getTodayFeedSummary",
        // Diaper logs
        "createDiaperLog", "updateDiaperLog", "deleteDiaperLog",
        "listRecentDiaperLogs",
        // Pumping sessions
        "createPumpingSession", "updatePumpingSession", "deletePumpingSession",
        "listRecentPumpingSessions",
        // Growth measurements
        "createGrowthMeasurement", "updateGrowthMeasurement", "deleteGrowthMeasurement",
        // Milestones
        "createMilestone", "updateMilestone", "deleteMilestone",
    ]

    static func filterToolsForOnDevice(_ tools: [any ChatTool]) -> [any ChatTool] {
        tools.filter { onDeviceToolAllowlist.contains($0.name) }
    }

    /// `tool(call) → tool(result)` *after* the most recent user turn. We
    /// must project those into history as `.assistant(<|tool_call>...)`
    /// and `.tool(result)` so Gemma sees "I already called the tool, here
    /// is the result" and replies with a confirmation sentence instead of
    /// re-emitting the same tool call (which would log a duplicate feed).
    static func splitHistory(
        _ messages: [ChatMessage],
        today: Date,
        tools: [any ChatTool] = [],
        childProfile: ChildProfile? = nil
    ) -> (history: [Chat.Message], lastUser: String?) {
        guard !messages.isEmpty else { return ([], nil) }

        var history: [Chat.Message] = [
            .system(gemmaSystemPrompt(today: today, tools: tools, childProfile: childProfile))
        ]

        // Strip any trailing empty assistant shell inserted by ChatViewModel's
        // tool loop before it calls us. That placeholder has no text/intent/
        // reasoning yet and must not be treated as the "last message" for the
        // purpose of determining lastUser — doing so puts splitHistory into the
        // else branch (lastUser = "") which gives the model an empty prompt and
        // produces a silent no-response turn.
        var effective = messages
        if let last = effective.last,
           last.role == .assistant,
           last.text.isEmpty,
           last.intent == nil,
           last.reasoning == nil {
            effective.removeLast()
        }

        // If the last message is a user turn, treat it as the prompt and
        // everything before as history. Otherwise (tool-loop follow-up
        // after a tool result), pop the trailing tool result and pass it
        // as the next user turn wrapped in `tool_output` — the shape
        // Google's Gemma 4 docs specify for returning tool output.
        let prior: ArraySlice<ChatMessage>
        let lastUser: String
        if effective.last?.role == .user {
            prior = effective.dropLast()
            lastUser = effective.last?.text ?? ""
        } else if let tail = effective.last,
                  tail.role == .tool,
                  case .result(_, let name, let result)? = tail.toolEntry {
            prior = effective.dropLast()
            lastUser = renderToolResponse(name: name, content: result.content)
        } else {
            prior = ArraySlice(effective)
            lastUser = ""
        }

        for msg in prior {
            switch msg.role {
            case .user:
                history.append(.user(msg.text))
            case .assistant:
                // Skip empty assistant shells (e.g. the placeholder bubble
                // that ChatViewModel inserts before streaming starts). They
                // carry no content and would produce a blank model turn.
                if !msg.text.isEmpty {
                    history.append(.assistant(msg.text))
                }
            case .system:
                continue
            case .tool:
                guard let entry = msg.toolEntry else { continue }
                switch entry {
                case .call(_, let name, let arguments):
                    let callText = renderGemmaCall(name: name, arguments: arguments)
                    // If the immediately preceding history entry is also an
                    // assistant turn, the model emitted prose *before* the
                    // tool call. Gemma's chat template expects everything
                    // from one assistant turn (prose + tool_code) to live
                    // in a single <start_of_turn>model…<end_of_turn> block.
                    // Two consecutive assistant entries would produce two
                    // model turns, which confuses the model on subsequent
                    // turns. Merge them instead.
                    // Note: Chat.Message is a struct (role + content),
                    // so we check .role instead of using enum pattern matching.
                    if history.last?.role == .assistant {
                        let prev = history.removeLast().content
                        history.append(.assistant(prev + "\n" + callText))
                    } else {
                        history.append(.assistant(callText))
                    }
                case .result(_, let name, let result):
                    // Historical tool results — no "tell the user" directive.
                    // That directive is only load-bearing on the *active* turn
                    // (passed as `lastUser`). Leaving it in history causes the
                    // model to repeat the "relay the result" instruction on
                    // every subsequent turn, producing spurious re-summaries.
                    history.append(.user(renderToolResponse(name: name, content: result.content, isActive: false)))
                }
            }
        }
        return (history, lastUser)
    }

    /// Wrap a tool result in the ```tool_output fenced-block shape
    /// base Gemma 3/4 expects per Google's chat-template docs. The model
    /// sees a user turn containing a `tool_output` markdown code block and
    /// knows to respond with a confirmation sentence rather than re-calling.
    ///
    /// - Parameter isActive: `true` for the current (active) tool result
    ///   turn — adds a directive telling the model to relay the numbers.
    ///   `false` for historical results stored in the context window —
    ///   the plain fence is enough; the directive must not repeat.
    private static func renderToolResponse(name: String, content: String, isActive: Bool = true) -> String {
        // `name` is intentionally dropped — the `tool_output` fence is
        // positional, the model knows which call it pairs with because
        // the assistant's prior turn is the matching `tool_code` block.
        _ = name
        // The explicit directive after the fence is load-bearing on the active
        // turn: without it, Gemma 4 E2B treats the tool_output block as a
        // terminal and replies "What else can I help you with?" instead of
        // quoting the numbers. Historical turns omit it so the model doesn't
        // re-execute the relay instruction on every subsequent message.
        if isActive {
            return "```tool_output\n\(content)\n```\nNow tell the user the result using the data above."
        } else {
            return "```tool_output\n\(content)\n```"
        }
    }

    /// Gemma-specific system prompt. Base Gemma 3/4 (non-FunctionGemma)
    static let todayDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// uses Google's documented `tool_code` markdown-fence format for
    /// tool calls — Python-call syntax inside a ```tool_code``` block —
    /// and receives tool results inside a ```tool_output``` block. We
    /// parse these markdown fences ourselves from the raw text stream.
    ///
    /// Tool list is rendered dynamically from the registry so the model
    /// only sees tools that are actually wired up.
    static func gemmaSystemPrompt(
        today: Date,
        tools: [any ChatTool],
        childProfile: ChildProfile? = nil
    ) -> String {
        let stamp = Self.todayDateFormatter.string(from: today)
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"
        timeFmt.locale = Locale(identifier: "en_US_POSIX")
        timeFmt.timeZone = .current
        let timeStamp = timeFmt.string(from: today)
        let tz = TimeZone.current
        let tzName = tz.localizedName(for: .shortGeneric, locale: .current) ?? tz.identifier
        let offsetSeconds = tz.secondsFromGMT()
        let sign = offsetSeconds >= 0 ? "+" : "-"
        let absOffset = abs(offsetSeconds)
        let tzOffset = String(format: "UTC%@%02d:%02d", sign, absOffset / 3600, (absOffset % 3600) / 60)
        let toolDocs = tools.map(renderToolForPrompt(_:)).joined(separator: "\n")
        let toolBlock = toolDocs.isEmpty
            ? "No tools are currently available."
            : "Tools:\n\(toolDocs)"
        let babyLine: String
        if let profile = childProfile {
            let dob = Self.todayDateFormatter.string(from: profile.dateOfBirth)
            babyLine = "Baby: \(profile.name), born \(dob). "
        } else {
            babyLine = ""
        }
        return """
        BabyLog Assistant. \(babyLine)Now: \(stamp)T\(timeStamp) (\(tzName), \(tzOffset)). \
        For datetime args use this exact format: \(stamp)T\(timeStamp) — \
        never use JavaScript date expressions. \
        Be warm, brief. Pick defaults and act — never ask to clarify.

        \(toolBlock)

        Call tools with: ```tool_code\nfunctionName(arg=value)\n``` \
        Multiple calls = multiple fences. After tool_output you MUST \
        relay the exact numbers to the user — never reply "What else \
        can I help you with?" without first stating the result. \
        Never invent ids — call listRecent* first. \
        Never show internal record ids (the id=... values) to the user — \
        they are for your tool calls only, not useful to a person.
        """
    }

    /// Render one tool for the system prompt: `name(arg: type, ...) — description`.
    /// Kept compact so a 10-tool registry fits in ~40 tokens.
    private static func renderToolForPrompt(_ tool: any ChatTool) -> String {
        let params = tool.inputSchema.properties
            .map { name, prop in
                let typeName = prop.type == .dateTime ? "datetime" : prop.type.rawValue
                return "\(name): \(typeName)"
            }
            .joined(separator: ", ")
        return "- \(tool.name)(\(params)) — \(tool.description)"
    }

    /// Render an assistant tool-call turn into a ```tool_code``` fenced
    /// block with Python-call body so the model sees its own prior call
    /// in the exact shape we parse back out of the stream.
    private static func renderGemmaCall(
        name: String,
        arguments: ToolArguments
    ) -> String {
        let pairs = arguments.values
            .sorted { $0.key < $1.key }
            .map { key, value in "\(key)=\(renderGemmaValue(value))" }
            .joined(separator: ", ")
        return "```tool_code\n\(name)(\(pairs))\n```"
    }

    /// Python-literal serialization for a JSON value inside a `tool_code`
    /// block. Nested objects/arrays are flattened to a JSON-ish string
    /// — our tools don't use them, so round-trip fidelity isn't required.
    private static func renderGemmaValue(_ value: BabyLogCore.JSONValue) -> String {
        switch value {
        case .null: return "None"
        case .bool(let b): return b ? "True" : "False"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .string(let s):
            let escaped = s
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        case .array(let arr):
            return "[" + arr.map(renderGemmaValue(_:)).joined(separator: ", ") + "]"
        case .object(let obj):
            // Tools don't use nested objects; flatten deterministically.
            let inner = obj
                .sorted { $0.key < $1.key }
                .map { "\"\($0.key)\": \(renderGemmaValue($0.value))" }
                .joined(separator: ", ")
            return "{\(inner)}"
        }
    }
}

// MARK: - Sliding-window tool call parser

/// Incremental parser for base Gemma 3/4's markdown `tool_code` fences:
///
///     ```tool_code
///     functionName(arg=value, other="str")
///     ```
///
/// Accumulates streamed chunks and yields a mix of `.token`, `.toolCall`,
/// and `.reasoning` deltas. Prose before/after a fence streams as normal
/// tokens; tool calls only fire once the closing ```` ``` ```` lands, so
/// partial calls never leak to the UI. Back-to-back fences produce
/// multiple parallel `.toolCall` deltas. Any `tool_output` fenced blocks
/// the model echoes are stripped silently — results are fed back through
/// `splitHistory`, not re-emitted from the assistant's own stream.
struct GemmaToolCallStreamParser: Sendable {
    private var buffer: String = ""
    /// True when we are mid-`<|channel|>analysis<|message|>` block and
    /// draining tokens into `reasoningAccum` across chunk boundaries.
    private var inAnalysisMode: Bool = false
    /// Reasoning body built up across chunks inside an analysis channel.
    /// Flushed as a `.reasoning` delta when the terminator lands.
    private var reasoningAccum: String = ""

    nonisolated private static let codeFenceOpen = "```tool_code"
    nonisolated private static let outputFenceOpen = "```tool_output"
    nonisolated private static let fenceClose = "```"
    /// Bare `tool_code\n` emitted without backtick fences. Some Gemma 4
    /// checkpoint variants omit the triple-backtick fence markers entirely,
    /// outputting e.g. `tool_code\ncreateFeedLog(...)` as plain text.
    nonisolated private static let bareToolCodeOpen = "tool_code\n"
    /// Gemma 4 E2B's native tool-call envelope — emitted when the model
    /// decides to call a function outside the documented
    /// ```tool_code``` markdown fence. Observed on TestFlight as e.g.
    /// `<|tool_call>call:listRecentFeedLogs{limit:10}<tool_call|>`,
    /// with multiple back-to-back envelopes in one assistant message
    /// when the model emits parallel calls. Asymmetric tag shapes are
    /// intentional — that's how Gemma was trained.
    nonisolated static let nativeToolOpen = "<|tool_call>"
    nonisolated static let nativeToolClose = "<tool_call|>"
    /// Reasoning marker pairs Gemma 4 E2B emits when `enable_thinking=true`.
    /// Legacy shapes: Google docs suggest `<think>`/`</think>`; earlier
    /// TestFlight builds showed `<|channel>thought ... <|channel|>`. The
    /// real Gemma 4 E2B format is OpenAI Harmony (`<|channel|>analysis
    /// <|message|>...<|end|>` → reasoning, `<|channel|>final<|message|>`
    /// → prose), handled separately in `harmonyNormalize`. These two
    /// kept for backwards compat.
    nonisolated private static let thinkMarkers: [(open: String, close: String)] = [
        ("<|channel>", "<|channel|>"),
        ("<think>", "</think>"),
    ]

    /// OpenAI Harmony control tokens Gemma 4 E2B emits. Order matters:
    /// longer prefixes come first so the matcher prefers the most
    /// specific opener (e.g. `<|start|>assistant` over `<|start|>`).
    nonisolated private static let harmonyOpeners: [String] = [
        "<|channel|>analysis<|message|>",
        "<|channel|>commentary<|message|>",
        "<|channel|>final<|message|>",
        "<|start|>assistant",
        "<|start|>system",
        "<|start|>user",
        "<|end|>",
        "<|return|>",
        "<|start|>",
        "<|message|>",
    ]
    /// Openers that put the parser into analysis (reasoning) mode. The
    /// `commentary` channel is treated as reasoning too since it is
    /// internal chain-of-thought, never user-facing.
    nonisolated private static let analysisOpeners: Set<String> = [
        "<|channel|>analysis<|message|>",
        "<|channel|>commentary<|message|>",
    ]

    nonisolated init() {}

    nonisolated mutating func consume(_ piece: String) -> [ChatDelta] {
        buffer += piece
        var out: [ChatDelta] = harmonyNormalize()

        // 1. Strip any complete reasoning blocks first and emit them as
        // `.reasoning` deltas. Gemma's thinking mode always emits reasoning
        // BEFORE the final answer, so this pass runs before the tool-call
        // scan. If an open marker lacks its close we hold the entire
        // buffer until more bytes arrive — never leak raw reasoning
        // tokens as assistant prose.
        while let hit = Self.firstThinkOpen(in: buffer) {
            let prefix = String(buffer[..<hit.range.lowerBound])
            if !prefix.isEmpty {
                out.append(.token(prefix))
            }
            let searchFrom = hit.range.upperBound
            guard
                let closeRange = buffer.range(
                    of: hit.close,
                    range: searchFrom..<buffer.endIndex
                )
            else {
                // Hold everything from the open marker onward.
                buffer = String(buffer[hit.range.lowerBound...])
                return out
            }
            let body = String(buffer[searchFrom..<closeRange.lowerBound])
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                out.append(.reasoning(text: trimmed, signature: ""))
            }
            buffer = String(buffer[closeRange.upperBound...])
        }

        // 1a. Strip Gemma 4 native `<|tool_call>...<tool_call|>`
        // envelopes. Multiple back-to-back envelopes are each emitted as
        // a separate `.toolCall` delta — looping here is what fixes the
        // "only the first call fires" bug on parallel tool calls. If the
        // opener is found but the closer hasn't arrived, hold the
        // buffer from the opener onward so partial envelopes never leak.
        while let openRange = buffer.range(of: Self.nativeToolOpen) {
            let prefix = String(buffer[..<openRange.lowerBound])
            if !prefix.isEmpty {
                out.append(.token(prefix))
            }
            let searchFrom = openRange.upperBound
            guard
                let closeRange = buffer.range(
                    of: Self.nativeToolClose,
                    range: searchFrom..<buffer.endIndex
                )
            else {
                buffer = String(buffer[openRange.lowerBound...])
                return out
            }
            let body = String(buffer[searchFrom..<closeRange.lowerBound])
            if let call = Self.parseGemmaNativeCall(body: body) {
                out.append(
                    .toolCall(
                        id: UUID().uuidString,
                        name: call.name,
                        arguments: call.arguments
                    )
                )
            }
            buffer = String(buffer[closeRange.upperBound...])
        }

        // 1b. Strip bare `tool_code\n` fences (no backticks).
        // Observed on-device as `tool_code\nfunctionName(args)` with no
        // surrounding triple backticks — probably a checkpoint variant that
        // drops the Markdown wrapper. Same parse path as the fenced format.
        // IMPORTANT: "tool_code\n" is a substring of "```tool_code\n" so we
        // skip any match that is preceded by a backtick — those belong to the
        // main fenced-block loop below.
        while let openRange = buffer.range(of: Self.bareToolCodeOpen) {
            let beforeMatch = buffer[..<openRange.lowerBound]
            if beforeMatch.hasSuffix("`") {
                // This is inside a ```tool_code fence — let the fenced loop handle it.
                break
            }
            let prefix = String(beforeMatch)
            let callStart = openRange.upperBound
            let bodyCandidate = String(buffer[callStart...])
            guard let endOffset = Self.indexAfterCall(in: bodyCandidate) else {
                // Call not yet complete — hold from the bare opener.
                if !prefix.isEmpty { out.append(.token(prefix)) }
                buffer = String(buffer[openRange.lowerBound...])
                return out
            }
            if !prefix.isEmpty { out.append(.token(prefix)) }
            let callBody = String(bodyCandidate[..<endOffset])
            if let call = Self.parsePythonCall(body: callBody) {
                out.append(.toolCall(id: UUID().uuidString, name: call.name, arguments: call.arguments))
            }
            let afterEnd = buffer.index(callStart, offsetBy: bodyCandidate.distance(from: bodyCandidate.startIndex, to: endOffset))
            let remaining = String(buffer[afterEnd...])
            buffer = remaining.hasPrefix("\n") ? String(remaining.dropFirst()) : remaining
        }

        while true {
            // Locate the next `tool_code` or `tool_output` opener,
            // whichever comes first. Prose up to that point is emitted.
            let codeHit = buffer.range(of: Self.codeFenceOpen)
            let outHit = buffer.range(of: Self.outputFenceOpen)
            let firstHit: (range: Range<String.Index>, isOutput: Bool)?
            switch (codeHit, outHit) {
            case let (c?, o?):
                firstHit = c.lowerBound <= o.lowerBound ? (c, false) : (o, true)
            case let (c?, nil):
                firstHit = (c, false)
            case let (nil, o?):
                firstHit = (o, true)
            case (nil, nil):
                firstHit = nil
            }

            if let hit = firstHit {
                // Emit any prose that landed before the fence.
                let prefix = String(buffer[..<hit.range.lowerBound])
                if !prefix.isEmpty {
                    out.append(.token(prefix))
                }
                // Need the matching closing ``` before we can parse.
                let searchFrom = hit.range.upperBound
                guard
                    let endRange = buffer.range(
                        of: Self.fenceClose,
                        range: searchFrom..<buffer.endIndex
                    )
                else {
                    // Incomplete fence — hold from the opener onward.
                    buffer = String(buffer[hit.range.lowerBound...])
                    return out
                }
                let body = String(buffer[searchFrom..<endRange.lowerBound])
                if hit.isOutput {
                    // Swallow tool_output echoes — never re-surface them.
                } else if let call = Self.parsePythonCall(body: body) {
                    out.append(
                        .toolCall(
                            id: UUID().uuidString,
                            name: call.name,
                            arguments: call.arguments
                        )
                    )
                }
                buffer = String(buffer[endRange.upperBound...])
                continue
            }

            // No fence in buffer. Emit everything except the longest
            // suffix that could still be the start of a ```tool_* fence
            // (or a harmony/think opener) on the next chunk.
            let safeEmit = Self.emitBoundary(in: buffer)
            if safeEmit > buffer.startIndex {
                let toEmit = String(buffer[..<safeEmit])
                if !toEmit.isEmpty { out.append(.token(toEmit)) }
                buffer = String(buffer[safeEmit...])
            }
            return out
        }
    }

    /// At end-of-stream, flush whatever's still buffered.
    /// Unclosed `<|tool_call>` envelopes are parsed and emitted as real
    /// `.toolCall` deltas (the model sometimes omits the closing tag for
    /// no-arg calls). Unclosed `<think>` blocks become `.reasoning`.
    /// Everything else that could not be parsed is dropped silently —
    /// raw model tokens must never surface as assistant prose.
    nonisolated mutating func flush() -> [ChatDelta] {
        var out: [ChatDelta] = harmonyNormalize()
        // Drain any still-open analysis block as best-effort reasoning.
        if inAnalysisMode || !reasoningAccum.isEmpty {
            let trimmed = reasoningAccum.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                out.append(.reasoning(text: trimmed, signature: ""))
            }
            reasoningAccum = ""
            inAnalysisMode = false
        }
        // Drop any Harmony control partial left at tail — leaking `<|c…`
        // as prose is worse than silently losing an unterminated token.
        if buffer.hasPrefix("<|"),
           Self.harmonyOpeners.contains(where: { $0.hasPrefix(buffer) }) {
            buffer = ""
        }
        guard !buffer.isEmpty else { return out }
        let remaining = buffer
        buffer = ""
        if let hit = Self.firstThinkOpen(in: remaining) {
            let prefix = String(remaining[..<hit.range.lowerBound])
            if !prefix.isEmpty { out.append(.token(prefix)) }
            let tail = String(remaining[hit.range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty {
                out.append(.reasoning(text: tail, signature: ""))
            }
            return out
        }
        // Unclosed <|tool_call> envelope — model omitted the closing tag.
        // Parse the body and emit as a real tool call rather than prose.
        if remaining.hasPrefix(Self.nativeToolOpen) {
            let afterOpen = remaining.dropFirst(Self.nativeToolOpen.count)
            let body: String
            if let closeRange = afterOpen.range(of: Self.nativeToolClose) {
                body = String(afterOpen[..<closeRange.lowerBound])
            } else {
                body = String(afterOpen)
            }
            if let call = Self.parseGemmaNativeCall(body: body) {
                out.append(.toolCall(id: UUID().uuidString, name: call.name, arguments: call.arguments))
                return out
            }
        }
        // Bare tool_code\n without closing ``` — parse whatever call body exists.
        if remaining.hasPrefix(Self.bareToolCodeOpen) {
            let callBody = String(remaining.dropFirst(Self.bareToolCodeOpen.count))
            if let call = Self.parsePythonCall(body: callBody) {
                out.append(.toolCall(id: UUID().uuidString, name: call.name, arguments: call.arguments))
                return out
            }
        }
        // Drop unrecognised trailing bytes silently rather than surfacing
        // raw model tokens as assistant prose.
        return out
    }

    /// Strip Gemma 4 Harmony control tokens from `buffer`, collecting
    /// analysis-channel content as `.reasoning` deltas. Leaves prose
    /// (plus legacy `<think>` tags and `<|tool_call>` markers) in the
    /// buffer for downstream passes. Partial control tokens at the tail
    /// are held back so cross-chunk splits never leak raw reasoning.
    nonisolated private mutating func harmonyNormalize() -> [ChatDelta] {
        var out: [ChatDelta] = []
        var work = buffer
        var prose = ""

        outer: while !work.isEmpty {
            if inAnalysisMode {
                // Prepend any held-back unsafe suffix from the previous
                // chunk so a control token split across chunks is seen
                // as a single string by the terminator scan.
                if !reasoningAccum.isEmpty {
                    work = reasoningAccum + work
                    reasoningAccum = ""
                }
                // Terminator is whichever comes first: <|end|> (consumed)
                // or the next <|channel|> (left in place so the next
                // iteration re-enters prose mode and parses it).
                var terminator: (range: Range<String.Index>, consume: Bool)?
                if let e = work.range(of: "<|end|>") {
                    terminator = (e, true)
                }
                if let c = work.range(of: "<|channel|>") {
                    if let existing = terminator {
                        if c.lowerBound < existing.range.lowerBound {
                            terminator = (c, false)
                        }
                    } else {
                        terminator = (c, false)
                    }
                }
                if let t = terminator {
                    // Terminator found — emit whatever body remains as a
                    // final reasoning chunk (merged with any held-back
                    // unsafe suffix from the previous chunk) and exit
                    // analysis mode.
                    let tail = String(work[..<t.range.lowerBound])
                    let combined = reasoningAccum + tail
                    if !combined.isEmpty {
                        out.append(.reasoning(text: combined, signature: ""))
                    }
                    reasoningAccum = ""
                    inAnalysisMode = false
                    work = t.consume
                        ? String(work[t.range.upperBound...])
                        : String(work[t.range.lowerBound...])
                    continue
                }
                // No terminator yet — stream the safe prefix now (so the
                // UI sees reasoning tokens live) and hold back only the
                // trailing suffix that could still be the start of a
                // control token on the next chunk.
                let safe = Self.harmonySafeBoundary(in: work)
                let safeChunk = reasoningAccum + String(work[..<safe])
                if !safeChunk.isEmpty {
                    out.append(.reasoning(text: safeChunk, signature: ""))
                }
                reasoningAccum = String(work[safe...])
                work = ""
                break outer
            }

            // Prose mode: find the next `<|`, emit prefix as prose, then
            // match a known Harmony opener or hold back if partial.
            guard let ltRange = work.range(of: "<|") else {
                prose += work
                work = ""
                break
            }
            prose += String(work[..<ltRange.lowerBound])
            let rest = String(work[ltRange.lowerBound...])

            // Harmony openers always start with `<|`, and our fence
            // openers start with backticks — they never collide, so the
            // `<|` branch only matches harmony control tokens.

            var matched: String?
            for opener in Self.harmonyOpeners where rest.hasPrefix(opener) {
                matched = opener
                break
            }
            if let m = matched {
                work = String(rest.dropFirst(m.count))
                if Self.analysisOpeners.contains(m) {
                    inAnalysisMode = true
                }
                continue
            }

            // Could `rest` still become a known token with more bytes?
            let couldComplete = Self.harmonyOpeners.contains { $0.hasPrefix(rest) }
            if couldComplete {
                // Hold back from the `<|` onward for the next chunk.
                work = rest
                break
            }
            // Literal `<|` in content — emit and advance.
            prose += "<|"
            work = String(rest.dropFirst(2))
        }

        buffer = prose + work
        return out
    }

    /// When draining reasoning across a chunk boundary, hold back any
    /// trailing suffix of `work` that could be the start of `<|end|>`
    /// or `<|channel|>` — either terminates the analysis block.
    nonisolated private static func harmonySafeBoundary(
        in work: String
    ) -> String.Index {
        let candidates = ["<|end|>", "<|channel|>"]
        let maxLen = candidates.map(\.count).max() ?? 0
        let maxSuffix = min(work.count, maxLen - 1)
        for len in stride(from: maxSuffix, through: 1, by: -1) {
            let suffix = work.suffix(len)
            if candidates.contains(where: { $0.hasPrefix(suffix) }) {
                return work.index(work.endIndex, offsetBy: -len)
            }
        }
        return work.endIndex
    }

    /// Find the earliest reasoning open marker in `buffer`, along with
    /// the matching close marker string. When two opens start at the
    /// same index we prefer the longer one so `<|channel>thought` wins
    /// over a hypothetical `<|channel>` prefix.
    nonisolated private static func firstThinkOpen(
        in buffer: String
    ) -> (range: Range<String.Index>, close: String)? {
        var best: (range: Range<String.Index>, close: String, openLen: Int)?
        for (open, close) in thinkMarkers {
            guard let r = buffer.range(of: open) else { continue }
            if let current = best {
                if r.lowerBound < current.range.lowerBound {
                    best = (r, close, open.count)
                } else if r.lowerBound == current.range.lowerBound,
                          open.count > current.openLen {
                    best = (r, close, open.count)
                }
            } else {
                best = (r, close, open.count)
            }
        }
        return best.map { ($0.range, $0.close) }
    }

    /// Returns the index up to which `buffer` can safely be emitted
    /// without splitting a potential ```tool_code``` / ```tool_output```
    /// fence, a `<think>` marker, or a harmony control token across
    /// chunks. We hold back the longest suffix that is a prefix of any
    /// of those openers.
    nonisolated private static func emitBoundary(in buffer: String) -> String.Index {
        var candidates = [Self.codeFenceOpen, Self.outputFenceOpen, Self.nativeToolOpen, Self.bareToolCodeOpen]
        candidates.append(contentsOf: Self.thinkMarkers.map(\.open))
        candidates.append(contentsOf: Self.harmonyOpeners)
        let maxLen = candidates.map(\.count).max() ?? 0
        let maxSuffix = min(buffer.count, maxLen - 1)
        for len in stride(from: maxSuffix, through: 1, by: -1) {
            let suffix = buffer.suffix(len)
            if candidates.contains(where: { $0.hasPrefix(suffix) }) {
                return buffer.index(buffer.endIndex, offsetBy: -len)
            }
        }
        return buffer.endIndex
    }

    // MARK: - Body parse: `functionName(arg=value, ...)`

    /// Returns the index in `s` immediately after the closing `)` of the
    /// first balanced Python call expression, or `nil` if the expression
    /// is incomplete (no `)` at depth 0 yet). Used by the bare
    /// `tool_code\n` scanner to know when the call body has fully arrived.
    nonisolated static func indexAfterCall(in s: String) -> String.Index? {
        guard let parenOpen = s.firstIndex(of: "(") else { return nil }
        var depth = 0
        var inString = false
        var escape = false
        var i = s.index(after: parenOpen)
        while i < s.endIndex {
            let c = s[i]
            if inString {
                if escape { escape = false }
                else if c == "\\" { escape = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "(" || c == "[" || c == "{" {
                depth += 1
            } else if c == ")" || c == "]" || c == "}" {
                if c == ")" && depth == 0 { return s.index(after: i) }
                depth -= 1
            }
            i = s.index(after: i)
        }
        return nil
    }

    struct ParsedCall {
        let name: String
        let arguments: ToolArguments
    }

    /// Parse the body of a ```tool_code``` block. Body is expected to
    /// contain a single Python-style call expression:
    ///
    ///     createFeedLog(volumeMl=60, loggedAt="2026-04-15T10:00:00Z")
    ///
    /// Bare identifiers before `(` are the tool name; kwargs inside the
    /// parens use `=`. String literals are double-quoted with `\"` /
    /// `\\` escapes. Numbers and booleans (`True`/`False`/`None`, also
    /// accepts JSON-style `true`/`false`/`null`) are bare.
    nonisolated static func parsePythonCall(body: String) -> ParsedCall? {
        var s = body.trimmingCharacters(in: .whitespacesAndNewlines)
        // Tolerate a stray language tag on the first line
        // (e.g. "python\nname(...)") — rare but harmless.
        if let firstLine = s.split(separator: "\n", maxSplits: 1).first,
           !firstLine.contains("(") {
            s = String(s.drop(while: { $0 != "\n" })).drop(while: { $0 == "\n" }).description
        }
        guard let parenOpen = s.firstIndex(of: "(") else { return nil }
        let name = s[..<parenOpen]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, isValidIdentifier(name) else { return nil }

        // Find matching closing paren at depth 0, respecting string literals.
        var depth = 0
        var inString = false
        var escape = false
        var closeIdx: String.Index?
        var i = s.index(after: parenOpen)
        while i < s.endIndex {
            let c = s[i]
            if inString {
                if escape {
                    escape = false
                } else if c == "\\" {
                    escape = true
                } else if c == "\"" {
                    inString = false
                }
            } else if c == "\"" {
                inString = true
            } else if c == "(" || c == "[" || c == "{" {
                depth += 1
            } else if c == ")" || c == "]" || c == "}" {
                if c == ")" && depth == 0 {
                    closeIdx = i
                    break
                }
                depth -= 1
            }
            i = s.index(after: i)
        }
        guard let close = closeIdx else { return nil }

        let inner = String(s[s.index(after: parenOpen)..<close])
        let pairs = splitTopLevel(inner)
        var values: [String: BabyLogCore.JSONValue] = [:]
        for pair in pairs {
            let trimmed = pair.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let eq = indexOfTopLevelEquals(trimmed) else { continue }
            let key = String(trimmed[..<eq])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = String(trimmed[trimmed.index(after: eq)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            values[key] = decodeValue(raw)
        }
        return ParsedCall(
            name: name,
            arguments: ToolArguments(values)
        )
    }

    /// Parse the body of a native `<|tool_call>...<tool_call|>` envelope.
    /// Primary shape: `call:toolName{key:value, key:"string", key:10}`.
    /// Gemma 4 also emits Python-call syntax for no-arg or simple calls
    /// (e.g. `call:getTodayFeedSummary()`), so we fall back to
    /// `parsePythonCall` when no `{` is present.
    nonisolated static func parseGemmaNativeCall(body: String) -> ParsedCall? {
        var s = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("call:") {
            s = String(s.dropFirst("call:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let braceOpen = s.firstIndex(of: "{") else {
            // No JSON-object body — try Python-call format as fallback.
            return parsePythonCall(body: s)
        }
        let name = s[..<braceOpen]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, isValidIdentifier(name) else { return nil }

        var depth = 0
        var inString = false
        var escape = false
        var closeIdx: String.Index?
        var i = s.index(after: braceOpen)
        while i < s.endIndex {
            let c = s[i]
            if inString {
                if escape { escape = false }
                else if c == "\\" { escape = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "{" || c == "[" || c == "(" {
                depth += 1
            } else if c == "}" || c == "]" || c == ")" {
                if c == "}" && depth == 0 { closeIdx = i; break }
                depth -= 1
            }
            i = s.index(after: i)
        }
        guard let close = closeIdx else { return nil }

        let inner = String(s[s.index(after: braceOpen)..<close])
        let pairs = splitTopLevel(inner)
        var values: [String: BabyLogCore.JSONValue] = [:]
        for pair in pairs {
            let trimmed = pair.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let colon = indexOfTopLevelColon(trimmed) else { continue }
            var key = String(trimmed[..<colon])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if key.hasPrefix("\""), key.hasSuffix("\""), key.count >= 2 {
                key = String(key.dropFirst().dropLast())
            }
            let raw = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            values[key] = decodeValue(raw)
        }
        return ParsedCall(name: name, arguments: ToolArguments(values))
    }

    /// Find the index of the top-level `:` in a `key:value` pair,
    /// ignoring any `:` inside a quoted string or a nested container.
    nonisolated private static func indexOfTopLevelColon(_ s: String) -> String.Index? {
        var inString = false
        var escape = false
        var depth = 0
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if inString {
                if escape { escape = false }
                else if c == "\\" { escape = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "{" || c == "[" || c == "(" {
                depth += 1
            } else if c == "}" || c == "]" || c == ")" {
                depth -= 1
            } else if c == ":" && depth == 0 {
                return i
            }
            i = s.index(after: i)
        }
        return nil
    }

    nonisolated private static func isValidIdentifier(_ s: String) -> Bool {
        guard let first = s.first,
              first.isLetter || first == "_" else { return false }
        for c in s.dropFirst() {
            if !(c.isLetter || c.isNumber || c == "_") { return false }
        }
        return true
    }

    /// Find the index of the top-level `=` in a `key=value` pair,
    /// ignoring any `=` that appears inside a quoted string.
    nonisolated private static func indexOfTopLevelEquals(_ s: String) -> String.Index? {
        var inString = false
        var escape = false
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if inString {
                if escape { escape = false }
                else if c == "\\" { escape = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "=" {
                return i
            }
            i = s.index(after: i)
        }
        return nil
    }

    /// Split on top-level commas, respecting `"..."` string literals
    /// (with `\"` escapes) and `(...)` / `{...}` / `[...]` nesting.
    nonisolated private static func splitTopLevel(_ s: String) -> [String] {
        var result: [String] = []
        var current = ""
        var depth = 0
        var inString = false
        var escape = false
        for c in s {
            if inString {
                if escape {
                    current.append(c)
                    escape = false
                } else if c == "\\" {
                    current.append(c)
                    escape = true
                } else if c == "\"" {
                    current.append(c)
                    inString = false
                } else {
                    current.append(c)
                }
                continue
            }
            if c == "\"" {
                inString = true
                current.append(c)
            } else if c == "(" || c == "[" || c == "{" {
                depth += 1
                current.append(c)
            } else if c == ")" || c == "]" || c == "}" {
                depth -= 1
                current.append(c)
            } else if c == "," && depth == 0 {
                result.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    nonisolated private static func decodeValue(_ raw: String) -> BabyLogCore.JSONValue {
        if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
            let inner = String(raw.dropFirst().dropLast())
            return .string(unescapeString(inner))
        }
        switch raw {
        case "true", "True": return .bool(true)
        case "false", "False": return .bool(false)
        case "null", "None": return .null
        default: break
        }
        if let i = Int(raw) { return .int(i) }
        if let d = Double(raw) { return .double(d) }
        return .string(raw)
    }

    /// Unescape `\"` and `\\` inside a JSON/Python double-quoted string.
    /// Other escape sequences (`\n`, `\t`, …) are passed through as-is
    /// since our tool arguments don't need them.
    nonisolated private static func unescapeString(_ s: String) -> String {
        var out = ""
        var escape = false
        for c in s {
            if escape {
                switch c {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "n": out.append("\n")
                case "t": out.append("\t")
                default:
                    out.append("\\")
                    out.append(c)
                }
                escape = false
            } else if c == "\\" {
                escape = true
            } else {
                out.append(c)
            }
        }
        return out
    }
}
