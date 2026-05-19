import Foundation
import BabyLogCore
import MLXLMCommon

/// Bidirectional projection between `BabyLogCore` chat-tool types and
/// `mlx-swift-lm`'s `MLXLMCommon.ToolSpec` / `ToolCall` shapes. Kept in a
/// standalone file so the mapping is independently unit-testable and
/// `Gemma4MLXChatSession` stays focused on streaming.
nonisolated enum Gemma4ToolMapping {

    // MARK: - Outbound: ChatTool -> ToolSpec

    /// Project a `ChatTool` into the OpenAI-style function-call schema
    /// `MLXLMCommon.ChatSession` expects (`type: "function"`, nested
    /// `function.parameters` JSON-Schema object). `GemmaFunctionParser`
    /// upstream consumes this shape directly.
    static func toolSpec(for tool: any ChatTool) -> MLXLMCommon.ToolSpec {
        var properties: [String: any Sendable] = [:]
        for (name, prop) in tool.inputSchema.properties {
            var propDict: [String: any Sendable] = [
                "type": prop.type.rawValue
            ]
            if let desc = prop.description {
                propDict["description"] = desc
            }
            if prop.type == .string, let values = prop.enumValues {
                propDict["enum"] = values
            }
            properties[name] = propDict
        }

        let parameters: [String: any Sendable] = [
            "type": "object",
            "properties": properties,
            "required": tool.inputSchema.required,
        ]

        let function: [String: any Sendable] = [
            "name": tool.name,
            "description": tool.description,
            "parameters": parameters,
        ]

        return [
            "type": "function",
            "function": function,
        ]
    }

    static func toolSpecs(from registry: ToolRegistry) -> [MLXLMCommon.ToolSpec] {
        registry.all.map { toolSpec(for: $0) }
    }

    // MARK: - Inbound: MLX JSONValue args -> ToolArguments

    /// Convert the upstream `[String: MLXLMCommon.JSONValue]` argument blob
    /// a tool call arrives with into a `BabyLogCore.ToolArguments`. The
    /// two `JSONValue` enums are structurally identical, so this is a
    /// recursive case-by-case map.
    static func toolArguments(
        from mlxArgs: [String: MLXLMCommon.JSONValue]
    ) -> ToolArguments {
        let mapped = mlxArgs.mapValues(convert(_:))
        return ToolArguments(mapped)
    }

    private static func convert(_ value: MLXLMCommon.JSONValue) -> BabyLogCore.JSONValue {
        switch value {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .int(let i): return .int(i)
        case .double(let d): return .double(d)
        case .string(let s): return .string(s)
        case .array(let a): return .array(a.map(convert(_:)))
        case .object(let o): return .object(o.mapValues(convert(_:)))
        }
    }
}
