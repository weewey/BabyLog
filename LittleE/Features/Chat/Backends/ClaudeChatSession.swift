import Foundation
import LittleECore

/// `ChatSession` implementation that streams a reply from the Anthropic
/// Messages API (`claude-opus-4-6`) using Server-Sent Events.
///
/// Design notes:
/// - Networking deliberately lives in the iOS target (not `LittleECore`),
///   because `LittleECore` is pure Swift with no Foundation networking
///   allowances. See `CLAUDE.md` architecture rules.
/// - The tool-use schema + cached system prompt are copy-compatible with
///   `ClaudeAssistant`, so the Chat backend can still log baby events
///   via a single tool called `log_baby_event`. We intentionally expose one
///   multiplexed tool here instead of five separate ones: chat replies want
///   a single structured decision per turn, not a tool_choice race.
/// - Errors are reported as a dedicated `ChatSessionError` enum rather than
///   reusing `AssistantError`: the router and the chat session have
///   different semantics (retries, rate limits, cancellation) and lumping
///   them together confused the call sites during bootstrap.
final class ClaudeChatSession: ChatSession, @unchecked Sendable {

    /// Claude natively accepts base64 `image` content blocks; see
    /// `anthropicMessages(from:)` for the serialization.
    var supportsImageInput: Bool { true }

    static let model = "claude-opus-4-6"
    static let apiVersion = "2023-06-01"

