import XCTest
import UIKit
import BabyLogCore
@testable import BabyLog

final class ChatImageProcessorTests: XCTestCase {

    /// Build an opaque solid-color `UIImage` at the given point size (scale 1).
    private func solidImage(width: CGFloat, height: CGFloat, color: UIColor = .systemPink) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func pngData(_ image: UIImage) throws -> Data {
        try XCTUnwrap(image.pngData())
    }

    func test_process_returnsJpegAttachmentFromSmallPng() async throws {
        let image = solidImage(width: 200, height: 100)
        let data = try pngData(image)

        let attachment = try await ChatImageProcessor().process(imageData: data)

        XCTAssertEqual(attachment.mimeType, "image/jpeg")
        XCTAssertFalse(attachment.data.isEmpty)
        XCTAssertGreaterThan(attachment.widthPx, 0)
        XCTAssertGreaterThan(attachment.heightPx, 0)
    }

    func test_process_downscalesLongestEdgeToAtMost1568() async throws {
        // 4000 x 2000 — both edges above the cap, longest edge is width.
        let image = solidImage(width: 4000, height: 2000)
        let data = try pngData(image)

        let attachment = try await ChatImageProcessor().process(imageData: data)

        XCTAssertLessThanOrEqual(attachment.widthPx, 1568)
        XCTAssertLessThanOrEqual(attachment.heightPx, 1568)
        XCTAssertEqual(max(attachment.widthPx, attachment.heightPx), 1568)
    }

    func test_process_preservesAspectRatioWhenDownscaling() async throws {
        let image = solidImage(width: 4000, height: 1000) // 4:1 aspect
        let data = try pngData(image)

        let attachment = try await ChatImageProcessor().process(imageData: data)

        // Expect ~1568 x ~392 (4:1). Allow a little rounding slack.
        XCTAssertEqual(attachment.widthPx, 1568)
        XCTAssertEqual(attachment.heightPx, 392, accuracy: 2)
    }

    func test_process_smallImage_isNotUpscaled() async throws {
        let image = solidImage(width: 50, height: 75)
        let data = try pngData(image)

        let attachment = try await ChatImageProcessor().process(imageData: data)

        XCTAssertEqual(attachment.widthPx, 50)
        XCTAssertEqual(attachment.heightPx, 75)
    }

    func test_process_invalidBytes_throwsDecodeFailed() async {
        let garbage = Data([0x00, 0x01, 0x02, 0x03])

        do {
            _ = try await ChatImageProcessor().process(imageData: garbage)
            XCTFail("Expected decodeFailed")
        } catch ChatImageProcessingError.decodeFailed {
            // success
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

// Small helper: XCTAssertEqual with integer accuracy (XCTest only ships
// the accuracy overload for FloatingPoint).
private func XCTAssertEqual(
    _ actual: Int,
    _ expected: Int,
    accuracy: Int,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertTrue(
        abs(actual - expected) <= accuracy,
        "\(actual) not within \(accuracy) of \(expected)",
        file: file,
        line: line
    )
}
