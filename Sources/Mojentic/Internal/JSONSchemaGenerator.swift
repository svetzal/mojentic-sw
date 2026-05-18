import Foundation

/// Derives a JSON Schema (`JSONValue`-shaped) for a `Codable & Sendable`
/// Swift type, used by `LLMBroker.completeJSON` to give the model a typed
/// target shape.
///
/// Strategy:
/// 1. If the type opts in by conforming to `JSONSchemaProviding`, use the
///    `static var jsonSchema` it returns. This is the escape hatch for
///    shapes that cannot be inferred from a sample value (nested generics,
///    enums with associated values, etc.).
/// 2. Otherwise, attempt to derive a schema from a sample instance via
///    `Mirror` reflection of an `init()` call. This works for simple structs
///    with primitives, optionals, nested structs, and arrays.
///
/// > Future work: replace the reflection path with a Swift macro
/// > (`@LLMToolArguments`) once we hit ergonomic friction. The macro design
/// > is out of Phase 1 scope per `SWIFT.md` §10.1.
public enum JSONSchemaGenerator {
    /// Generate a JSON Schema for `type`.
    ///
    /// Throws `MojenticError.schema` if the type cannot be schematised by
    /// either route.
    public static func schema<T: Codable & Sendable>(for type: T.Type) throws -> JSONValue {
        if let providing = type as? any JSONSchemaProviding.Type {
            return providing.jsonSchema
        }
        if let sampleProviding = type as? any JSONSchemaSampleProviding.Type {
            return try schema(forMirrorOf: sampleProviding.jsonSchemaSample)
        }
        if let sample = try? defaultInstance(of: type) {
            return try schema(forMirrorOf: sample)
        }
        throw MojenticError.schema(
            message:
                "Cannot derive schema for \(type). Conform it to JSONSchemaProviding "
                + "or JSONSchemaSampleProviding."
        )
    }

    /// Generate a schema from a sample value supplied directly by the caller.
    ///
    /// Convenient when a type can't decode from `{}` (i.e. has required
    /// non-optional fields without Codable-visible defaults) but the caller
    /// can hand the generator a fully-populated instance.
    public static func schema(forSample sample: some Codable & Sendable) throws -> JSONValue {
        try schema(forMirrorOf: sample)
    }

    /// Generate a schema by reflecting a sample value.
    public static func schema(forMirrorOf instance: Any) throws -> JSONValue {
        let mirror = Mirror(reflecting: instance)
        guard mirror.displayStyle == .struct || mirror.displayStyle == .class else {
            return try schema(forValue: instance)
        }
        var properties: [String: JSONValue] = [:]
        var required: [JSONValue] = []
        for child in mirror.children {
            guard let label = child.label else { continue }
            let (childSchema, isRequired) = try fieldSchema(for: child.value)
            properties[label] = childSchema
            if isRequired {
                required.append(.string(label))
            }
        }
        return [
            "type": "object",
            "properties": .object(properties),
            "required": .array(required),
            "additionalProperties": false,
        ]
    }

    private static func fieldSchema(for value: Any) throws -> (JSONValue, Bool) {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            // Unwrap the optional one level.
            if let inner = mirror.children.first?.value {
                let unwrapped = try schema(forValue: inner)
                return (unwrapped, false)
            }
            // Optional carrying nil — we don't know the wrapped type from a
            // runtime nil, so emit a permissive any-type schema.
            return ([:], false)
        }
        let schema = try schema(forValue: value)
        return (schema, true)
    }

    private static func schema(forValue value: Any) throws -> JSONValue {
        switch value {
        case is String:
            return ["type": "string"]
        case is Bool:
            return ["type": "boolean"]
        case is Int, is Int32, is Int64, is UInt, is UInt32, is UInt64:
            return ["type": "integer"]
        case is Double, is Float:
            return ["type": "number"]
        default:
            break
        }
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .collection:
            if let first = mirror.children.first?.value {
                let itemSchema = try schema(forValue: first)
                return ["type": "array", "items": itemSchema]
            }
            return ["type": "array"]
        case .dictionary:
            return ["type": "object"]
        case .struct, .class:
            return try schema(forMirrorOf: value)
        case .enum:
            return ["type": "string"]
        case .optional:
            if let inner = mirror.children.first?.value {
                return try schema(forValue: inner)
            }
            return [:]
        default:
            return [:]
        }
    }

    private static func defaultInstance<T: Decodable>(of type: T.Type) throws -> T {
        // Try decoding from an empty object — this works for any struct whose
        // properties are all optional or have synthesised default Codable
        // behaviour with sentinel values. This is intentionally limited;
        // anything more complex should conform to JSONSchemaProviding.
        let emptyObject = Data("{}".utf8)
        return try JSONDecoder().decode(type, from: emptyObject)
    }
}

/// Opt-in protocol letting a type supply its own JSON Schema instead of
/// relying on `Mirror`-based inference.
public protocol JSONSchemaProviding {
    /// JSON Schema describing this type's encoded shape.
    static var jsonSchema: JSONValue { get }
}

/// Opt-in protocol letting a type supply a sample instance that
/// `JSONSchemaGenerator` reflects over via `Mirror`.
///
/// Use this when the type can't be decoded from an empty JSON object
/// (because of required non-optional fields) but you still want the schema
/// inferred automatically from a representative value.
public protocol JSONSchemaSampleProviding {
    /// Representative instance used to derive the schema.
    static var jsonSchemaSample: Self { get }
}
