import Foundation

/// A single domain action a chat backend can invoke on the model's
/// behalf — e.g. "create a feed log", "update a diaper log". Concrete
/// tools wrap a `BabyLogCore` repository protocol and validate their
/// arguments before dispatching.
public protocol ChatTool: Sendable {
    /// Stable identifier the chat backend sends to the model when
    /// describing the tool, and that the model echoes back to invoke it.
    var name: String { get }

    /// Natural-language description shown to the model. Should be a
    /// short imperative sentence describing what the tool does.
    var description: String { get }

    /// JSON schema for the tool's arguments. Serialised into the
    /// backend's tool-use payload at request time.
    var inputSchema: ToolInputSchema { get }

    /// Tools that mutate or destroy existing data set this to `true`;
    /// the chat view model uses it to gate execution behind a user
    /// confirmation card.
    var requiresConfirmation: Bool { get }

    /// Run the tool. May throw `ToolArgumentsError`, `ChatToolError`,
    /// or any domain-typed error from the wrapped repository.
    func execute(arguments: ToolArguments) async throws -> ToolResult
}
