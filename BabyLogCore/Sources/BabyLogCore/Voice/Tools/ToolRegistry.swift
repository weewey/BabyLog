import Foundation

/// An ordered collection of `ChatTool` values keyed by `name`. The chat
/// backend asks the registry for a tool by name when the model emits a
/// `tool_use` block.
///
/// Insertion order is preserved by `all`. If two tools share a name the
/// later one wins (last-writer-wins) — this mirrors how a registry of
/// overrideable defaults usually behaves in practice.
public struct ToolRegistry: Sendable {

    private let storage: [String: any ChatTool]
    private let order: [String]

    public init(_ tools: [any ChatTool]) {
        var storage: [String: any ChatTool] = [:]
        var order: [String] = []
        for tool in tools {
            if storage[tool.name] == nil {
                order.append(tool.name)
            }
            storage[tool.name] = tool
        }
        self.storage = storage
        self.order = order
    }

    public func tool(named name: String) -> (any ChatTool)? {
        storage[name]
    }

    /// All tools in insertion order (last-writer-wins on duplicate names).
    public var all: [any ChatTool] {
        order.compactMap { storage[$0] }
    }
}
