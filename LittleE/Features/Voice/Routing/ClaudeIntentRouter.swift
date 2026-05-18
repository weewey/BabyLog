import Foundation
import LittleECore

/// `LittleEAssistant` impl that calls Claude Haiku 4.5 with tool-use to parse a
/// transcript into a `ToolUse`. Talks to the Anthropic Messages API
/// directly via `URLSession` (no SDK dependency — keeps the dep tree clean).
///
/// Caching: the system prompt and tool definitions are static and marked
/// `cache_control: ephemeral` so every call after the first hits the cache.
/// Retries: max 2 retries with exponential backoff on transient 5xx / 429.
///
/// Modelled as an `actor` so it satisfies `Sendable` naturally — no more
/// `@unchecked`. The reviewer flagged the old `@unchecked Sendable` as a
/// foot-gun; actors make the concurrency story explicit.
actor ClaudeAssistant: LittleEAssistant {

    static let model = "claude-haiku-4-5-20251001"
    static let apiVersion = "2023-06-01"

    /// Compile-time-constant endpoint URL. `fatalError` is genuinely
    /// unreachable here: the literal is validated at app launch, and if the
    /// string ever becomes malformed it is a programmer bug the test suite
    /// will catch long before it ships. CLAUDE.md explicitly allows
    /// `fatalError` for "unreachable invariants".
    static let apiEndpoint: URL = {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            fatalError("invalid Anthropic endpoint literal — unreachable")
        }
        return url
    }()

    private let session: URLSession
    private let apiKeyProvider: @Sendable () -> String?
    private let maxRetries: Int

    init(
        session: URLSession = .shared,
        apiKeyProvider: @escaping @Sendable () -> String? = { ClaudeAPIKeyStore.load() },
        maxRetries: Int = 2
    ) {
        self.session = session
        self.apiKeyProvider = apiKeyProvider
        self.maxRetries = maxRetries
    }

    func respond(to transcript: String) async throws(AssistantError) -> AssistantResponse {
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            throw .apiKeyMissing
        }
        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: Self.requestBody(transcript: transcript))
        } catch {
            throw .decoding
        }

        var attempt = 0
        var lastError: AssistantError = .network
        while attempt <= maxRetries {
            do {
                let (responseData, response) = try await performRequest(data: body, apiKey: apiKey)
                guard let http = response as? HTTPURLResponse else {
                    throw AssistantError.invalidResponse
                }
                switch http.statusCode {
                case 200:
                    return try Self.parse(responseData)
                case 401, 403:
                    throw AssistantError.unauthenticated
                case 429:
                    lastError = .rateLimited
                case 500...599:
                    lastError = .network
                default:
                    throw AssistantError.invalidResponse
                }
            } catch let error as AssistantError {
                // Non-retryable errors short-circuit the loop.
                switch error {
                case .unauthenticated, .invalidResponse, .decoding, .apiKeyMissing:
                    throw error
                case .network, .rateLimited, .timeout, .unknown:
                    lastError = error
                }
            } catch let urlError as URLError where urlError.code == .timedOut {
                lastError = .timeout
            } catch {
                lastError = .network
            }
            attempt += 1
            if attempt <= maxRetries {
                let backoffNs = UInt64(pow(2.0, Double(attempt)) * 200_000_000) // 0.4s, 0.8s
                try? await Task.sleep(nanoseconds: backoffNs)
            }
        }
        throw lastError
    }

    private func performRequest(data: Data, apiKey: String) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: Self.apiEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue("prompt-caching-2024-07-31", forHTTPHeaderField: "anthropic-beta")
        req.httpBody = data
        return try await session.data(for: req)
    }

    // MARK: - Request body construction

    static let systemPrompt = """
    You are LittleE, a helpful assistant for two parents tracking their baby Ethan. \
    The user will speak or type a short message — sometimes they want to log an \
    event, sometimes they are asking a question or just chatting. Respond in the \
    way that is most useful for that turn: \
    • If the user is reporting something to log, call one of the tools to record \
    it — `log_feed` (bottle/breast, volume in ml, time), `log_diaper` \
    (wet/dirty/both), `log_growth` (weight in grams, height in cm, head \
    circumference in cm), `log_appointment`, or `log_milestone`. You may also \
    write a brief natural-language confirmation alongside the tool call. \
    • If the user is asking a question or chatting, reply directly with a short \
    helpful answer and do not call any tool. \
    Extract only what the user actually said when filling in tool slots — never \
    invent volumes, times, or other values. Keep replies concise: one or two \
    sentences, no preamble.
    """

    static func requestBody(transcript: String) -> [String: Any] {
        return [
            "model": model,
            "max_tokens": 512,
            "system": [
                [
                    "type": "text",
                    "text": systemPrompt,
                    "cache_control": ["type": "ephemeral"],
                ],
            ],
            "tools": toolDefinitionsCached(),
            "messages": [
                ["role": "user", "content": transcript],
            ],
        ]
    }

    static func toolDefinitionsCached() -> [[String: Any]] {
        var tools = toolDefinitions()
        // Mark only the LAST tool with cache_control — caches the whole tools block.
        if !tools.isEmpty {
            tools[tools.count - 1]["cache_control"] = ["type": "ephemeral"]
        }
        return tools
    }

    static func toolDefinitions() -> [[String: Any]] {
        return [
            [
                "name": "log_feed",
                "description": "Log a baby feeding (bottle or breast).",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "volume_ml": ["type": "integer", "description": "Volume in ml (1-500)"],
                        "source": ["type": "string", "enum": ["bottle", "breast"]],
                        "logged_at": ["type": "string", "description": "ISO8601 timestamp; omit if not stated"],
                        "notes": ["type": "string"],
                    ],
                ],
            ],
            [
                "name": "log_diaper",
                "description": "Log a diaper change.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "type": ["type": "string", "enum": ["wet", "dirty", "both"]],
                        "logged_at": ["type": "string"],
                        "notes": ["type": "string"],
                    ],
                ],
            ],
            [
                "name": "log_growth",
                "description": "Log a growth measurement.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "weight_grams": ["type": "integer"],
                        "height_cm": ["type": "number"],
                        "head_circumference_cm": ["type": "number"],
                        "date": ["type": "string"],
                        "notes": ["type": "string"],
                    ],
                ],
            ],
            [
                "name": "log_appointment",
                "description": "Log a medical appointment.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "scheduled_at": ["type": "string"],
                        "location": ["type": "string"],
                        "notes": ["type": "string"],
                    ],
                ],
            ],
            [
                "name": "log_milestone",
                "description": "Log a developmental milestone.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "achieved_at": ["type": "string"],
                        "notes": ["type": "string"],
                    ],
                ],
            ],
            [
                "name": "unknown",
                "description": "Could not determine the user's intent.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "reason": ["type": "string"],
                    ],
                    "required": ["reason"],
                ],
            ],
        ]
    }

    // MARK: - Response parsing

    static func parse(_ data: Data) throws(AssistantError) -> AssistantResponse {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw .decoding }

        // Surface explicit API error responses distinctly from shape errors.
        if let errorBlock = json["error"] as? [String: Any],
           let type = errorBlock["type"] as? String {
            switch type {
            case "rate_limit_error": throw .rateLimited
            case "authentication_error", "permission_error": throw .unauthenticated
            default: throw .invalidResponse
            }
        }

        guard let content = json["content"] as? [[String: Any]] else {
            throw .decoding
        }

        var answerParts: [String] = []
        var toolUses: [ToolUse] = []
        for block in content {
            guard let type = block["type"] as? String else { continue }
            switch type {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    answerParts.append(text)
                }
            case "tool_use":
                let name = block["name"] as? String ?? ""
                let input = block["input"] as? [String: Any] ?? [:]
                toolUses.append(parseTool(name: name, input: input))
            default:
                continue
            }
        }

        // A turn with neither text nor a tool call is a shape error — the
        // model should always produce at least one meaningful content block.
        guard !answerParts.isEmpty || !toolUses.isEmpty else {
            throw .invalidResponse
        }

        return AssistantResponse(
            answer: answerParts.joined(separator: "\n"),
            toolUses: toolUses
        )
    }

    static func parseTool(name: String, input: [String: Any]) -> ToolUse {
        let iso = ISO8601DateFormatter()
        switch name {
        case "log_feed":
            let source: FeedSource? = {
                guard let s = input["source"] as? String else { return nil }
                return s == "breast" ? .breast : .bottle
            }()
            return .feed(FeedDraft(
                volumeMl: input["volume_ml"] as? Int,
                loggedAt: (input["logged_at"] as? String).flatMap { iso.date(from: $0) },
                source: source,
                notes: input["notes"] as? String
            ))
        case "log_diaper":
            let type: DiaperType? = (input["type"] as? String).flatMap { DiaperType(rawValue: $0) }
            return .diaper(DiaperDraft(
                type: type,
                loggedAt: (input["logged_at"] as? String).flatMap { iso.date(from: $0) },
                notes: input["notes"] as? String
            ))
        case "log_growth":
            let height = (input["height_cm"] as? Double) ?? (input["height_cm"] as? Int).map(Double.init)
            let head = (input["head_circumference_cm"] as? Double) ?? (input["head_circumference_cm"] as? Int).map(Double.init)
            return .growth(GrowthDraft(
                date: (input["date"] as? String).flatMap { iso.date(from: $0) },
                weightGrams: input["weight_grams"] as? Int,
                heightCm: height,
                headCircumferenceCm: head,
                notes: input["notes"] as? String
            ))
        case "log_appointment":
            return .appointment(AppointmentDraft(
                title: input["title"] as? String,
                scheduledAt: (input["scheduled_at"] as? String).flatMap { iso.date(from: $0) },
                location: input["location"] as? String,
                notes: input["notes"] as? String
            ))
        case "log_milestone":
            return .milestone(MilestoneDraft(
                title: input["title"] as? String,
                achievedAt: (input["achieved_at"] as? String).flatMap { iso.date(from: $0) },
                notes: input["notes"] as? String
            ))
        case "unknown":
            return .unknown(reason: input["reason"] as? String ?? "unknown")
        default:
            return .unknown(reason: "unrecognised tool: \(name)")
        }
    }
}
