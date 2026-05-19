import XCTest
@testable import BabyLogCore
import Foundation

final class ChatAttachmentTests: XCTestCase {

    private let nonEmptyData = Data([0xFF, 0xD8, 0xFF])

    func test_init_happyPath_acceptsJpeg() throws {
        let attachment = try ChatAttachment(
            mimeType: "image/jpeg",
            data: nonEmptyData,
            widthPx: 640,
            heightPx: 480
        )

        XCTAssertEqual(attachment.mimeType, "image/jpeg")
        XCTAssertEqual(attachment.data, nonEmptyData)
        XCTAssertEqual(attachment.widthPx, 640)
        XCTAssertEqual(attachment.heightPx, 480)
    }

    func test_init_acceptsAllSupportedMimeTypes() throws {
        for mime in ["image/jpeg", "image/png", "image/webp", "image/gif"] {
            _ = try ChatAttachment(mimeType: mime, data: nonEmptyData, widthPx: 1, heightPx: 1)
        }
    }

    func test_init_rejectsUnsupportedMimeType() {
        do {
            _ = try ChatAttachment(mimeType: "image/heic", data: nonEmptyData, widthPx: 1, heightPx: 1)
            XCTFail("expected ChatAttachmentError.unsupportedMimeType")
        } catch {
            XCTAssertEqual(error, .unsupportedMimeType)
        }
    }

    func test_init_rejectsEmptyData() {
        do {
            _ = try ChatAttachment(mimeType: "image/jpeg", data: Data(), widthPx: 1, heightPx: 1)
            XCTFail("expected ChatAttachmentError.emptyData")
        } catch {
            XCTAssertEqual(error, .emptyData)
        }
    }

    func test_init_rejectsZeroWidth() {
        do {
            _ = try ChatAttachment(mimeType: "image/jpeg", data: nonEmptyData, widthPx: 0, heightPx: 10)
            XCTFail("expected ChatAttachmentError.invalidDimensions")
        } catch {
            XCTAssertEqual(error, .invalidDimensions)
        }
    }

    func test_init_rejectsNegativeHeight() {
        do {
            _ = try ChatAttachment(mimeType: "image/jpeg", data: nonEmptyData, widthPx: 10, heightPx: -1)
            XCTFail("expected ChatAttachmentError.invalidDimensions")
        } catch {
            XCTAssertEqual(error, .invalidDimensions)
        }
    }

    func test_equatable_equalAttachmentsAreEqual() throws {
        let id = UUID()
        let a = try ChatAttachment(id: id, mimeType: "image/png", data: nonEmptyData, widthPx: 2, heightPx: 2)
        let b = try ChatAttachment(id: id, mimeType: "image/png", data: nonEmptyData, widthPx: 2, heightPx: 2)
        XCTAssertEqual(a, b)
    }

    func test_equatable_distinctIdsAreNotEqual() throws {
        let a = try ChatAttachment(mimeType: "image/png", data: nonEmptyData, widthPx: 2, heightPx: 2)
        let b = try ChatAttachment(mimeType: "image/png", data: nonEmptyData, widthPx: 2, heightPx: 2)
        XCTAssertNotEqual(a, b)
    }
}
