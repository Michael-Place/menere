import Foundation

/// A minimal, serializable JSON-Schema node — the model-facing `input_schema` for each agent tool.
/// `jsonValue` renders a valid Anthropic tool-use schema (`type` + `properties`/`items` + `required`).
public indirect enum JSONSchema: Sendable, Equatable {
    case object(properties: [String: JSONSchema], required: [String], description: String?)
    case string(description: String?, enumValues: [String]?)
    case integer(description: String?)
    case number(description: String?)
    case boolean(description: String?)
    case array(items: JSONSchema, description: String?)

    // Convenience constructors (keep call sites terse).
    public static func object(_ properties: [String: JSONSchema], required: [String] = [], description: String? = nil) -> JSONSchema {
        .object(properties: properties, required: required, description: description)
    }
    public static func string(_ description: String? = nil, enum enumValues: [String]? = nil) -> JSONSchema {
        .string(description: description, enumValues: enumValues)
    }
    public static func integer(_ description: String? = nil) -> JSONSchema { .integer(description: description) }
    public static func number(_ description: String? = nil) -> JSONSchema { .number(description: description) }
    public static func boolean(_ description: String? = nil) -> JSONSchema { .boolean(description: description) }
    public static func array(of items: JSONSchema, description: String? = nil) -> JSONSchema {
        .array(items: items, description: description)
    }
}

public extension JSONSchema {
    /// The schema as an `AgentValue` object (valid JSON Schema for the Anthropic API).
    var jsonValue: AgentValue {
        switch self {
        case let .object(properties, required, description):
            var obj: [String: AgentValue] = [
                "type": .string("object"),
                "properties": .object(properties.mapValues(\.jsonValue)),
                "additionalProperties": .bool(false),
            ]
            if !required.isEmpty { obj["required"] = .array(required.map(AgentValue.string)) }
            if let description { obj["description"] = .string(description) }
            return .object(obj)
        case let .string(description, enumValues):
            var obj: [String: AgentValue] = ["type": .string("string")]
            if let description { obj["description"] = .string(description) }
            if let enumValues { obj["enum"] = .array(enumValues.map(AgentValue.string)) }
            return .object(obj)
        case let .integer(description):
            var obj: [String: AgentValue] = ["type": .string("integer")]
            if let description { obj["description"] = .string(description) }
            return .object(obj)
        case let .number(description):
            var obj: [String: AgentValue] = ["type": .string("number")]
            if let description { obj["description"] = .string(description) }
            return .object(obj)
        case let .boolean(description):
            var obj: [String: AgentValue] = ["type": .string("boolean")]
            if let description { obj["description"] = .string(description) }
            return .object(obj)
        case let .array(items, description):
            var obj: [String: AgentValue] = ["type": .string("array"), "items": items.jsonValue]
            if let description { obj["description"] = .string(description) }
            return .object(obj)
        }
    }

    /// Foundation `Any` for the callable payload.
    var anyValue: Any { jsonValue.anyValue }
}
