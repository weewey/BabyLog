import Foundation
import BabyLogCore
import MLXLMCommon

/// Typed errors surfaced by the Qwen on-device backend.
enum QwenMLXChatSessionError: Error, Equatable {
    case unsupportedDevice
    case modelLoadFailed(String)
    case generationFailed(String)
}

/// Qwen 3.5 9B backend using `mlx-swift-lm`.
///
/// Mirrors the lifecycle invariants of `Gemma4MLXChatSession`:
/// - **Container is cached process-wide.** The MLX `ModelContainer` is
///   loaded once per app launch and reused across all turns.
/// - **MLX generation is serialized.** A new `stream()` awaits any prior
///   in-flight task before touching the container.
/// - **Tool tokens are parsed locally.** Qwen 3 emits tool calls as
///   `<tool_call>{"name":...,"arguments":{...}}</tool_call>` JSON envelopes.
///   `QwenToolCallStreamParser` strips these from the text stream and
///   emits real `.toolCall` deltas so raw JSON never leaks as prose.
final class QwenMLXChatSession: BabyLogCore.ChatSession, @unchecked Sendable {

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

    static func startWarmUp(loader: any QwenMLXModelLoader = LiveQwenMLXModelLoader()) {
        lock.lock()
        guard cachedContainer == nil, inFlightTask == nil else {
            lock.unlock()
            return
        }
        let task = Task<Void, Never>(priority: .utility) {
            guard let container = try? await loader.loadContainer(progress: { _ in }) else { return }
            Self.storeContainer(container)
        }
        inFlightTask = task
        lock.unlock()
    }

    static func warmUp(loader: any QwenMLXModelLoader = LiveQwenMLXModelLoader()) async {
        startWarmUp(loader: loader)
        if let task = currentInFlight() { await task.value }
    }

    private static func setInFlight(_ task: Task<Void, Never>?) {
        lock.lock(); defer { lock.unlock() }
        inFlightTask = task
    }

