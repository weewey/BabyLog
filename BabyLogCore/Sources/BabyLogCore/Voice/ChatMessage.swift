import Foundation

/// A single message in a Chat tab conversation.
///
/// Pure value type, owned by Core so the iOS chat view model and all three
/// backend adapters can speak in the same shape. The assistant's text grows
/// as `ChatDelta.token` events stream in — the Chat view model replaces the
/// message's `text` on each delta and SwiftUI re-renders the bubble.
public struct ChatMessage: Identifiable, Equatable, Sendable {

    public enum Role: String, Sendable, Codable {
        case user
        case assistant
        case system
        /// A visible inline entry describing a tool call the model made or
        /// the result of executing it. The chat view renders these as
        /// monospaced bubbles between assistant messages.
        case tool
    }

    /// Tool-call / tool-result payload attached to a `tool`-role message.
    /// Surfacing this as a separate message (rather than an attachment on
    /// the assistant's bubble) keeps streaming state simple: once the
    /// assistant yields a tool call, we seal its current text bubble, push
    /// a tool entry, execute, push a tool-result entry, then start a fresh
    /// assistant bubble for the next turn.
    public enum ToolEntry: Equatable, Sendable {
        case call(id: String, name: String, arguments: ToolArguments)
        case result(id: String, name: String, result: ToolResult)
    }

    /// Extended-thinking / chain-of-thought block that the assistant
    /// produced on this turn. Backends that expose reasoning (Anthropic
    /// `thinking` blocks) stash the text + opaque `signature` here so
    /// they can be round-tripped on the next turn — Anthropic requires
    /// thinking blocks with their signature to be echoed back when a
    /// tool_use turn is followed by tool_result, otherwise the model
    /// loses the reasoning context and performance degrades.
    public struct Reasoning: Equatable, Sendable {
        public var text: String
        public var signature: String
        public init(text: String, signature: String) {
            self.text = text
            self.signature = signature
        }
    }

    public let id: UUID
    public let role: Role
    public var text: String
    public var timestamp: Date
    /// Non-nil when the assistant recognized a structured logging action
    /// (feed, diaper, growth, appointment, milestone). The Chat view renders
    /// an inline confirmation card that hands off to the feature repo.
    public var intent: ToolUse?
    /// True while the assistant is still streaming tokens into this message.
    public var isStreaming: Bool
    /// Non-nil for `tool`-role messages. Carries the tool-call or
    /// tool-result payload so views can render it inline.
    public var toolEntry: ToolEntry?
    /// Image attachments on a user turn. Empty for every other role.
    /// Backends that return `supportsImageInput == false` must ignore
    /// attachments or assert; `ChatSessionParityHarness` pins this.
    public var attachments: [ChatAttachment]
    /// Reasoning block the assistant produced on this turn, if any.
    /// Always `nil` for non-assistant roles. Set by the Claude backend
    /// when extended thinking is enabled; other backends leave it `nil`.
    public var reasoning: Reasoning?

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String = "",
        timestamp: Date = Date(),
        intent: ToolUse? = nil,
        isStreaming: Bool = false,
        toolEntry: ToolEntry? = nil,
        attachments: [ChatAttachment] = [],
        reasoning: Reasoning? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.intent = intent
        self.isStreaming = isStreaming
        self.toolEntry = toolEntry
        self.attachments = attachments
        self.reasoning = reasoning
    }
}
