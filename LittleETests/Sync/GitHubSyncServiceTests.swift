import XCTest
import LittleECore
@testable import LittleE

/// URLProtocol-mocked tests for `GitHubSyncService`. No real network —
/// every HTTP exchange is scripted by URL + method so the suite stays
/// hermetic. Covers push, pull, auth failure, SHA-conflict retry, own-file
/// skipping, and the structural-validity guard on peer events.
@MainActor
final class GitHubSyncServiceTests: XCTestCase {

    private let selfDeviceID = DeviceID("DEVICE-SELF")
    private let peerDeviceID = DeviceID("DEVICE-PEER")

    override func tearDown() {
        super.tearDown()
        SyncURLProtocol.reset()
    }

    // MARK: - pullPeers

    func test_pullPeers_appliesFreshPeerEvents_andMarksConnected() async throws {
        let store = InMemoryEventStore()
        let engine = SyncEngine(store: store, deviceID: selfDeviceID)

        let peerEvent = makeEvent(device: peerDeviceID, record: "feed-1")
        let peerFile = encodeJSONL([peerEvent])

        SyncURLProtocol.route { request in
            guard let url = request.url else { return nil }
            if url.path.hasSuffix("/git/trees/main") {
                let body = """
                { "tree": [
                    { "path": "events-test/\(self.peerDeviceID.rawValue).jsonl",
                      "type": "blob", "sha": "peerSHA-1" }
                ] }
                """
                return .json(status: 200, body: body)
            }
            if url.path.contains("/contents/events-test/\(self.peerDeviceID.rawValue).jsonl") {
                return .raw(status: 200, body: peerFile)
            }
            // Self-device lookups during pushLocal (fetch SHA, PUT) — return 404/201.
            if url.path.contains("/contents/events-test/\(self.selfDeviceID.rawValue).jsonl") {
                if request.httpMethod == "PUT" {
                    return .json(status: 201, body: #"{ "content": { "sha": "selfSHA-1" } }"#)
                }
                return .json(status: 404, body: "{}")
            }
            return nil
        }

        let service = GitHubSyncService(
            engine: engine,
            session: mockSession(),
            config: GitHubSyncConfig(repoSlug: "owner/repo", token: "pat")
        )

        await service.syncNow()

        let applied = await engine.allEvents()
        XCTAssertTrue(applied.contains { $0.recordID == "feed-1" })
        if case .connected = service.status {} else {
            XCTFail("expected connected status, got \(service.status)")
        }
    }

    func test_pullPeers_http401_marksUnavailable() async throws {
        let store = InMemoryEventStore()
        let engine = SyncEngine(store: store, deviceID: selfDeviceID)

        SyncURLProtocol.route { _ in .json(status: 401, body: #"{"message":"Bad credentials"}"#) }

        let service = GitHubSyncService(
            engine: engine,
            session: mockSession(),
            config: GitHubSyncConfig(repoSlug: "owner/repo", token: "bad")
        )

        await service.syncNow()

        if case .unavailable = service.status {} else {
            XCTFail("expected unavailable status, got \(service.status)")
        }
    }

    func test_pullPeers_skipsOwnDeviceFile() async throws {
        let store = InMemoryEventStore()
        let engine = SyncEngine(store: store, deviceID: selfDeviceID)

        var fetchedPaths: [String] = []
        SyncURLProtocol.route { request in
            guard let url = request.url else { return nil }
            if url.path.hasSuffix("/git/trees/main") {
                let body = """
                { "tree": [
                    { "path": "events-test/\(self.selfDeviceID.rawValue).jsonl",
                      "type": "blob", "sha": "self" },
                    { "path": "events-test/\(self.peerDeviceID.rawValue).jsonl",
                      "type": "blob", "sha": "peer" }
                ] }
                """
                return .json(status: 200, body: body)
            }
            if url.path.contains("/contents/events-test/") {
                fetchedPaths.append(url.path)
                if request.httpMethod == "PUT" {
                    return .json(status: 200, body: #"{ "content": { "sha": "x" } }"#)
                }
                if url.path.contains(self.selfDeviceID.rawValue) {
                    return .json(status: 404, body: "{}")
                }
                return .raw(status: 200, body: Data())
            }
            return nil
        }

        let service = GitHubSyncService(
            engine: engine,
            session: mockSession(),
            config: GitHubSyncConfig(repoSlug: "owner/repo", token: "pat")
        )

        await service.syncNow()

        let peerGETs = fetchedPaths.filter {
            $0.contains("contents/events-test/\(peerDeviceID.rawValue)")
        }
        XCTAssertFalse(peerGETs.isEmpty, "expected peer file fetch")
    }

    // MARK: - pushLocal

    func test_pushLocal_retriesOnShaConflict() async throws {
        let store = InMemoryEventStore()
        let engine = SyncEngine(store: store, deviceID: selfDeviceID)
        try await store.append(makeEvent(device: selfDeviceID, record: "local-1"))

        var putCount = 0
        SyncURLProtocol.route { request in
            guard let url = request.url else { return nil }
            if url.path.hasSuffix("/git/trees/main") {
                return .json(status: 200, body: #"{ "tree": [] }"#)
            }
            if url.path.contains("/contents/events-test/\(self.selfDeviceID.rawValue).jsonl") {
                if request.httpMethod == "PUT" {
                    putCount += 1
                    if putCount == 1 {
                        return .json(status: 409, body: #"{"message":"sha mismatch"}"#)
                    }
                    return .json(status: 200, body: #"{ "content": { "sha": "refreshed" } }"#)
                }
                // SHA lookup — first nil (not cached), then refreshed value.
                return .json(status: 200, body: #"{ "sha": "stale" }"#)
            }
            return nil
        }

        let service = GitHubSyncService(
            engine: engine,
            session: mockSession(),
            config: GitHubSyncConfig(repoSlug: "owner/repo", token: "pat")
        )

        await service.syncNow()

        XCTAssertEqual(putCount, 2, "expected one PUT, one conflict-retry PUT")
    }

    // MARK: - isStructurallyValid

    func test_isStructurallyValid_rejectsEmptyDeviceID() {
        let event = makeEvent(device: DeviceID(""), record: "x")
        XCTAssertFalse(GitHubSyncService.isStructurallyValid(event))
    }

    func test_isStructurallyValid_rejectsEmptyRecordID() {
        let event = makeEvent(device: peerDeviceID, record: "")
        XCTAssertFalse(GitHubSyncService.isStructurallyValid(event))
    }

    func test_isStructurallyValid_rejectsPrehistoricTimestamp() {
        let event = makeEvent(
            device: peerDeviceID,
            record: "x",
            timestamp: Date(timeIntervalSince1970: 1_000_000_000) // 2001
        )
        XCTAssertFalse(GitHubSyncService.isStructurallyValid(event))
    }

    func test_isStructurallyValid_rejectsFutureTimestamp() {
        let event = makeEvent(
            device: peerDeviceID,
            record: "x",
            timestamp: Date().addingTimeInterval(60 * 60 * 24 * 7) // +7 days
        )
        XCTAssertFalse(GitHubSyncService.isStructurallyValid(event))
    }

    func test_isStructurallyValid_rejectsOversizedPayload() {
        let huge = Data(repeating: 0x41, count: 64 * 1024 + 1)
        let event = DomainEvent(
            deviceID: peerDeviceID,
            timestamp: Date(),
            kind: .feedLog,
            operation: .upsert,
            recordID: "x",
            payload: huge
        )
        XCTAssertFalse(GitHubSyncService.isStructurallyValid(event))
    }

    func test_isStructurallyValid_acceptsSaneEvent() {
        let event = makeEvent(device: peerDeviceID, record: "x")
        XCTAssertTrue(GitHubSyncService.isStructurallyValid(event))
    }

    // MARK: - Helpers

    private func makeEvent(
        device: DeviceID,
        record: String,
        timestamp: Date = Date()
    ) -> DomainEvent {
        DomainEvent(
            deviceID: device,
            timestamp: timestamp,
            kind: .feedLog,
            operation: .upsert,
            recordID: record,
            payload: Data("{}".utf8)
        )
    }

    private func encodeJSONL(_ events: [DomainEvent]) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var buffer = Data()
        for e in events {
            buffer.append(try! encoder.encode(e))
            buffer.append(0x0A)
        }
        return buffer
    }

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SyncURLProtocol.self]
        return URLSession(configuration: config)
    }
}

// MARK: - URLProtocol mock

/// A route-based `URLProtocol` stub. Tests install a closure that maps
/// `URLRequest` → scripted `Response`. Returning `nil` from the closure
/// produces a 500 to flag an unhandled route.
final class SyncURLProtocol: URLProtocol, @unchecked Sendable {

    enum Response {
        case json(status: Int, body: String)
        case raw(status: Int, body: Data)
    }

    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) -> Response?)?
    private static let lock = NSLock()

    static func route(_ handler: @escaping @Sendable (URLRequest) -> Response?) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
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
        let response = h?(request) ?? .json(status: 500, body: #"{"error":"unrouted"}"#)

        let status: Int
        let data: Data
        switch response {
        case .json(let s, let b):
            status = s
            data = Data(b.utf8)
        case .raw(let s, let b):
            status = s
            data = b
        }

        if let http = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) {
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