    private static func currentInFlight() -> Task<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        return inFlightTask
    }

    // MARK: - Instance

    private let loader: any QwenMLXModelLoader

    init(loader: any QwenMLXModelLoader = LiveQwenMLXModelLoader()) throws {
        #if targetEnvironment(simulator)
        throw QwenMLXChatSessionError.unsupportedDevice
        #else
        self.loader = loader
        #endif
    }

    // MARK: - ChatSession

    func stream(_ text: String) -> AsyncThrowingStream<ChatDelta, Error> {
        stream(messages: [ChatMessage(role: .user, text: text)], tools: nil)
    }

    func stream(
        messages: [ChatMessage],
        tools: ToolRegistry?
    ) -> AsyncThrowingStream<ChatDelta, Error> {
        AsyncThrowingStream { continuation in
            let loader = self.loader
            let prior = Self.currentInFlight()
            var recorder = GemmaTelemetryRecorder(historyCount: messages.count)
            let task = Task {
                if let prior { _ = await prior.value }
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

    func cancel() { Self.currentInFlight()?.cancel() }

    // MARK: - Load + progress

    private static func ensureContainer(
        loader: any QwenMLXModelLoader,
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
            throw QwenMLXChatSessionError.modelLoadFailed(String(describing: error))
        }
    }

    // MARK: - Generation

    private static func runGeneration(
        container: ModelContainer,
        messages: [ChatMessage],
        tools: ToolRegistry?,
        continuation: AsyncThrowingStream<ChatDelta, Error>.Continuation,
        recorder: inout GemmaTelemetryRecorder
    ) async throws {
        let toolList: [any ChatTool] = filterToolsForOnDevice(tools?.all ?? [])
        let (history, lastUser) = splitHistory(messages, today: Date(), tools: toolList)
        guard let lastUser else { return }

        let thinkingEnabled = UserDefaults.standard.bool(forKey: "chat.enableThinking")
        let session = MLXLMCommon.ChatSession(
            container,
            history: history,
            additionalContext: ["enable_thinking": thinkingEnabled]
        )

        var parser = QwenToolCallStreamParser()
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
                    let args = Gemma4ToolMapping.toolArguments(from: call.function.arguments)
                    continuation.yield(.toolCall(
                        id: UUID().uuidString,
                        name: call.function.name,
                        arguments: args
                    ))
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
            throw QwenMLXChatSessionError.generationFailed(String(describing: error))
        }
    }

    // MARK: - Tool filtering

    private static let onDeviceToolAllowlist: Set<String> = [
        "createFeedLog", "listRecentFeedLogs", "getTodayFeedSummary",
        "createDiaperLog", "listRecentDiaperLogs",
        "createPumpingSession", "listRecentPumpingSessions",
        "createGrowthMeasurement",
        "createMilestone",
    ]

    static func filterToolsForOnDevice(_ tools: [any ChatTool]) -> [any ChatTool] {
        tools.filter { onDeviceToolAllowlist.contains($0.name) }
    }

    // MARK: - History projection

    static let todayDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Project `ChatViewModel`'s messages into `(history, lastUserPrompt)`
    /// for `MLXLMCommon.ChatSession`. Tool calls are rendered as
    /// `<tool_call>` JSON in assistant turns; tool results as
    /// `<tool_response>` in user turns — Qwen 3's documented format.
    static func splitHistory(
        _ messages: [ChatMessage],
        today: Date,
        tools: [any ChatTool] = []
    ) -> (history: [Chat.Message], lastUser: String?) {
        guard !messages.isEmpty else { return ([], nil) }

        var history: [Chat.Message] = [
            .system(qwenSystemPrompt(today: today, tools: tools))
        ]

        var effective = messages
        // Strip empty trailing assistant shell from ChatViewModel's tool loop.
        if let last = effective.last,
           last.role == .assistant,
           last.text.isEmpty,
           last.intent == nil,
           last.reasoning == nil {
            effective.removeLast()
        }

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
                if !msg.text.isEmpty {
                    history.append(.assistant(msg.text))
                }
            case .system:
                continue
            case .tool:
                guard let entry = msg.toolEntry else { continue }
                switch entry {
                case .call(_, let name, let arguments):
                    history.append(.assistant(renderQwenCall(name: name, arguments: arguments)))
                case .result(_, let name, let result):
                    history.append(.user(renderToolResponse(name: name, content: result.content)))
                }
            }
        }
        return (history, lastUser)
    }

    /// Render an assistant tool call in Qwen 3's JSON envelope format.
    private static func renderQwenCall(name: String, arguments: ToolArguments) -> String {
        var obj: [String: Any] = ["name": name]
        var args: [String: Any] = [:]
        for (k, v) in arguments.values {
            args[k] = jsonAny(v)
        }
        obj["arguments"] = args
        let data = (try? JSONSerialization.data(
            withJSONObject: obj,
            options: [.sortedKeys]
        )) ?? Data()
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return "<tool_call>\(json)</tool_call>"
    }

    /// Render a tool result in Qwen 3's `<tool_response>` format.
    private static func renderToolResponse(name: String, content: String) -> String {
        _ = name
        return "<tool_response>\n\(content)\n</tool_response>\nNow tell the user the result using the data above."
    }

    /// Recursively convert `JSONValue` to `Any` for `JSONSerialization`.
    private static func jsonAny(_ value: BabyLogCore.JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map(jsonAny)
        case .object(let o): return o.mapValues(jsonAny)
        }
    }

    // MARK: - System prompt

    /// Qwen 3's documented tool format: JSON array inside `<tools>` tags in
    /// the system prompt. The model emits calls as
    /// `<tool_call>{"name":"...","arguments":{...}}</tool_call>`.
    static func qwenSystemPrompt(today: Date, tools: [any ChatTool]) -> String {
        let stamp = todayDateFormatter.string(from: today)
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

        var base = """
        You are the BabyLog Assistant helping track baby Ethan (born 2026-04-07). \
        Now: \(stamp)T\(timeStamp) (\(tzName), \(tzOffset)). \
        For datetime args use this exact format: \(stamp)T\(timeStamp) — \
        never use JavaScript date expressions. \
        Be warm and brief. Pick defaults and act — never ask to clarify.
        """

        if !tools.isEmpty {
            let toolSpecs: [[String: Any]] = tools.map { tool in
                var properties: [String: Any] = [:]
                for (name, prop) in tool.inputSchema.properties {
                    var propDict: [String: Any] = [
                        "type": prop.type == .dateTime ? "string" : prop.type.rawValue
                    ]
                    if let desc = prop.description { propDict["description"] = desc }
                    if prop.type == .string, let values = prop.enumValues {
                        propDict["enum"] = values
                    }
                    properties[name] = propDict
                }
                let parameters: [String: Any] = [
                    "type": "object",
                    "properties": properties,
                    "required": tool.inputSchema.required,
                ]
                return [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": parameters,
                    ] as [String: Any],
                ]
            }
            let toolsData = (try? JSONSerialization.data(
                withJSONObject: toolSpecs,
                options: [.prettyPrinted, .sortedKeys]
            )) ?? Data()
            let toolsJson = String(data: toolsData, encoding: .utf8) ?? "[]"
            base += """


            # Tools

            <tools>
            \(toolsJson)
            </tools>

            Call a tool by emitting: <tool_call>{"name":"toolName","arguments":{"key":"value"}}</tool_call>
            Multiple calls = multiple envelopes back to back.
            After receiving a <tool_response>, relay the exact numbers to the user.
            Never invent IDs — call listRecent* first when you need one.
            """
        }
        return base
    }
}

