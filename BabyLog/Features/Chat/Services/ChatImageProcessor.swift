import Foundation
import UIKit
import BabyLogCore

/// Errors raised by `ChatImageProcessor` when an image picked from the
/// Photos library can't be decoded, downscaled, or re-encoded for transport
/// to a multimodal chat backend.
public enum ChatImageProcessingError: Error, Equatable, Sendable {
    /// Raw bytes couldn't be decoded into a `UIImage` (unsupported format
    /// or corrupt data).
    case decodeFailed
    /// `UIGraphicsImageRenderer` produced zero-byte JPEG data.
    case encodeFailed
    /// Core rejected the finished attachment (shouldn't happen in practice,
    /// we always emit `image/jpeg` + non-empty data + positive dims).
    case attachmentRejected(ChatAttachmentError)
}

/// Turns raw photo bytes into a `ChatAttachment` suitable for a multimodal
/// chat backend. Protocol + live impl so tests can inject a fake.
public protocol ChatImageProcessing: Sendable {
    /// Decode, downscale (longest edge ≤ 1568px per Anthropic vision
    /// recommendation), re-encode as JPEG q=0.85, and wrap in a
    /// `ChatAttachment`. Runs off the main actor — callers should `await`.
    func process(imageData: Data) async throws -> ChatAttachment
}

/// Longest edge in pixels we downscale to before sending an image to a
/// multimodal model. Matches Anthropic's vision docs — larger images cost
/// more tokens without helping accuracy.
public let chatImageMaxEdgePx: CGFloat = 1568

/// JPEG quality used for outgoing chat attachments. 0.85 keeps file size
/// reasonable while avoiding visible compression artefacts.
public let chatImageJPEGQuality: CGFloat = 0.85

/// Production implementation backed by `UIGraphicsImageRenderer`.
public struct ChatImageProcessor: ChatImageProcessing {

    public init() {}

    public func process(imageData: Data) async throws -> ChatAttachment {
        // Do the heavy work off the main actor via a detached task.
        try await Task.detached(priority: .userInitiated) {
            try Self.processSync(imageData: imageData)
        }.value
    }

    /// Synchronous core of `process`. Exposed `internal` for testing; the
    /// public API is still the `async` one.
    static func processSync(imageData: Data) throws -> ChatAttachment {
        guard let decoded = UIImage(data: imageData) else {
            throw ChatImageProcessingError.decodeFailed
        }

        let downscaled = downscale(decoded)
        guard let jpeg = downscaled.jpegData(compressionQuality: chatImageJPEGQuality),
              !jpeg.isEmpty else {
            throw ChatImageProcessingError.encodeFailed
        }

        let widthPx = Int(downscaled.size.width * downscaled.scale)
        let heightPx = Int(downscaled.size.height * downscaled.scale)

        do {
            return try ChatAttachment(
                mimeType: "image/jpeg",
                data: jpeg,
                widthPx: max(widthPx, 1),
                heightPx: max(heightPx, 1)
            )
        } catch {
            throw ChatImageProcessingError.attachmentRejected(error)
        }
    }

    /// Rescale so the longest edge is ≤ `chatImageMaxEdgePx` in *point*
    /// space (we force a 1x renderer so points == pixels in the output).
    /// Pass-through when the image already fits.
    private static func downscale(_ image: UIImage) -> UIImage {
        let pxWidth = image.size.width * image.scale
        let pxHeight = image.size.height * image.scale
        let longest = max(pxWidth, pxHeight)
        guard longest > chatImageMaxEdgePx else {
            // Still round-trip through a 1x renderer so `scale == 1` and the
            // pixel dimensions returned by the caller match the JPEG bytes.
            return render(image, targetSize: CGSize(width: pxWidth, height: pxHeight))
        }
        let ratio = chatImageMaxEdgePx / longest
        let target = CGSize(width: floor(pxWidth * ratio), height: floor(pxHeight * ratio))
        return render(image, targetSize: target)
    }

    private static func render(_ image: UIImage, targetSize: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}
