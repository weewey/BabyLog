import Foundation

/// The natural-language outcome of executing a `ChatTool`. The chat
/// session feeds `content` back to the model on its next turn; `isError`
/// signals whether the model should treat the call as having failed.
public struct ToolResult: Sendable, Equatable, Codable {
    public let content: String
    public let isError: Bool

    public init(content: String, isError: Bool = false) {
        self.content = content
        self.isError = isError
    }
}
