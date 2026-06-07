import Foundation
import BabyLogCore
#if canImport(FoundationModels)
import FoundationModels

/// Projects `BabyLogCore` chat-tool types into the Apple Foundation Models
/// tool-calling shapes, and back. Kept standalone from `AppleFMChatSession`
/// so the (bug-prone) schema/argument mapping is independently unit-testable
/// against the real `FoundationModels` runtime.
@available(iOS 26.0, macOS 26.0, *)
enum AppleFMToolMapping {

    // MARK: - Outbound: ChatTool schema -> GenerationSchema

    /// Build a `GenerationSchema` describing a tool's arguments so the model
    /// produces well-typed tool-call arguments. `dateTime` properties map to
    /// `String` (the model emits an ISO-8601 string, parsed downstream by
    /// `ToolArguments.date`); `string` properties carrying `enumValues`
    /// become a closed `anyOf` choice set.
    static func generationSchema(for tool: any ChatTool) throws -> GenerationSchema {
        let schema = tool.inputSchema
        let requiredNames = Set(schema.required)

        let properties: [DynamicGenerationSchema.Property] = schema.properties.map { entry in
            let (name, prop) = entry
            let valueSchema: DynamicGenerationSchema
            if prop.type == .string, let values = prop.enumValues, !values.isEmpty {
                valueSchema = DynamicGenerationSchema(name: "\(tool.name)_\(name)", anyOf: values)
            } else {
                switch prop.type {
                case .string, .dateTime:
                    valueSchema = DynamicGenerationSchema(type: String.self)
                case .integer:
                    valueSchema = DynamicGenerationSchema(type: Int.self)
                case .number:
                    valueSchema = DynamicGenerationSchema(type: Double.self)
                case .boolean:
                    valueSchema = DynamicGenerationSchema(type: Bool.self)
                }
            }
            return DynamicGenerationSchema.Property(
                name: name,
                description: prop.description,
                schema: valueSchema,
                isOptional: !requiredNames.contains(name)
            )
        }

        let root = DynamicGenerationSchema(
            name: tool.name,
            description: tool.description,
            properties: properties
        )
        return try GenerationSchema(root: root, dependencies: [])
    }

    // MARK: - Inbound: GeneratedContent -> ToolArguments

    /// Decode the `GeneratedContent` the model produced for a tool call into
    /// `ToolArguments`. Routes through the JSON representation so the existing
    /// `JSONValue` `Codable` handles every primitive coercion in one place.
    static func toolArguments(from content: GeneratedContent) throws -> ToolArguments {
        let json = content.jsonString
        guard let data = json.data(using: .utf8) else { return ToolArguments() }
        let decoded = try JSONDecoder().decode([String: JSONValue].self, from: data)
        return ToolArguments(decoded)
    }
}
#endif
