import XCTest
@testable import BabyLog

/// Tests for the `SpeechRecognizing` protocol + the auth helper. The real
/// `SpeechInputPipeline` class can't run in a unit-test bundle (no audio
/// hardware, no speech-framework entitlement) — we test the public surface
/// via a fake and pin the auth branch logic as a pure function.
final class SpeechInputPipelineTests: XCTestCase {

    // MARK: - FakeSpeechInputPipeline

    /// Tiny recording that lets tests assert the pipeline was stopped and
    /// scripts a pre-canned sequence of partial transcripts.
    final class FakePipeline: SpeechRecognizing, @unchecked Sendable {
        var scripted: [String] = []
        var stopError: (any Error)?
        private(set) var stopCallCount = 0
        private var continuation: AsyncThrowingStream<String, any Error>.Continuation?

        func start() async throws -> AsyncThrowingStream<String, any Error> {
            AsyncThrowingStream { continuation in
                self.continuation = continuation
                let scripted = self.scripted
                let stopError = self.stopError
                Task {
                    for partial in scripted {
                        continuation.yield(partial)
                    }
                    if let stopError {
                        continuation.finish(throwing: stopError)
                    } else {
                        continuation.finish()
                    }
                }
                continuation.onTermination = { [weak self] _ in
                    self?.stopCallCount += 1
                }
            }
        }

        func stop() {
            stopCallCount += 1
            continuation?.finish()
        }
    }

    func test_fakePipeline_yieldsAllPartialTranscripts() async throws {
        let fake = FakePipeline()
        fake.scripted = ["hel", "hello", "hello world"]

        let stream = try await fake.start()
        var collected: [String] = []
        for try await partial in stream {
            collected.append(partial)
        }

        XCTAssertEqual(collected, ["hel", "hello", "hello world"])
    }

    func test_fakePipeline_propagatesError() async {
        let fake = FakePipeline()
        fake.scripted = ["hi"]
        fake.stopError = SpeechInputPipelineError.audioEngineFailed

        do {
            let stream = try await fake.start()
            for try await _ in stream {}
            XCTFail("expected error")
        } catch let error as SpeechInputPipelineError {
            XCTAssertEqual(error, .audioEngineFailed)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_fakePipeline_stopIsIdempotent() {
        let fake = FakePipeline()
        fake.stop()
        fake.stop()
        fake.stop()
        XCTAssertEqual(fake.stopCallCount, 3)
    }

    // MARK: - ensureSpeechAuthorized

    final class StubAuthorizer: SpeechAuthorizing, @unchecked Sendable {
        var currentStatusValue: Int
        var requestStatusValue: Int
        private(set) var requestCalled = false

        init(currentStatusValue: Int, requestStatusValue: Int = SpeechAuthStatus.authorized) {
            self.currentStatusValue = currentStatusValue
            self.requestStatusValue = requestStatusValue
        }

        func currentStatus() -> Int { currentStatusValue }

        func request() async -> Int {
            requestCalled = true
            return requestStatusValue
        }
    }

    func test_ensureSpeechAuthorized_returnsWhenAlreadyAuthorized() async throws {
        let stub = StubAuthorizer(currentStatusValue: SpeechAuthStatus.authorized)

        try await ensureSpeechAuthorized(stub)

        XCTAssertFalse(stub.requestCalled)
    }

    func test_ensureSpeechAuthorized_requestsWhenNotDetermined() async throws {
        let stub = StubAuthorizer(
            currentStatusValue: SpeechAuthStatus.notDetermined,
            requestStatusValue: SpeechAuthStatus.authorized
        )

        try await ensureSpeechAuthorized(stub)

        XCTAssertTrue(stub.requestCalled)
    }

    func test_ensureSpeechAuthorized_throwsWhenDenied() async {
        let stub = StubAuthorizer(currentStatusValue: SpeechAuthStatus.denied)

        do {
            try await ensureSpeechAuthorized(stub)
            XCTFail("expected error")
        } catch let error as SpeechInputPipelineError {
            XCTAssertEqual(error, .notAuthorized)
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func test_ensureSpeechAuthorized_throwsWhenRequestResolvesToDenied() async {
        let stub = StubAuthorizer(
            currentStatusValue: SpeechAuthStatus.notDetermined,
            requestStatusValue: SpeechAuthStatus.denied
        )

        do {
            try await ensureSpeechAuthorized(stub)
            XCTFail("expected error")
        } catch let error as SpeechInputPipelineError {
            XCTAssertEqual(error, .notAuthorized)
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }
}
