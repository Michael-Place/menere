import Foundation

/// A JSON-shaped value passed to/from agent tools. Tool inputs arrive as `[String: AgentValue]`
/// (decoded from the model's `tool_use.input`), and tool schemas / wire payloads are built from it.
/// Deliberately small and `Sendable` so it crosses the phone↔proxy boundary and mocks cleanly.
public enum AgentValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([AgentValue])
    case object([String: AgentValue])
}

// MARK: - Typed accessors

public extension AgentValue {
    var stringValue: String? {
        switch self {
        case let .string(s): return s
        case let .int(i): return String(i)
        case let .double(d): return String(d)
        case let .bool(b): return String(b)
        default: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case let .int(i): return i
        case let .double(d): return Int(d)
        case let .string(s): return Int(s)
        case let .bool(b): return b ? 1 : 0
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case let .double(d): return d
        case let .int(i): return Double(i)
        case let .string(s): return Double(s)
        default: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case let .bool(b): return b
        case let .int(i): return i != 0
        case let .string(s):
            switch s.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        default: return nil
        }
    }
}

/// Ergonomic typed reads over a decoded tool-input object.
public extension Dictionary where Key == String, Value == AgentValue {
    func string(_ key: String) -> String? { self[key]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
    func int(_ key: String) -> Int? { self[key]?.intValue }
    func double(_ key: String) -> Double? { self[key]?.doubleValue }
    func bool(_ key: String) -> Bool? { self[key]?.boolValue }
}

// MARK: - Codable

extension AgentValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([AgentValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: AgentValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported AgentValue")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .string(s): try c.encode(s)
        case let .int(i): try c.encode(i)
        case let .double(d): try c.encode(d)
        case let .bool(b): try c.encode(b)
        case .null: try c.encodeNil()
        case let .array(a): try c.encode(a)
        case let .object(o): try c.encode(o)
        }
    }
}

// MARK: - Bridging to/from Foundation `Any` (Firebase callable payloads)

public extension AgentValue {
    /// A JSON-serializable Foundation value (for FirebaseFunctions callable payloads).
    var anyValue: Any {
        switch self {
        case let .string(s): return s
        case let .int(i): return i
        case let .double(d): return d
        case let .bool(b): return b
        case .null: return NSNull()
        case let .array(a): return a.map(\.anyValue)
        case let .object(o): return o.mapValues(\.anyValue)
        }
    }

    /// Build an `AgentValue` from a Foundation value returned by a callable (`NSDictionary`/`NSArray`/…).
    init(any value: Any) {
        switch value {
        case let v as AgentValue: self = v
        case is NSNull: self = .null
        case let n as NSNumber:
            // NSNumber muddles Bool/Int/Double — disambiguate by the ObjC type encoding.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else if n.stringValue.contains(".") || n.stringValue.contains("e") {
                self = .double(n.doubleValue)
            } else {
                self = .int(n.intValue)
            }
        case let b as Bool: self = .bool(b)
        case let i as Int: self = .int(i)
        case let d as Double: self = .double(d)
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { AgentValue(any: $0) })
        case let o as [String: Any]: self = .object(o.mapValues { AgentValue(any: $0) })
        default: self = .null
        }
    }

    /// Compact JSON string (used for model-facing tool content).
    var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }
}
