import Foundation

/// Errors raised by `ChatTool.execute` (or the surrounding registry)
/// that aren't themselves typed repository errors. Domain errors from
/// `BabyLogCore.Models.*Error` may also escape `execute` directly — the
/// caller should handle both shapes.
public enum ChatToolError: Error, Equatable, Sendable {
    case unknownTool(String)
    case executionFailed(String)
}
