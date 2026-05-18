import Foundation

/// A `Codable`, `Sendable` JSON value.
///
/// `JSONValue` is intentionally untyped: tool arguments, JSON Schema
/// definitions, and raw provider payloads all flow through this enum so we can
/// stay independent of any particular provider's strongly-typed model layer.
public enum JSONValue: Sendable, Hashable {
    /// JSON object payload.
    case object([String: JSONValue])
    /// JSON array payload.
    case array([JSONValue])
    /// JSON string payload.
    case string(String)
    /// JSON floating-point number payload.
    case number(Double)
    /// JSON integer payload (preserved separately from `.number`).
    case integer(Int)
    /// JSON boolean payload.
    case bool(Bool)
    /// JSON `null` payload.
    case null

    /// Convenience accessor for `.object` payloads.
    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Convenience accessor for `.string` payloads.
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// Convenience accessor that coerces `.integer` or `.number` to `Int`.
    public var intValue: Int? {
        if case .integer(let value) = self { return value }
        if case .number(let value) = self { return Int(value) }
        return nil
    }
}

extension JSONValue: Codable {
    /// Decode a `JSONValue` from any single-value Codable container.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Int.self) {
            self = .integer(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .number(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
            return
        }
        if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unable to decode JSONValue"
        )
    }

    /// Encode a `JSONValue` into any single-value Codable container.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral {
    /// Build a `.string` value from a string literal.
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    /// Build an `.integer` value from an integer literal.
    public init(integerLiteral value: Int) {
        self = .integer(value)
    }
}

extension JSONValue: ExpressibleByFloatLiteral {
    /// Build a `.number` value from a float literal.
    public init(floatLiteral value: Double) {
        self = .number(value)
    }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    /// Build a `.bool` value from a boolean literal.
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension JSONValue: ExpressibleByNilLiteral {
    /// Build a `.null` value from a `nil` literal.
    public init(nilLiteral: ()) {
        self = .null
    }
}

extension JSONValue: ExpressibleByArrayLiteral {
    /// Build an `.array` value from an array literal.
    public init(arrayLiteral elements: JSONValue...) {
        self = .array(elements)
    }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    /// Build an `.object` value from a dictionary literal.
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var dict: [String: JSONValue] = [:]
        for (key, value) in elements {
            dict[key] = value
        }
        self = .object(dict)
    }
}
