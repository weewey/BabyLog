import Foundation

/// Opaque image payload attached to a chat turn. Downscaling and format
/// conversion happen in the app layer (where `UIImage` / `ImageIO` live);
/// Core only carries the finished bytes plus identifying metadata so it
/// can stay pure Swift and testable on Linux.
///
/// Never log `data` or include it in error descriptions — baby photos are
/// sensitive per `CLAUDE.md`.
public struct ChatAttachment: Equatable, Sendable, Identifiable {

    public let id: UUID
    /// One of `image/jpeg`, `image/png`, `image/webp`, `image/gif` — the
    /// media types Anthropic's Messages API accepts as `image` blocks.
    public let mimeType: String
    /// Raw bytes already downscaled by the caller. Encoded as base64 when
    /// the Claude backend serializes this attachment into a request body.
    public let data: Data
    public let widthPx: Int
    public let heightPx: Int

    public init(
        id: UUID = UUID(),
        mimeType: String,
        data: Data,
        widthPx: Int,
        heightPx: Int
    ) throws(ChatAttachmentError) {
        guard Self.supportedMimeTypes.contains(mimeType) else {
            throw .unsupportedMimeType
        }
        guard !data.isEmpty else {
            throw .emptyData
        }
        guard widthPx > 0, heightPx > 0 else {
            throw .invalidDimensions
        }
        self.id = id
        self.mimeType = mimeType
        self.data = data
        self.widthPx = widthPx
        self.heightPx = heightPx
    }

    public static let supportedMimeTypes: Set<String> = [
        "image/jpeg",
        "image/png",
        "image/webp",
        "image/gif",
    ]
}

public enum ChatAttachmentError: Error, Equatable, Sendable {
    case unsupportedMimeType
    case emptyData
    case invalidDimensions
}
