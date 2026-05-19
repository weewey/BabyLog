import XCTest
@testable import LittleECore

final class ChatMessageTests: XCTestCase {

    func test_init_defaultsToEmptyTextAndNonStreaming() {
        let msg = ChatMessage(role: .user)

        XCTAssertEqual(msg.role, .user)
        XCTAssertEqual(msg.text, "")
        XCTAssertNil(msg.intent)
        XCTAssertFalse(msg.isStreaming)
    }

    func test_mutableTextSupportsStreamingGrowth() {
        var msg = ChatMessage(role: .assistant, isStreaming: true)

        msg.text += "Logged "
        msg.text += "120ml "
        msg.text += "bottle."

        XCTAssertEqual(msg.text, "Logged 120ml bottle.")
        XCTAssertTrue(msg.isStreaming)
    }

    func test_chatBackendRoundTripsAsCodable() throws {
        let backends: [ChatBackend] = [.apple, .gemma]

        for backend in backends {
            let data = try JSONEncoder().encode(backend)
            let decoded = try JSONDecoder().decode(ChatBackend.self, from: data)
            XCTAssertEqual(decoded, backend)
        }
    }

    func test_chatBackendRawValuesAreStable() {
        XCTAssertEqual(ChatBackend.apple.rawValue, "apple")
        XCTAssertEqual(ChatBackend.gemma.rawValue, "gemma")
    }

    func test_init_defaultsAttachmentsToEmpty() {
        let msg = ChatMessage(role: .user, text: "hi")

        XCTAssertEqual(msg.attachments, [])
    }

    func test_init_roundTripsAttachments() throws {
        let attachment = try ChatAttachment(
            mimeType: "image/jpeg",
            data: Data([0x01, 0x02, 0x03]),
            widthPx: 10,
            heightPx: 20
        )

        let msg = ChatMessage(role: .user, text: "look", attachments: [attachment])

        XCTAssertEqual(msg.attachments.count, 1)
        XCTAssertEqual(msg.attachments.first?.mimeType, "image/jpeg")
    }

    func test_equatable_differsWhenAttachmentsDiffer() throws {
        let attachment = try ChatAttachment(
            mimeType: "image/png",
            data: Data([0xAA]),
            widthPx: 1,
            heightPx: 1
        )
        let id = UUID()

        let plain = ChatMessage(id: id, role: .user, text: "x")
        let withImage = ChatMessage(id: id, role: .user, text: "x", attachments: [attachment])

        XCTAssertNotEqual(plain, withImage)
    }
}
