import XCTest
import LittleECore
@testable import LittleE

@MainActor
final class ChatViewModelAttachmentsTests: XCTestCase {

    private final class InMemoryStore: ChatBackendPreferenceStore, @unchecked Sendable {
        var storage: [String: String] = [:]
        func string(forKey key: String) -> String? { storage[key] }
        func set(_ value: String, forKey key: String) { storage[key] = value }
    }

    /// FakeChatSession defaults `supportsImageInput == false`, matching Gemma.
    private struct GemmaLikeFactory: ChatSessionFactory {
        func makeSession(for backend: ChatBackend) throws -> any ChatSession {
            FakeChatSession(script: .tokens(["ok"], perTokenDelay: .milliseconds(0)))
        }
    }

    /// Session that reports `supportsImageInput == true`, matching Claude.
    private final class ImageCapableSession: ChatSession, @unchecked Sendable {
        var supportsImageInput: Bool { true }
        func stream(_ text: String) -> AsyncThrowingStream<ChatDelta, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(.token("ack"))
                continuation.yield(.done)
                continuation.finish()
            }
        }
        func cancel() {}
    }

    private struct ImageCapableFactory: ChatSessionFactory {
        func makeSession(for backend: ChatBackend) throws -> any ChatSession {
            ImageCapableSession()
        }
    }

    private func makeAttachment() throws -> ChatAttachment {
        // 4 bytes is enough to satisfy Core's non-empty invariant.
        try ChatAttachment(
            mimeType: "image/jpeg",
            data: Data([0xFF, 0xD8, 0xFF, 0xD9]),
            widthPx: 10,
            heightPx: 10
        )
    }

    private func waitUntil(
        _ check: @escaping @MainActor () -> Bool,
        timeout: TimeInterval = 2.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if check() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("waitUntil timed out", file: file, line: line)
    }

    func test_attach_thenSend_bundlesAttachmentIntoUserMessageAndClearsPending() async throws {
        let vm = ChatViewModel(
            factory: ImageCapableFactory(),
            preferenceStore: InMemoryStore()
        )
        let attachment = try makeAttachment()

        vm.attach(attachment)
        XCTAssertEqual(vm.pendingAttachment?.id, attachment.id)

        vm.input = "what's this?"
        vm.send()

        XCTAssertNil(vm.pendingAttachment, "pending attachment should clear after send")
        let userMessage = try XCTUnwrap(vm.messages.first { $0.role == .user })
        XCTAssertEqual(userMessage.attachments.count, 1)
        XCTAssertEqual(userMessage.attachments.first?.id, attachment.id)
        await waitUntil { !vm.isStreaming }
    }

    func test_clearAttachment_removesPendingWithoutSending() throws {
        let vm = ChatViewModel(
            factory: ImageCapableFactory(),
            preferenceStore: InMemoryStore()
        )
        let attachment = try makeAttachment()

        vm.attach(attachment)
        vm.clearAttachment()

        XCTAssertNil(vm.pendingAttachment)
        XCTAssertTrue(vm.messages.isEmpty)
    }

    func test_send_withAttachment_onBackendWithoutImageSupport_surfacesErrorAndKeepsAttachment() throws {
        let vm = ChatViewModel(
            factory: GemmaLikeFactory(),
            preferenceStore: InMemoryStore()
        )
        let attachment = try makeAttachment()

        vm.attach(attachment)
        vm.input = "look at this"
        vm.send()

        XCTAssertEqual(vm.error, .attachmentNotSupported)
        XCTAssertEqual(vm.pendingAttachment?.id, attachment.id,
                       "attachment should survive so the user can switch backend and retry")
        XCTAssertTrue(vm.messages.isEmpty, "no user message should be posted")
        XCTAssertFalse(vm.isStreaming)
    }

    func test_supportsImageInput_reflectsSessionCapability() {
        let claudeLike = ChatViewModel(
            factory: ImageCapableFactory(),
            preferenceStore: InMemoryStore()
        )
        let gemmaLike = ChatViewModel(
            factory: GemmaLikeFactory(),
            preferenceStore: InMemoryStore()
        )

        XCTAssertTrue(claudeLike.supportsImageInput)
        XCTAssertFalse(gemmaLike.supportsImageInput)
    }
}