    /// Compile-time-constant endpoint URL. `fatalError` on malformed literal
    /// is genuinely unreachable, allowed by `CLAUDE.md`.
    static let apiEndpoint: URL = {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            fatalError("invalid Anthropic endpoint literal — unreachable")
        }
        return url
    }()

    /// Abstraction over `URLSession.bytes(for:)` so tests can inject a
    /// canned SSE stream without touching the network stack. Real callers
    /// pass `URLSession.shared.bytes(for:)`.
    typealias ByteStreamOpener = @Sendable (URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse)

    private let opener: ByteStreamOpener
    private let apiKeyProvider: @Sendable () -> String?
    private let dateProvider: @Sendable () -> Date

    // Mutable state guarded by `stateLock`.
    private let stateLock = NSLock()
    private var activeTask: Task<Void, Never>?

    init(
        opener: @escaping ByteStreamOpener,
        apiKeyProvider: @escaping @Sendable () -> String? = { ClaudeAPIKeyStore.load() },
        dateProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.opener = opener
        self.apiKeyProvider = apiKeyProvider
        self.dateProvider = dateProvider
    }

    /// Convenience initializer that binds to a real `URLSession`.
    convenience init(
        session: URLSession = .shared,
        apiKeyProvider: @escaping @Sendable () -> String? = { ClaudeAPIKeyStore.load() },
        dateProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            opener: { request in try await session.bytes(for: request) },
            apiKeyProvider: apiKeyProvider,
            dateProvider: dateProvider
        )
    }

    func stream(_ text: String) -> AsyncThrowingStream<ChatDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [opener, apiKeyProvider, dateProvider] in
                do {
                    guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
                        throw ChatSessionError.apiKeyMissing
                    }
                    let request = try Self.makeRequest(apiKey: apiKey, userText: text, today: dateProvider())
                    let (bytes, response) = try await opener(request)
                    try Task.checkCancellation()

                    if let http = response as? HTTPURLResponse {
                        switch http.statusCode {
                        case 200: break
                        case 401, 403: throw ChatSessionError.unauthenticated
                        case 408: throw ChatSessionError.timeout
                        case 429: throw ChatSessionError.rateLimited
                        default:
                            let message = await Self.decodeErrorBody(bytes: bytes)
                            throw ChatSessionError.invalidResponse(status: http.statusCode, message: message)
                        }
                    }

                    try await Self.consumeSSE(bytes: bytes, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as ChatSessionError {
                    continuation.finish(throwing: error)
                } catch let urlError as URLError where urlError.code == .timedOut {
                    continuation.finish(throwing: ChatSessionError.timeout)
                } catch let urlError as URLError where urlError.code == .cancelled {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: ChatSessionError.network)
                }
            }

            stateLock.lock()
            activeTask = task
            stateLock.unlock()

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func cancel() {
        stateLock.lock()
        let task = activeTask
        activeTask = nil
        stateLock.unlock()
        task?.cancel()
    }

    // MARK: - Multi-turn tool-calling entry point

    /// Generic multi-turn streaming that advertises a `ToolRegistry` as
    /// Anthropic tools and emits `.toolCall` deltas for every `tool_use`
    /// block the model returns. The caller (`ChatViewModel`) executes
    /// the tool, appends a `.tool` role message with a `.result` entry
    /// to history, and re-invokes this method. When `tools == nil` (or
    /// empty) this behaves like the legacy `stream(_:)` but passes the
    /// full conversation history instead of a single user message.
    func stream(
        messages: [ChatMessage],
        tools: ToolRegistry?
    ) -> AsyncThrowingStream<ChatDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [opener, apiKeyProvider, dateProvider] in
                do {
                    guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
                        throw ChatSessionError.apiKeyMissing
                    }
                    let request = try Self.makeMultiTurnRequest(
                        apiKey: apiKey,
                        history: messages,
                        tools: tools,
                        today: dateProvider()
                    )
                    let (bytes, response) = try await opener(request)
                    try Task.checkCancellation()

                    if let http = response as? HTTPURLResponse {
                        switch http.statusCode {
                        case 200: break
                        case 401, 403: throw ChatSessionError.unauthenticated
                        case 408: throw ChatSessionError.timeout
                        case 429: throw ChatSessionError.rateLimited
                        default:
                            let message = await Self.decodeErrorBody(bytes: bytes)
                            throw ChatSessionError.invalidResponse(status: http.statusCode, message: message)
                        }
                    }

                    try await Self.consumeMultiTurnSSE(bytes: bytes, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as ChatSessionError {
                    continuation.finish(throwing: error)
                } catch let urlError as URLError where urlError.code == .timedOut {
                    continuation.finish(throwing: ChatSessionError.timeout)
                } catch let urlError as URLError where urlError.code == .cancelled {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: ChatSessionError.network)
                }
            }

            stateLock.lock()
            activeTask = task
            stateLock.unlock()

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Multi-turn SSE consumer

    struct ToolUseState {
        var id: String
        var name: String
        var json: String
    }

    /// SSE consumer for the generic tool-use path. Yields `.token` for
    /// text and `.toolCall(id, name, args)` when a `tool_use` block closes.
    /// Tracks blocks by their `index` so parallel tool uses disambiguate.
    struct ThinkingState {
        var text: String
        var signature: String
    }

    static func consumeMultiTurnSSE<Bytes: AsyncSequence & Sendable>(
        bytes: Bytes,
        continuation: AsyncThrowingStream<ChatDelta, Error>.Continuation
    ) async throws where Bytes.Element == UInt8 {
        var toolStates: [Int: ToolUseState] = [:]
        var thinkingStates: [Int: ThinkingState] = [:]

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty || payload == "[DONE]" { continue }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String
            else { continue }

            switch type {
            case "content_block_start":
                let index = (obj["index"] as? Int) ?? 0
                if let block = obj["content_block"] as? [String: Any],
                   let blockType = block["type"] as? String {
                    switch blockType {
                    case "tool_use":
                        let id = (block["id"] as? String) ?? ""
                        let name = (block["name"] as? String) ?? ""
                        toolStates[index] = ToolUseState(id: id, name: name, json: "")
                    case "thinking":
                        thinkingStates[index] = ThinkingState(text: "", signature: "")
                    default:
                        break
                    }
                }
            case "content_block_delta":
                let index = (obj["index"] as? Int) ?? 0
                guard let delta = obj["delta"] as? [String: Any],
                      let deltaType = delta["type"] as? String
                else { continue }
                switch deltaType {
                case "text_delta":
                    if let text = delta["text"] as? String, !text.isEmpty {
                        continuation.yield(.token(text))
                    }
                case "input_json_delta":
                    if let partial = delta["partial_json"] as? String {
                        toolStates[index, default: ToolUseState(id: "", name: "", json: "")].json += partial
                    }
                case "thinking_delta":
                    if let chunk = delta["thinking"] as? String, !chunk.isEmpty {
                        // Stream incrementally — ChatViewModel appends
                        // text chunks into the existing reasoning block.
                        thinkingStates[index, default: ThinkingState(text: "", signature: "")].text += chunk
                        continuation.yield(.reasoning(text: chunk, signature: ""))
                    }
                case "signature_delta":
                    if let chunk = delta["signature"] as? String {
                        thinkingStates[index, default: ThinkingState(text: "", signature: "")].signature += chunk
                    }
                default:
                    continue
                }
            case "content_block_stop":
                let index = (obj["index"] as? Int) ?? 0
                if let state = toolStates.removeValue(forKey: index) {
                    let args = Self.decodeToolArguments(state.json)
                    continuation.yield(.toolCall(id: state.id, name: state.name, arguments: args))
                }
                if let think = thinkingStates.removeValue(forKey: index),
                   !think.signature.isEmpty {
                    // Text was already streamed via thinking_delta; this
                    // final delta just carries the signature so the VM
                    // can round-trip the block on the next turn.
                    continuation.yield(.reasoning(text: "", signature: think.signature))
                }
            case "message_stop":
                continuation.yield(.done)
                return
            default:
                continue
            }
        }
        continuation.yield(.done)
    }

    /// Decode an Anthropic `tool_use.input` JSON blob into `ToolArguments`.
    /// Empty / malformed blobs produce an empty argument set so the VM can
    /// still surface the tool call and let the tool raise a typed error.
    static func decodeToolArguments(_ json: String) -> ToolArguments {
        guard !json.isEmpty, let data = json.data(using: .utf8) else {
            return ToolArguments()
        }
        if let dict = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
            return ToolArguments(dict)
        }
        return ToolArguments()
    }

    // MARK: - Multi-turn request building

    static func makeMultiTurnRequest(
        apiKey: String,
        history: [ChatMessage],
        tools: ToolRegistry?,
        today: Date = Date()
    ) throws(ChatSessionError) -> URLRequest {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "stream": true,
            "system": [
                [
                    "type": "text",
                    "text": systemPromptBody,
                    "cache_control": ["type": "ephemeral"],
                ],
                [
                    "type": "text",
                    "text": "Today's date is \(todayDateFormatter.string(from: today)).",
                ],
            ],
            "messages": anthropicMessages(from: history),
        ]
        if let tools, !tools.all.isEmpty {
            let allTools = tools.all
            body["tools"] = allTools.enumerated().map { idx, tool in
                toolDefinitionDict(for: tool, cache: idx == allTools.count - 1)
            }
        }
        // Extended thinking is off by default; SettingsView's toggle
        // writes `chat.enableThinking`. Anthropic rejects the request
        // if the `thinking` key is present with type=disabled, so we
        // only add the key when enabled.
        if UserDefaults.standard.bool(forKey: "chat.enableThinking") {
            body["thinking"] = ["type": "enabled", "budget_tokens": 2048]
        }
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw .encoding
        }
        var req = URLRequest(url: apiEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue("prompt-caching-2024-07-31", forHTTPHeaderField: "anthropic-beta")
        req.httpBody = data
        return req
    }

    /// Render one `ChatTool` as the `[String: Any]` shape Anthropic's
    /// `tools` param expects. `input_schema` comes from encoding the
    /// `ToolInputSchema` (which is `Encodable`) through `JSONEncoder` +
    /// `JSONSerialization`.
    static func toolDefinitionDict(for tool: any ChatTool, cache: Bool = false) -> [String: Any] {
        var dict: [String: Any] = [
            "name": tool.name,
            "description": tool.description,
        ]
        if cache {
            dict["cache_control"] = ["type": "ephemeral"]
        }
        if let schemaData = try? JSONEncoder().encode(tool.inputSchema),
           let schemaAny = try? JSONSerialization.jsonObject(with: schemaData) {
            dict["input_schema"] = schemaAny
        } else {
            dict["input_schema"] = ["type": "object", "properties": [:], "required": []]
        }
        return dict
    }

    /// Collapse a flat `[ChatMessage]` history into Anthropic's turn-based
    /// messages array.
    ///
    /// Anthropic's contract for parallel tool use: a single `assistant`
    /// message carries N `tool_use` blocks, and the immediately following
    /// `user` message must carry exactly N `tool_result` blocks — one per
    /// `tool_use_id`, in the same order. Splitting them into separate
    /// messages (or dropping calls onto the assistant turn out of order)
    /// triggers HTTP 400 "unexpected tool_use_id in tool_result blocks".
    ///
    /// `ChatViewModel` appends tool messages interleaved (call, result,
    /// call, result, ...) because it executes each tool synchronously as
    /// it streams. This serializer re-groups them: for each assistant
    /// turn we greedily consume ALL following `.tool` messages regardless
    /// of `.call` / `.result` ordering, then emit one assistant turn with
    /// text + every `.call` block, followed by one user turn with every
    /// `.result` block. Empty in-progress assistant bubbles are dropped.
    static func anthropicMessages(from history: [ChatMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = []

        // Precompute: strip the trailing empty streaming assistant bubble
        // (ChatViewModel appends this before calling stream()). Also drop
        // system messages — Anthropic takes the system prompt top-level.
        // Keep an empty shell if it carries a reasoning block: we still
        // need to echo the thinking signature back on the round-trip.
        var working = history.filter { $0.role != .system }
        while let last = working.last,
              last.role == .assistant,
              last.text.isEmpty,
              last.toolEntry == nil,
              last.reasoning == nil {
            working.removeLast()
        }

        var i = 0
        while i < working.count {
            let msg = working[i]
            switch msg.role {
            case .user:
                if msg.attachments.isEmpty {
                    out.append(["role": "user", "content": msg.text])
                } else {
                    out.append(["role": "user", "content": userContentBlocks(for: msg)])
                }
                i += 1
            case .assistant:
                // Gather this assistant's text + ALL subsequent .tool
                // messages (both .call and .result, in any order) into
                // a single assistant turn (text + tool_use blocks) and
                // a single user turn (tool_result blocks).
                var toolUseBlocks: [[String: Any]] = []
                var toolResultBlocks: [[String: Any]] = []
                var j = i + 1
                while j < working.count, working[j].role == .tool {
                    switch working[j].toolEntry {
                    case let .call(id, name, arguments)?:
                        toolUseBlocks.append([
                            "type": "tool_use",
                            "id": id,
                            "name": name,
                            "input": foundationDict(from: arguments.values),
                        ])
                    case let .result(id, _, result)?:
                        toolResultBlocks.append([
                            "type": "tool_result",
                            "tool_use_id": id,
                            "content": result.content,
                            "is_error": result.isError,
                        ])
                    case .none:
                        break
                    }
                    j += 1
                }

                var assistantBlocks: [[String: Any]] = []
                // Thinking blocks must come FIRST in the assistant turn
                // per Anthropic's extended-thinking contract. They carry
                // an opaque signature the server uses to verify the CoT
                // hasn't been tampered with before the following tool_use.
                if let reasoning = msg.reasoning,
                   !reasoning.text.isEmpty, !reasoning.signature.isEmpty {
                    assistantBlocks.append([
                        "type": "thinking",
                        "thinking": reasoning.text,
                        "signature": reasoning.signature,
                    ])
                }
                if !msg.text.isEmpty {
                    assistantBlocks.append(["type": "text", "text": msg.text])
                }
                assistantBlocks.append(contentsOf: toolUseBlocks)

                if assistantBlocks.isEmpty {
                    // Purely structural turn — skip; Anthropic rejects empty.
                } else if assistantBlocks.count == 1,
                          let only = assistantBlocks.first,
                          (only["type"] as? String) == "text",
                          let text = only["text"] as? String {
                    out.append(["role": "assistant", "content": text])
                } else {
                    out.append(["role": "assistant", "content": assistantBlocks])
                }

                if !toolResultBlocks.isEmpty {
                    out.append(["role": "user", "content": toolResultBlocks])
                }

                i = j
            case .tool:
                // Orphan tool messages (no preceding assistant). This
                // happens on tool-loop iteration 2+: `ChatViewModel`
                // drops the empty assistant shell after .toolsRequested,
                // leaving the .call/.result pair anchorless. Synthesize
                // an assistant turn carrying the tool_use blocks and a
                // user turn carrying the matching tool_result blocks.
                var toolUseBlocks: [[String: Any]] = []
                var toolResultBlocks: [[String: Any]] = []
                var j = i
                while j < working.count, working[j].role == .tool {
                    switch working[j].toolEntry {
                    case let .call(id, name, arguments)?:
                        toolUseBlocks.append([
                            "type": "tool_use",
                            "id": id,
                            "name": name,
                            "input": foundationDict(from: arguments.values),
                        ])
                    case let .result(id, _, result)?:
                        toolResultBlocks.append([
                            "type": "tool_result",
                            "tool_use_id": id,
                            "content": result.content,
                            "is_error": result.isError,
                        ])
                    case .none:
                        break
                    }
                    j += 1
                }
                if !toolUseBlocks.isEmpty {
                    out.append(["role": "assistant", "content": toolUseBlocks])
                }
                if !toolResultBlocks.isEmpty {
                    out.append(["role": "user", "content": toolResultBlocks])
                }
                i = j
            case .system:
                i += 1
            }
        }
        return out
    }

    /// Build Anthropic content blocks for a user message that carries
    /// image attachments. Images go FIRST (Anthropic docs recommend
    /// image-before-text for better attention), in order, followed by
    /// exactly one `text` block. Empty message text falls back to a
    /// single space so the block is still well-formed. Never logs the
    /// attachment bytes — per `CLAUDE.md`, baby photos are sensitive.
    static func userContentBlocks(for msg: ChatMessage) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        for attachment in msg.attachments {
            blocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": attachment.mimeType,
                    "data": attachment.data.base64EncodedString(),
                ],
            ])
        }
        let text = msg.text.isEmpty ? " " : msg.text
        blocks.append(["type": "text", "text": text])
        return blocks
    }

    /// Convert a `[String: JSONValue]` into a Foundation-typed dict suitable
    /// for `JSONSerialization`. Used for `tool_use.input`.
    static func foundationDict(from values: [String: JSONValue]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in values {
            out[key] = foundationAny(from: value)
        }
        return out
    }

    static func foundationAny(from value: JSONValue) -> Any {
        switch value {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .null: return NSNull()
        case .array(let a): return a.map(foundationAny(from:))
        case .object(let o): return foundationDict(from: o)
        }
    }

    // MARK: - SSE consumption

    /// Iterates SSE lines from the raw byte stream, decodes each `data:`
    /// payload as JSON, and emits the appropriate `ChatDelta` for each
    /// event. Exposed `internal` for unit tests which feed synthetic
    /// byte streams.
    static func consumeSSE<Bytes: AsyncSequence & Sendable>(
        bytes: Bytes,
        continuation: AsyncThrowingStream<ChatDelta, Error>.Continuation
    ) async throws where Bytes.Element == UInt8 {
        var toolInputJSON = ""
        var toolName: String?
        var sawToolUse = false

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty || payload == "[DONE]" { continue }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String
            else { continue }

            switch type {
            case "content_block_start":
                if let block = obj["content_block"] as? [String: Any],
                   let blockType = block["type"] as? String,
                   blockType == "tool_use" {
                    sawToolUse = true
                    toolName = block["name"] as? String
                    toolInputJSON = ""
                }
            case "content_block_delta":
                guard let delta = obj["delta"] as? [String: Any],
                      let deltaType = delta["type"] as? String
                else { continue }
                switch deltaType {
                case "text_delta":
                    if let text = delta["text"] as? String, !text.isEmpty {
                        continuation.yield(.token(text))
                    }
                case "input_json_delta":
                    if let partial = delta["partial_json"] as? String {
                        toolInputJSON += partial
                    }
                default:
                    continue
                }
            case "message_stop":
                if sawToolUse, toolName == "log_baby_event" {
                    if let intent = Self.parseToolInput(toolInputJSON) {
                        continuation.yield(.intent(intent))
                    }
                }
                continuation.yield(.done)
                return
            default:
                continue
            }
        }
        // Stream ended without explicit `message_stop` — still emit `.done`.
        continuation.yield(.done)
    }

    // MARK: - Request building

    static let systemPromptBody = """
    In-app helper for baby Ethan Chua (born 2026-04-07). Users are \
    tired new parents. Be warm, brief, never preachy. Just act — \
    never introduce yourself or ask clarifying questions.

    After logging, quote the numbers from the tool result in 1-2 \
    warm sentences. Never fabricate numbers — only cite what \
    tool results actually contain. If a list query returns empty, \
    state it warmly and stop. If the user sounds tired or \
    frustrated, acknowledge in one short sentence.

    Job: 1) Log events by calling the right tool immediately with \
    sensible defaults. 2) Answer questions by calling list tools \
    first — never guess.

    Defaults (apply silently): omit loggedAt → stamps "now". \
    Diaper: poo/dirty → dirty, pee → wet. Ambiguous times → \
    sensible default (9am morning, 2pm afternoon). Never ask \
    follow-ups — a second question is a failure.

    Rules: never invent measurements. Short replies (1-2 sentences). \
    Grams ≤ 2000 g, kg above. ml for volumes. Never judge, never \
    lecture. Off-topic → gently redirect.
    """

    /// Formatter for the "Today's date is YYYY-MM-DD" line injected into
    /// every system prompt so the model can correctly resolve relative
    /// phrases like "this morning" or "yesterday".
    static let todayDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Builds the full system prompt including a date stamp for `today`.
    /// The date stamp is kept out of the cached body so the static prompt
    /// prefix remains cacheable while the short suffix changes daily.
    static func systemPrompt(today: Date) -> String {
        let stamp = todayDateFormatter.string(from: today)
        let tz = TimeZone.current
        let tzName = tz.localizedName(for: .shortGeneric, locale: .current) ?? tz.identifier
        let offsetSeconds = tz.secondsFromGMT()
        let sign = offsetSeconds >= 0 ? "+" : "-"
        let absOffset = abs(offsetSeconds)
        let tzOffset = String(format: "UTC%@%02d:%02d", sign, absOffset / 3600, (absOffset % 3600) / 60)
        return systemPromptBody + "\n\nToday's date is \(stamp). " +
            "User's timezone is \(tzName) (\(tzOffset)). " +
            "All timestamps in tool calls must be in the user's local time without a Z or timezone suffix (e.g. 2026-04-19T14:30:00, not 2026-04-19T06:30:00Z)."
    }

    static func makeRequest(apiKey: String, userText: String, today: Date = Date()) throws(ChatSessionError) -> URLRequest {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "stream": true,
            "system": [
                [
                    "type": "text",
                    "text": systemPromptBody,
                    "cache_control": ["type": "ephemeral"],
                ],
                [
                    "type": "text",
                    "text": "Today's date is \(todayDateFormatter.string(from: today)).",
                ],
            ],
            "tools": [toolDefinition()],
            "messages": [
                ["role": "user", "content": userText],
            ],
        ]
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw .encoding
        }
        var req = URLRequest(url: apiEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue("prompt-caching-2024-07-31", forHTTPHeaderField: "anthropic-beta")
        req.httpBody = data
        return req
    }

    static func toolDefinition() -> [String: Any] {
        return [
            "name": "log_baby_event",
            "description": "Log a baby event (feed, diaper, growth, appointment, or milestone) described by the user.",
            "cache_control": ["type": "ephemeral"],
            "input_schema": [
                "type": "object",
                "properties": [
                    "kind": [
                        "type": "string",
                        "enum": ["feed", "diaper", "growth", "appointment", "milestone", "unknown"],
                    ],
                    "volume_ml": ["type": "integer"],
                    "diaper_type": ["type": "string", "enum": ["wet", "dirty", "both"]],
                    "weight_grams": ["type": "integer"],
                    "height_cm": ["type": "number"],
                    "head_circumference_cm": ["type": "number"],
                    "title": ["type": "string"],
                    "location": ["type": "string"],
                    "logged_at": ["type": "string", "description": "ISO8601 timestamp"],
                    "notes": ["type": "string"],
                    "reason": ["type": "string"],
                ],
                "required": ["kind"],
            ],
        ]
    }

    // MARK: - Tool-use parsing

    /// Parses an assembled `log_baby_event` JSON blob into a `ToolUse`.
    /// Returns `nil` if the JSON is empty or structurally unusable — the
    /// caller then simply omits the `.intent` delta.
    static func parseToolInput(_ json: String) -> ToolUse? {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let iso = ISO8601DateFormatter()
        let kind = (input["kind"] as? String) ?? "unknown"
        switch kind {
        case "feed":
            return .feed(FeedDraft(
                volumeMl: input["volume_ml"] as? Int,
                loggedAt: (input["logged_at"] as? String).flatMap { iso.date(from: $0) },
                source: nil,
                notes: input["notes"] as? String
            ))
        case "diaper":
            let type: DiaperType? = (input["diaper_type"] as? String).flatMap { DiaperType(rawValue: $0) }
            return .diaper(DiaperDraft(
                type: type,
                loggedAt: (input["logged_at"] as? String).flatMap { iso.date(from: $0) },
                notes: input["notes"] as? String
            ))
        case "growth":
            let height = (input["height_cm"] as? Double) ?? (input["height_cm"] as? Int).map(Double.init)
            let head = (input["head_circumference_cm"] as? Double) ?? (input["head_circumference_cm"] as? Int).map(Double.init)
            return .growth(GrowthDraft(
                date: (input["logged_at"] as? String).flatMap { iso.date(from: $0) },
                weightGrams: input["weight_grams"] as? Int,
                heightCm: height,
                headCircumferenceCm: head,
                notes: input["notes"] as? String
            ))
        case "appointment":
            return .appointment(AppointmentDraft(
                title: input["title"] as? String,
                scheduledAt: (input["logged_at"] as? String).flatMap { iso.date(from: $0) },
                location: input["location"] as? String,
                notes: input["notes"] as? String
            ))
        case "milestone":
            return .milestone(MilestoneDraft(
                title: input["title"] as? String,
                achievedAt: (input["logged_at"] as? String).flatMap { iso.date(from: $0) },
                notes: input["notes"] as? String
            ))
        default:
            return .unknown(reason: input["reason"] as? String ?? "unknown")
        }
    }
}

