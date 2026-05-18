import XCTest
@testable import LittleE

/// URLProtocol-mocked tests for `UpdateChecker`. Verifies it correctly
/// flags a newer build, ignores an equal/older build, and silently
/// no-ops on missing token / 404 / malformed manifest. Real network is
/// never touched.
@MainActor
final class UpdateCheckerTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
        UpdateCheckerURLProtocol.reset()
    }

    private static let fakeConfig = GitHubSyncConfig(repoSlug: "owner/repo", token: "test-token")

    func test_newerBuild_setsIsUpdateAvailable() async {
        // The fixture bundle declares CFBundleVersion = 10. Manifest
        // returns 14, so an update is available.
        UpdateCheckerURLProtocol.respond { _ in
            .json(status: 200, body: #"{"build":14}"#)
        }

        let checker = UpdateChecker(
            session: mockSession(),
            currentBuild: { 10 },
            configProvider: { Self.fakeConfig }
        )
        await checker.check()

        XCTAssertEqual(checker.latestBuild, 14)
        XCTAssertTrue(checker.isUpdateAvailable)
    }

    func test_equalBuild_isNotUpdateAvailable() async {
        UpdateCheckerURLProtocol.respond { _ in
            .json(status: 200, body: #"{"build":10}"#)
        }
        let checker = UpdateChecker(
            session: mockSession(),
            currentBuild: { 10 },
            configProvider: { Self.fakeConfig }
        )
        await checker.check()

        XCTAssertEqual(checker.latestBuild, 10)
        XCTAssertFalse(checker.isUpdateAvailable)
    }

    func test_olderBuild_isNotUpdateAvailable() async {
        UpdateCheckerURLProtocol.respond { _ in
            .json(status: 200, body: #"{"build":3}"#)
        }
        let checker = UpdateChecker(
            session: mockSession(),
            currentBuild: { 10 },
            configProvider: { Self.fakeConfig }
        )
        await checker.check()

        XCTAssertFalse(checker.isUpdateAvailable)
    }

    func test_http404_leavesStateUnchanged() async {
        UpdateCheckerURLProtocol.respond { _ in
            .json(status: 404, body: #"{"message":"Not Found"}"#)
        }
        let checker = UpdateChecker(
            session: mockSession(),
            currentBuild: { 10 },
            configProvider: { Self.fakeConfig }
        )
        await checker.check()

        XCTAssertNil(checker.latestBuild)
        XCTAssertFalse(checker.isUpdateAvailable)
    }

    func test_malformedJson_leavesStateUnchanged() async {
        UpdateCheckerURLProtocol.respond { _ in
            .json(status: 200, body: "not json")
        }
        let checker = UpdateChecker(
            session: mockSession(),
            currentBuild: { 10 },
            configProvider: { Self.fakeConfig }
        )
        await checker.check()

        XCTAssertNil(checker.latestBuild)
        XCTAssertFalse(checker.isUpdateAvailable)
    }

    func test_missingBundleVersion_isNoOp() async {
        UpdateCheckerURLProtocol.respond { _ in
            .json(status: 200, body: #"{"build":14}"#)
        }
        let checker = UpdateChecker(
            session: mockSession(),
            currentBuild: { nil }
        )
        await checker.check()

        XCTAssertNil(checker.latestBuild)
        XCTAssertFalse(checker.isUpdateAvailable)
    }

    // MARK: - Helpers

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdateCheckerURLProtocol.self]
        return URLSession(configuration: config)
    }
}

// MARK: - URLProtocol stub

final class UpdateCheckerURLProtocol: URLProtocol, @unchecked Sendable {

    enum Response { case json(status: Int, body: String) }

    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) -> Response)?
    private static let lock = NSLock()

    static func respond(_ h: @escaping @Sendable (URLRequest) -> Response) {
        lock.lock(); defer { lock.unlock() }
        handler = h
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        handler = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let h = Self.handler
        Self.lock.unlock()

        let url = request.url ?? URL(string: "https://example.invalid")!
        let response = h?(request) ?? .json(status: 500, body: "{}")
        switch response {
        case .json(let status, let body):
            let http = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

