import XCTest
import LittleECore
@testable import LittleE

/// Unit tests for `ClaudeChatSession`. No real network: every test either
/// feeds a canned SSE byte stream directly to `consumeSSE`, or installs a
/// `MockSSEURLProtocol` that replays a scripted body on the injected
/// `URLSession.bytes(for:)` call.
final class ClaudeChatSessionTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        MockSSEURLProtocol.reset()
    }

    // MARK: - SSE parsing

    func test_consumeSSE_emitsTokensThenIntentThenDone() async throws {
        let sse = """
        event: message_start
        data: {"type":"message_start"}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" Ethan"}}

        event: content_block_start
        data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tu_1","name":"log_baby_event","input":{}}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"kind\\":\\"feed\\","}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\\"volume_ml\\":120,\\"source\\":\\"bottle\\"}"}}

        event: message_stop
        data: {"type":"message_stop"}

        """

        let deltas = try await collectDeltas(sse: sse)

        XCTAssertEqual(deltas.count, 4, "expected 2 tokens + intent + done, got \(deltas)")
        XCTAssertEqual(deltas[0], .token("Hello"))
        XCTAssertEqual(deltas[1], .token(" Ethan"))
        XCTAssertEqual(deltas[2], .intent(.feed(FeedDraft(volumeMl: 120, source: nil))))
        XCTAssertEqual(deltas[3], .done)
    }

    func test_consumeSSE_textOnly_emitsTokensThenDone() async throws {
        let sse = """
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}

        data: {"type":"message_stop"}

        """

        let deltas = try await collectDeltas(sse: sse)

        XCTAssertEqual(deltas, [.token("Hi"), .done])
    }

    // MARK: - Tool input round-trip

    func test_parseToolInput_feed_roundTrip() {
        let intent = ClaudeChatSession.parseToolInput(#"{"kind":"feed","volume_ml":90}"#)
        XCTAssertEqual(intent, .feed(FeedDraft(volumeMl: 90, source: nil)))
    }

    func test_parseToolInput_diaper_roundTrip() {
        let intent = ClaudeChatSession.parseToolInput(#"{"kind":"diaper","diaper_type":"both"}"#)
        XCTAssertEqual(intent, .diaper(DiaperDraft(type: .both)))
    }

    func test_parseToolInput_growth_roundTrip() {
        let intent = ClaudeChatSession.parseToolInput(
            #"{"kind":"growth","weight_grams":4200,"height_cm":55.5}"#
        )
        XCTAssertEqual(
            intent,
            .growth(GrowthDraft(weightGrams: 4200, heightCm: 55.5))
        )
    }

    func test_parseToolInput_appointment_roundTrip() {
        let intent = ClaudeChatSession.parseToolInput(
            #"{"kind":"appointment","title":"Pediatrician","location":"Clinic"}"#
        )
        XCTAssertEqual(
            intent,
            .appointment(AppointmentDraft(title: "Pediatrician", location: "Clinic"))
        )
    }

    func test_parseToolInput_milestone_roundTrip() {
        let intent = ClaudeChatSession.parseToolInput(
            #"{"kind":"milestone","title":"First smile"}"#
        )
        XCTAssertEqual(intent, .milestone(MilestoneDraft(title: "First smile")))
    }

    func test_parseToolInput_unknown_returnsReason() {
        let intent = ClaudeChatSession.parseToolInput(#"{"kind":"unknown","reason":"ambiguous"}"#)
        XCTAssertEqual(intent, .unknown(reason: "ambiguous"))
    }

    func test_parseToolInput_empty_returnsNil() {
        XCTAssertNil(ClaudeChatSession.parseToolInput(""))
    }

    // MARK: - System prompt date injection

    func test_makeRequest_systemPrompt_containsTodaysDate() throws {
        var components = DateComponents()
        components.year = 2026
        components.month = 4
        components.day = 13
        components.hour = 9
        let fixedDate = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: components))

        let request = try ClaudeChatSession.makeRequest(
            apiKey: "test-key",
            userText: "at 8am this morning I fed him 120ml",
            today: fixedDate
        )

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let system = try XCTUnwrap(json["system"] as? [[String: Any]])
        let joined = system.compactMap { $0["text"] as? String }.joined(separator: "\n")
        XCTAssertTrue(joined.contains("Today's date is 2026-04-13."), "system prompt missing date stamp: \(joined)")
    }

    func test_makeMultiTurnRequest_systemPrompt_containsTodaysDate() throws {
        var components = DateComponents()
        components.year = 2026
        components.month = 4
        components.day = 13
        let fixedDate = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: components))

        let request = try ClaudeChatSession.makeMultiTurnRequest(
            apiKey: "test-key",
            history: [ChatMessage(role: .user, text: "hi")],
            tools: nil,
            today: fixedDate
        )

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let system = try XCTUnwrap(json["system"] as? [[String: Any]])
        let joined = system.compactMap { $0["text"] as? String }.joined(separator: "\n")
        XCTAssertTrue(joined.contains("Today's date is 2026-04-13."), "system prompt missing date stamp: \(joined)")
    }

    // MARK: - API key missing

    func test_stream_missingApiKey_throwsApiKeyMissing() async {
        let session = ClaudeChatSession(
            opener: { _ in
                XCTFail("opener should not be invoked when key is missing")
                throw ChatSessionError.network
            },
            apiKeyProvider: { nil }
        )

        do {
            for try await _ in session.stream("hi") {}
            XCTFail("expected throw")
        } catch let error as ChatSessionError {
            XCTAssertEqual(error, .apiKeyMissing)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - HTTP error mapping (via MockSSEURLProtocol)

    func test_stream_http401_throwsUnauthenticated() async {
        MockSSEURLProtocol.stub(status: 401, body: "")
        let session = makeSessionWithMockProtocol()

        do {
            for try await _ in session.stream("hi") {}
            XCTFail("expected throw")
        } catch let error as ChatSessionError {
            XCTAssertEqual(error, .unauthenticated)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_stream_http429_throwsRateLimited() async {
        MockSSEURLProtocol.stub(status: 429, body: "")
        let session = makeSessionWithMockProtocol()

        do {
            for try await _ in session.stream("hi") {}
            XCTFail("expected throw")
        } catch let error as ChatSessionError {
            XCTAssertEqual(error, .rateLimited)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_stream_http400_surfacesAnthropicErrorMessage() async {
        let body = #"{"type":"error","error":{"type":"invalid_request_error","message":"messages.3: all messages must have non-empty content"}}"#
        MockSSEURLProtocol.stub(status: 400, body: body)
        let session = makeSessionWithMockProtocol()

        do {
            for try await _ in session.stream("hi") {}
            XCTFail("expected throw")
        } catch let error as ChatSessionError {
            guard case let .invalidResponse(status, message) = error else {
                XCTFail("expected invalidResponse, got \(error)")
                return
            }
            XCTAssertEqual(status, 400)
            XCTAssertTrue(
                message.contains("all messages must have non-empty content"),
                "error message did not contain Anthropic envelope text: \(message)"
            )
            XCTAssertTrue(
                String(describing: error).contains("all messages must have non-empty content"),
                "String(describing:) should surface body: \(String(describing: error))"
            )
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_stream_http500_fallsBackToRawBodyWhenNotAnthropicEnvelope() async {
        MockSSEURLProtocol.stub(status: 500, body: "upstream exploded")
        let session = makeSessionWithMockProtocol()

        do {
            for try await _ in session.stream("hi") {}
            XCTFail("expected throw")
        } catch let error as ChatSessionError {
            guard case let .invalidResponse(status, message) = error else {
                XCTFail("expected invalidResponse, got \(error)")
                return
            }
            XCTAssertEqual(status, 500)
            XCTAssertTrue(message.contains("upstream exploded"), "raw body missing: \(message)")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Parallel tool-use serialization

    /// Reproduces the HTTP 400 "unexpected tool_use_id" bug: when a single
    /// assistant turn emits multiple `tool_use` blocks, the follow-up
    /// request must bundle ALL corresponding `tool_result` blocks into a
    /// single `user` message whose `content` array contains one
    /// `tool_result` per `tool_use`, in order. Splitting them into
    /// multiple user messages (or dropping the non-first calls into the
    /// assistant turn) crashes Anthropic's validator.
    func test_anthropicMessages_bundlesParallelToolResultsIntoOneUserMessage() throws {
        // Arrange: reconstruct the ChatViewModel history shape for a user
        // message that triggers 3 parallel tool calls. The VM interleaves
        // .call / .result per tool, but the serializer must re-group.
        let callA = ChatMessage.ToolEntry.call(
            id: "tu_a", name: "createFeedLog", arguments: ToolArguments(["volume_ml": .int(150)])
        )
        let resultA = ChatMessage.ToolEntry.result(
            id: "tu_a", name: "createFeedLog", result: ToolResult(content: "ok id=1")
        )
        let callB = ChatMessage.ToolEntry.call(
            id: "tu_b", name: "createDiaperLog", arguments: ToolArguments(["type": .string("dirty")])
        )
        let resultB = ChatMessage.ToolEntry.result(
            id: "tu_b", name: "createDiaperLog", result: ToolResult(content: "ok id=2")
        )
        let callC = ChatMessage.ToolEntry.call(
            id: "tu_c", name: "createGrowthMeasurement", arguments: ToolArguments(["weight_grams": .int(5200)])
        )
        let resultC = ChatMessage.ToolEntry.result(
            id: "tu_c", name: "createGrowthMeasurement", result: ToolResult(content: "ok id=3")
        )

        let history: [ChatMessage] = [
            ChatMessage(role: .user, text: "Log a 150ml bottle feed, a dirty diaper, and Ethan weighing 5200 grams"),
            ChatMessage(role: .assistant, text: "Sure, logging those now."),
            ChatMessage(role: .tool, toolEntry: callA),
            ChatMessage(role: .tool, toolEntry: resultA),
            ChatMessage(role: .tool, toolEntry: callB),
            ChatMessage(role: .tool, toolEntry: resultB),
            ChatMessage(role: .tool, toolEntry: callC),
            ChatMessage(role: .tool, toolEntry: resultC),
        ]

        // Act
        let messages = ClaudeChatSession.anthropicMessages(from: history)

        // Assert: expect [user, assistant(text + 3 tool_use), user(3 tool_result)]
        XCTAssertEqual(messages.count, 3, "expected 3 top-level messages, got \(messages.count): \(messages)")

        // First message: the user prompt.
        XCTAssertEqual(messages[0]["role"] as? String, "user")

        // Second message: assistant turn with text + ALL 3 tool_use blocks.
        XCTAssertEqual(messages[1]["role"] as? String, "assistant")
        let assistantBlocks = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        let toolUseBlocks = assistantBlocks.filter { ($0["type"] as? String) == "tool_use" }
        XCTAssertEqual(toolUseBlocks.count, 3, "assistant turn must carry all 3 tool_use blocks")
        XCTAssertEqual(toolUseBlocks.map { $0["id"] as? String }, ["tu_a", "tu_b", "tu_c"])

        // Third message: one user turn, 3 tool_result blocks, matching ids in order.
        XCTAssertEqual(messages[2]["role"] as? String, "user")
        let resultBlocks = try XCTUnwrap(messages[2]["content"] as? [[String: Any]])
        XCTAssertEqual(resultBlocks.count, 3, "user follow-up must bundle all 3 tool_result blocks")
        XCTAssertEqual(resultBlocks.map { $0["type"] as? String }, ["tool_result", "tool_result", "tool_result"])
        XCTAssertEqual(resultBlocks.map { $0["tool_use_id"] as? String }, ["tu_a", "tu_b", "tu_c"])
    }

    // MARK: - Image attachments

    func test_claudeChatSession_supportsImageInput_isTrue() {
        let session = ClaudeChatSession(
            opener: { _ in throw ChatSessionError.network },
            apiKeyProvider: { "k" }
        )

        XCTAssertTrue(session.supportsImageInput)
    }

    func test_anthropicMessages_noAttachments_stillUsesStringContent() throws {
        let history: [ChatMessage] = [ChatMessage(role: .user, text: "hi")]

        let messages = ClaudeChatSession.anthropicMessages(from: history)

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[0]["content"] as? String, "hi")
    }

    func test_anthropicMessages_withSingleJpegAttachment_producesImageBlockThenTextBlock() throws {
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let attachment = try ChatAttachment(
            mimeType: "image/jpeg",
            data: bytes,
            widthPx: 100,
            heightPx: 200
        )
        let history: [ChatMessage] = [
            ChatMessage(role: .user, text: "what is this?", attachments: [attachment])
        ]

        let messages = ClaudeChatSession.anthropicMessages(from: history)

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        let blocks = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0]["type"] as? String, "image")
        let source = try XCTUnwrap(blocks[0]["source"] as? [String: Any])
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/jpeg")
        XCTAssertEqual(source["data"] as? String, bytes.base64EncodedString())
        XCTAssertEqual(blocks[1]["type"] as? String, "text")
        XCTAssertEqual(blocks[1]["text"] as? String, "what is this?")
    }

    func test_anthropicMessages_withEmptyMsgTextAndAttachment_fallsBackToSingleSpace() throws {
        let attachment = try ChatAttachment(
            mimeType: "image/png",
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            widthPx: 1,
            heightPx: 1
        )
        let history: [ChatMessage] = [
            ChatMessage(role: .user, text: "", attachments: [attachment])
        ]

        let messages = ClaudeChatSession.anthropicMessages(from: history)

        let blocks = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0]["type"] as? String, "image")
        XCTAssertEqual(blocks[1]["type"] as? String, "text")
        XCTAssertEqual(blocks[1]["text"] as? String, " ")
    }

    func test_anthropicMessages_withTwoAttachments_preservesOrder() throws {
        let first = try ChatAttachment(
            mimeType: "image/jpeg",
            data: Data([0x01]),
            widthPx: 10,
            heightPx: 10
        )
        let second = try ChatAttachment(
            mimeType: "image/webp",
            data: Data([0x02]),
            widthPx: 20,
            heightPx: 20
        )
        let history: [ChatMessage] = [
            ChatMessage(role: .user, text: "compare", attachments: [first, second])
        ]

        let messages = ClaudeChatSession.anthropicMessages(from: history)

        let blocks = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.count, 3)
        let firstSource = try XCTUnwrap(blocks[0]["source"] as? [String: Any])
        let secondSource = try XCTUnwrap(blocks[1]["source"] as? [String: Any])
        XCTAssertEqual(firstSource["media_type"] as? String, "image/jpeg")
        XCTAssertEqual(firstSource["data"] as? String, Data([0x01]).base64EncodedString())
        XCTAssertEqual(secondSource["media_type"] as? String, "image/webp")
        XCTAssertEqual(secondSource["data"] as? String, Data([0x02]).base64EncodedString())
        XCTAssertEqual(blocks[2]["type"] as? String, "text")
        XCTAssertEqual(blocks[2]["text"] as? String, "compare")
    }

    // MARK: - Cancellation

    func test_cancel_midStream_finishesCleanly() async throws {
        // Opener blocks forever until the task is cancelled.
        let session = ClaudeChatSession(
            opener: { _ in
                try await Task.sleep(for: .seconds(60))
                throw ChatSessionError.network
            },
            apiKeyProvider: { "test-key" }
        )

        let stream = session.stream("hi")
        let iterationTask = Task<Int, Error> {
            var count = 0
            for try await _ in stream { count += 1 }
            return count
        }

        // Let the task reach the blocking opener.
        try await Task.sleep(for: .milliseconds(20))
        session.cancel()

        let count = try await iterationTask.value
        XCTAssertEqual(count, 0)
    }

    // MARK: - Extended thinking / reasoning

    func test_consumeMultiTurnSSE_emitsReasoningDelta_fromThinkingBlock() async throws {
        let sse = """
        data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"User wants"}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":" a feed log."}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig-"}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"opaque"}}

        data: {"type":"content_block_stop","index":0}

        data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

        data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Done."}}

        data: {"type":"content_block_stop","index":1}

        data: {"type":"message_stop"}

        """
        let deltas = try await collectMultiTurnDeltas(sse: sse)

        // Streaming: each thinking_delta emits its own .reasoning
        // chunk (text-only); content_block_stop emits a final
        // signature-only delta; text block + done follow.
        let reasoning: [(String, String)] = deltas.compactMap {
            if case let .reasoning(t, s) = $0 { return (t, s) } else { return nil }
        }
        XCTAssertEqual(reasoning.map(\.0).joined(), "User wants a feed log.")
        XCTAssertEqual(reasoning.map(\.1).joined(), "sig-opaque")
        XCTAssertTrue(deltas.contains(.token("Done.")))
        XCTAssertEqual(deltas.last, .done)
    }

    private func collectMultiTurnDeltas(sse: String) async throws -> [ChatDelta] {
        let stream = AsyncThrowingStream<ChatDelta, Error> { continuation in
            let task = Task {
                do {
                    try await ClaudeChatSession.consumeMultiTurnSSE(
                        bytes: ByteSequence(data: Data(sse.utf8)),
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        var out: [ChatDelta] = []
        for try await delta in stream { out.append(delta) }
        return out
    }

    // MARK: - Helpers

    private func collectDeltas(sse: String) async throws -> [ChatDelta] {
        let stream = AsyncThrowingStream<ChatDelta, Error> { continuation in
            let task = Task {
                do {
                    try await ClaudeChatSession.consumeSSE(
                        bytes: ByteSequence(data: Data(sse.utf8)),
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }

        var out: [ChatDelta] = []
        for try await delta in stream { out.append(delta) }
        return out
    }

    private func makeSessionWithMockProtocol() -> ClaudeChatSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockSSEURLProtocol.self]
        let urlSession = URLSession(configuration: config)
        return ClaudeChatSession(
            opener: { request in try await urlSession.bytes(for: request) },
            apiKeyProvider: { "test-key" }
        )
    }
}

// MARK: - Byte sequence fixture

/// Minimal `AsyncSequence<UInt8>` that replays a `Data` blob. Used so
/// `consumeSSE` can be tested without a live URLSession.
struct ByteSequence: AsyncSequence, Sendable {
    typealias Element = UInt8
    let data: Data

    func makeAsyncIterator() -> Iterator { Iterator(data: data) }

    struct Iterator: AsyncIteratorProtocol {
        var data: Data
        var index: Int = 0
        mutating func next() async throws -> UInt8? {
            guard index < data.count else { return nil }
            defer { index += 1 }
            return data[index]
        }
    }
}

// MARK: - URLProtocol mock for SSE

final class MockSSEURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var stubStatus: Int = 200
    nonisolated(unsafe) private static var stubBody: String = ""
    private static let lock = NSLock()

    static func stub(status: Int, body: String) {
        lock.lock(); defer { lock.unlock() }
        stubStatus = status
        stubBody = body
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        stubStatus = 200
        stubBody = ""
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let status = Self.stubStatus
        let body = Self.stubBody
        Self.lock.unlock()

        let url = request.url ?? URL(string: "https://example.invalid") ?? URL(fileURLWithPath: "/")
        if let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        ) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