// MARK: - Errors

/// Typed error surface for `ClaudeChatSession`. Distinct from
/// `AssistantError` because the chat session has its own cancellation
/// and streaming semantics — keeping them separate avoids accidental
/// cross-wiring of retry logic.
enum ChatSessionError: Error, Equatable, Sendable, CustomStringConvertible {
    case apiKeyMissing
    case network
    case timeout
    case rateLimited
    case unauthenticated
    case encoding
    /// Non-2xx HTTP response from the Anthropic API. `message` is the
    /// decoded `error.message` field of Anthropic's error envelope, or a
    /// truncated raw body if decoding failed. Surfaced verbatim to the
    /// chat UI (`ChatTabView` appends it to "The assistant stopped
    /// mid-reply:") so it must be human-readable.
    case invalidResponse(status: Int, message: String)

    var description: String {
        switch self {
        case .apiKeyMissing: return "apiKeyMissing"
        case .network: return "network"
        case .timeout: return "timeout"
        case .rateLimited: return "rateLimited"
        case .unauthenticated: return "unauthenticated"
        case .encoding: return "encoding"
        case let .invalidResponse(status, message):
            return "HTTP \(status): \(message)"
        }
    }
}

extension ClaudeChatSession {
    /// Read the error body from an Anthropic non-2xx response. Tries to
    /// decode Anthropic's `{"error": {"type": ..., "message": ...}}`
    /// envelope; on failure, falls back to the raw body string truncated
    /// to 500 characters so an unexpected HTML error page can't blow up
    /// the thrown error label.
    static func decodeErrorBody<Bytes: AsyncSequence & Sendable>(
        bytes: Bytes
    ) async -> String where Bytes.Element == UInt8 {
        var data = Data()
        data.reserveCapacity(1024)
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > 8192 { break }
            }
        } catch {
            // If the stream errors mid-read, fall through with whatever
            // we managed to collect.
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any],
           let message = err["message"] as? String {
            return message
        }
        let raw = String(data: data, encoding: .utf8) ?? ""
        if raw.count > 500 {
            return String(raw.prefix(500)) + "…"
        }
        return raw.isEmpty ? "(empty body)" : raw
    }
}