// MARK: - Streaming tool-call parser

/// Incremental parser for Qwen 3's tool-call format:
///
///     <tool_call>{"name":"funcName","arguments":{"key":"value"}}</tool_call>
///
/// and reasoning blocks:
///
///     <think>chain of thought</think>
///
/// Text outside these markers streams as normal `.token` deltas.
/// Partial markers are held back so cross-chunk splits never leak raw JSON.
struct QwenToolCallStreamParser: Sendable {
    private var buffer: String = ""

    nonisolated private static let toolCallOpen  = "<tool_call>"
    nonisolated private static let toolCallClose = "</tool_call>"
    nonisolated private static let thinkOpen     = "<think>"
    nonisolated private static let thinkClose    = "</think>"

    // Longest prefix of any sentinel we must hold back to avoid splitting.
    nonisolated private static var allSentinels: [String] {
        [toolCallOpen, toolCallClose, thinkOpen, thinkClose]
    }

    nonisolated init() {}

    nonisolated mutating func consume(_ piece: String) -> [ChatDelta] {
        buffer += piece
        var out: [ChatDelta] = []

        while true {
            // 1. Drain complete <think>...</think> blocks first.
            if let thinkRange = buffer.range(of: Self.thinkOpen) {
                let prefix = String(buffer[..<thinkRange.lowerBound])
                if !prefix.isEmpty { out.append(.token(prefix)) }
                let afterOpen = thinkRange.upperBound
                guard let closeRange = buffer.range(
                    of: Self.thinkClose,
                    range: afterOpen..<buffer.endIndex
                ) else {
                    // Hold from the opener onward.
                    buffer = String(buffer[thinkRange.lowerBound...])
                    return out
                }
                let body = String(buffer[afterOpen..<closeRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty { out.append(.reasoning(text: body, signature: "")) }
                buffer = String(buffer[closeRange.upperBound...])
                continue
            }

            // 2. Drain complete <tool_call>...</tool_call> envelopes.
            if let openRange = buffer.range(of: Self.toolCallOpen) {
                let prefix = String(buffer[..<openRange.lowerBound])
                if !prefix.isEmpty { out.append(.token(prefix)) }
                let afterOpen = openRange.upperBound
                guard let closeRange = buffer.range(
                    of: Self.toolCallClose,
                    range: afterOpen..<buffer.endIndex
                ) else {
                    buffer = String(buffer[openRange.lowerBound...])
                    return out
                }
                let json = String(buffer[afterOpen..<closeRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let call = Self.parseCall(json: json) {
                    out.append(.toolCall(id: UUID().uuidString, name: call.name, arguments: call.arguments))
                }
                buffer = String(buffer[closeRange.upperBound...])
                continue
            }

            // 3. No complete sentinel in buffer — emit safe prefix.
            let safe = Self.safeEmitBoundary(in: buffer)
            if safe > buffer.startIndex {
                let chunk = String(buffer[..<safe])
                if !chunk.isEmpty { out.append(.token(chunk)) }
                buffer = String(buffer[safe...])
            }
            return out
        }
    }

    /// Flush any remaining buffered content at end-of-stream.
    nonisolated mutating func flush() -> [ChatDelta] {
        guard !buffer.isEmpty else { return [] }
        var out: [ChatDelta] = []

        // Unclosed <think> → emit as reasoning.
        if buffer.hasPrefix(Self.thinkOpen) {
            let body = String(buffer.dropFirst(Self.thinkOpen.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { out.append(.reasoning(text: body, signature: "")) }
            buffer = ""
            return out
        }
        // Unclosed <tool_call> → try to parse what we have.
        if buffer.hasPrefix(Self.toolCallOpen) {
            let json = String(buffer.dropFirst(Self.toolCallOpen.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let call = Self.parseCall(json: json) {
                out.append(.toolCall(id: UUID().uuidString, name: call.name, arguments: call.arguments))
            }
            buffer = ""
            return out
        }
        // Trailing partial sentinel → drop silently; raw model tokens must
        // never surface as prose.
        let isPotentialSentinel = Self.allSentinels.contains { $0.hasPrefix(buffer) }
        if isPotentialSentinel {
            buffer = ""
            return out
        }
        // Plain text remainder.
        out.append(.token(buffer))
        buffer = ""
        return out
    }

    // MARK: - JSON parse

    private struct ParsedCall {
        let name: String
        let arguments: ToolArguments
    }

    nonisolated private static func parseCall(json: String) -> ParsedCall? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["name"] as? String,
              !name.isEmpty
        else { return nil }

        let rawArgs = obj["arguments"] as? [String: Any] ?? [:]
        let values: [String: BabyLogCore.JSONValue] = rawArgs.reduce(into: [:]) { acc, pair in
            acc[pair.key] = toJSONValue(pair.value)
        }
        return ParsedCall(name: name, arguments: ToolArguments(values))
    }

    nonisolated private static func toJSONValue(_ any: Any) -> BabyLogCore.JSONValue {
        if any is NSNull { return .null }
        if let b = any as? Bool { return .bool(b) }
        if let i = any as? Int { return .int(i) }
        if let d = any as? Double { return .double(d) }
        if let s = any as? String { return .string(s) }
        if let a = any as? [Any] { return .array(a.map(toJSONValue)) }
        if let o = any as? [String: Any] { return .object(o.mapValues(toJSONValue)) }
        return .string(String(describing: any))
    }

    // MARK: - Safe emit boundary

    /// Return the index up to which `buffer` can safely be emitted without
    /// splitting any sentinel (`<tool_call>`, `</tool_call>`, `<think>`,
    /// `</think>`) across chunks.
    nonisolated private static func safeEmitBoundary(in buffer: String) -> String.Index {
        let maxLen = allSentinels.map(\.count).max() ?? 0
        let maxSuffix = min(buffer.count, maxLen - 1)
        for len in stride(from: maxSuffix, through: 1, by: -1) {
            let suffix = buffer.suffix(len)
            if allSentinels.contains(where: { $0.hasPrefix(suffix) }) {
                return buffer.index(buffer.endIndex, offsetBy: -len)
            }
        }
        return buffer.endIndex
    }
}
