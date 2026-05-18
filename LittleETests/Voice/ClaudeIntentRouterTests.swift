import XCTest
import LittleECore
@testable import LittleE

/// End-to-end tests for `ClaudeAssistant.respond(to:)` using a
/// `URLProtocol` mock. No real network — every response is scripted in the
/// test so the suite stays hermetic and sub-second.
final class ClaudeAssistantTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        MockURLProtocol.reset()
    }

    // MARK: - Happy paths

    func test_route_feedToolUse_returnsFeedDraft() async throws {
        let json = """
        {
          "content": [
            { "type": "tool_use", "name": "log_feed",
              "input": { "volume_ml": 120, "source": "bottle" } }
          ]
        }
        """
        MockURLProtocol.stub(status: 200, body: json)
        let router = makeRouter()

        let response = try await router.respond(to: "fed 120ml")

        XCTAssertEqual(response, .toolUse(.feed(FeedDraft(volumeMl: 120, source: .bottle))))
    }

    func test_route_diaperToolUse_returnsDiaperDraft() async throws {
        let json = """
        { "content": [ { "type": "tool_use", "name": "log_diaper",
                         "input": { "type": "dirty" } } ] }
        """
        MockURLProtocol.stub(status: 200, body: json)
        let router = makeRouter()

        let response = try await router.respond(to: "poopy diaper")

        XCTAssertEqual(response, .toolUse(.diaper(DiaperDraft(type: .dirty))))
    }

    func test_route_unknownToolName_returnsUnknownWithReason() async throws {
        // Model responded with a tool we do not recognise. We should not throw,
        // we should return `.unknown` so the UI can route to the fallback sheet.
        let json = """
        { "content": [ { "type": "tool_use", "name": "log_sneeze",
                         "input": {} } ] }
        """
        MockURLProtocol.stub(status: 200, body: json)
        let router = makeRouter()

        let response = try await router.respond(to: "achoo")

        guard let toolUse = response.toolUses.first,
              case .unknown(let reason) = toolUse else {
            XCTFail("expected .unknown tool use, got \(response)")
            return
        }
        XCTAssertTrue(reason.contains("log_sneeze"))
    }

    func test_route_textOnlyAnswer_returnsAnswerResponse() async throws {
        let json = """
        { "content": [ { "type": "text", "text": "Ethan's doing great!" } ] }
        """
        MockURLProtocol.stub(status: 200, body: json)
        let router = makeRouter()

        let response = try await router.respond(to: "how is he")

        XCTAssertEqual(response, .answer("Ethan's doing great!"))
    }

    // MARK: - Error paths

    func test_route_missingApiKey_throwsApiKeyMissing() async {
        let router = ClaudeAssistant(
            session: makeMockSession(),
            apiKeyProvider: { nil },
            maxRetries: 0
        )

        await assertThrows(router, expected: .apiKeyMissing)
    }

    func test_route_malformedJson_throwsDecoding() async {
        MockURLProtocol.stub(status: 200, body: "<<not json>>")
        let router = makeRouter(maxRetries: 0)

        await assertThrows(router, expected: .decoding)
    }

    func test_route_apiErrorRateLimit_throwsRateLimited() async {
        // Anthropic style error envelope. Parser should surface `.rateLimited`.
        let json = #"{ "type": "error", "error": { "type": "rate_limit_error", "message": "slow down" } }"#
        MockURLProtocol.stub(status: 200, body: json)
        let router = makeRouter(maxRetries: 0)

        await assertThrows(router, expected: .rateLimited)
    }

    func test_route_http401_throwsUnauthenticated() async {
        MockURLProtocol.stub(status: 401, body: "{}")
        let router = makeRouter(maxRetries: 0)

        await assertThrows(router, expected: .unauthenticated)
    }

    func test_route_http429_retriesThenThrowsRateLimited() async {
        MockURLProtocol.stub(status: 429, body: "{}")
        let router = makeRouter(maxRetries: 0)

        await assertThrows(router, expected: .rateLimited)
    }

    func test_route_http500_retriesThenThrowsNetwork() async {
        MockURLProtocol.stub(status: 500, body: "{}")
        let router = makeRouter(maxRetries: 0)

        await assertThrows(router, expected: .network)
    }

    // MARK: - Helpers

    private func makeRouter(maxRetries: Int = 0) -> ClaudeAssistant {
        ClaudeAssistant(
            session: makeMockSession(),
            apiKeyProvider: { "test-key" },
            maxRetries: maxRetries
        )
    }

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func assertThrows(
        _ router: ClaudeAssistant,
        expected: AssistantError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await router.respond(to: "anything")
            XCTFail("expected throw", file: file, line: line)
        } catch {
            XCTAssertEqual(error, expected, file: file, line: line)
        }
    }
}

// MARK: - URLProtocol mock

/// Minimal `URLProtocol` that returns a scripted `(status, body)` pair for
/// every request. Tests install it via `URLSessionConfiguration.protocolClasses`.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {

    // Shared script — tests reset this in `tearDown`.
    nonisolated(unsafe) private static var stubStatus: Int = 200
    nonisolated(unsafe) private static var stubBody: String = "{}"
    private static let lock = NSLock()

    static func stub(status: Int, body: String) {
        lock.lock(); defer { lock.unlock() }
        stubStatus = status
        stubBody = body
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        stubStatus = 200
        stubBody = "{}"
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
            headerFields: ["Content-Type": "application/json"]
        ) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
