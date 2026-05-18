import Foundation

/// Minimal typed JSON-schema representation used to describe a tool's
/// argument shape to a chat model. Designed to serialise into the
/// Anthropic tool-use JSON shape:
///
/// ```
/// { "type": "object",
///   "properties": { "<name>": { "type": "<t>", ... }, ... },
///   "required": [ ... ] }
/// ```
public struct ToolInputSchema: Sendable, Equatable, Encodable {

    public enum PropertyType: String, Sendable, Equatable {
        case string
        case integer
        case number
        case boolean
    }

    public struct Property: Sendable, Equatable {
        public let type: PropertyType
        public let description: String?
        /// When non-nil, restricts a `string` property to one of these
        /// values. Ignored for non-string types.
        public let enumValues: [String]?

        public init(
            type: PropertyType,
            description: String? = nil,
            enumValues: [String]? = nil
        ) {
            self.type = type
            self.description = description
            self.enumValues = enumValues
        }
    }

    /// Insertion-ordered list of properties. We use an ordered list so
    /// the JSON output is deterministic across runs (helpful for tests).
    public let properties: [(name: String, property: Property)]
    public let required: [String]

    public init(properties: [(name: String, property: Property)], required: [String]) {
        self.properties = properties
        self.required = required
    }

    // Equatable can't be synthesised because of the tuple list.
    public static func == (lhs: ToolInputSchema, rhs: ToolInputSchema) -> Bool {
        guard lhs.required == rhs.required,
              lhs.properties.count == rhs.properties.count else { return false }
        for (l, r) in zip(lhs.properties, rhs.properties) {
            if l.name != r.name || l.property != r.property { return false }
        }
        return true
    }

    // MARK: - Encoding

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private enum TopKey: String, CodingKey {
        case type
        case properties
        case required
    }

    private enum PropKey: String, CodingKey {
        case type
        case description
        case `enum`
    }

    public func encode(to encoder: any Encoder) throws {
        var top = encoder.container(keyedBy: TopKey.self)
        try top.encode("object", forKey: .type)

        var propsContainer = top.nestedContainer(
            keyedBy: DynamicKey.self,
            forKey: .properties
        )
        for (name, property) in properties {
            var propEnc = propsContainer.nestedContainer(
                keyedBy: PropKey.self,
                forKey: DynamicKey(stringValue: name)
            )
            try propEnc.encode(property.type.rawValue, forKey: .type)
            if let desc = property.description {
                try propEnc.encode(desc, forKey: .description)
            }
            if property.type == .string, let values = property.enumValues {
                try propEnc.encode(values, forKey: .enum)
            }
        }

        try top.encode(required, forKey: .required)
    }
}
