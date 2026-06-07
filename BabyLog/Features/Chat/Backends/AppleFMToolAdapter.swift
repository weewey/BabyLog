import Foundation
import BabyLogCore
#if canImport(FoundationModels)
import FoundationModels

/// Bridges a `BabyLogCore.ChatTool` into a `FoundationModels.Tool` so Apple's
/// `LanguageModelSession` can invoke our domain logging tools during a turn.
///
/// Apple owns the tool loop: when the model requests this tool, `call` runs,
/// executes the underlying `ChatTool`, and returns the result content, which
/// the model then folds back into the same generation. We also surface the
/// call + result to the chat layer via `emit` so the UI can render an
/// invocation card — the chat session passes both straight through as
/// `.toolCall` / `.toolResult` deltas (see `AppleFMChatSession`,
/// `ChatSession.executesToolsInternally`).
@available(iOS 26.0, macOS 26.0, *)
struct AppleFMToolAdapter: FoundationModels.Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    private let chatTool: any ChatTool
    private let emit: @Sendable (AppleFMEvent) -> Void

    let parameters: GenerationSchema

    var name: String { chatTool.name }
    var description: String { chatTool.description }

    init(
        chatTool: any ChatTool,
        emit: @escaping @Sendable (AppleFMEvent) -> Void
    ) throws {
        self.chatTool = chatTool
        self.emit = emit
        self.parameters = try AppleFMToolMapping.generationSchema(for: chatTool)
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let id = UUID().uuidString

        let args: ToolArguments
        do {
            args = try AppleFMToolMapping.toolArguments(from: arguments)
        } catch {
            let result = ToolResult(
                content: "Invalid arguments for \(chatTool.name): \(error)",
                isError: true
            )
            emit(.toolCall(id: id, name: chatTool.name, arguments: ToolArguments()))
            emit(.toolResult(id: id, result: result))
            return result.content
        }

        emit(.toolCall(id: id, name: chatTool.name, arguments: args))

        let result: ToolResult
        do {
            result = try await chatTool.execute(arguments: args)
        } catch {
            result = ToolResult(
                content: "Tool '\(chatTool.name)' failed: \(error)",
                isError: true
            )
        }
        emit(.toolResult(id: id, result: result))
        return result.content
    }
}
#endif
