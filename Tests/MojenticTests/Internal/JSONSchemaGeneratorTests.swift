import Foundation
import Testing

@testable import Mojentic

private struct PrimitiveBag: Codable, Sendable, JSONSchemaSampleProviding {
    var name: String
    var age: Int
    var active: Bool
    var rating: Double

    static var jsonSchemaSample: PrimitiveBag {
        PrimitiveBag(name: "", age: 0, active: false, rating: 0)
    }
}

private struct WithOptional: Codable, Sendable, JSONSchemaSampleProviding {
    var name: String
    var note: String?

    static var jsonSchemaSample: WithOptional {
        WithOptional(name: "", note: "hint")
    }
}

private struct WithArray: Codable, Sendable, JSONSchemaSampleProviding {
    var tags: [String]

    static var jsonSchemaSample: WithArray {
        WithArray(tags: ["sample"])
    }
}

private struct Nested: Codable, Sendable, JSONSchemaSampleProviding {
    var inner: PrimitiveBag

    static var jsonSchemaSample: Nested {
        Nested(inner: PrimitiveBag.jsonSchemaSample)
    }
}

private struct CustomShape: Codable, Sendable, JSONSchemaProviding {
    static var jsonSchema: JSONValue {
        ["type": "object", "properties": ["custom": ["type": "string"]]]
    }
}

@Suite("JSONSchemaGenerator")
struct JSONSchemaGeneratorTests {
    @Test("derives a schema for a struct with primitive fields")
    func primitives() throws {
        let schema = try JSONSchemaGenerator.schema(for: PrimitiveBag.self)
        let object = schema.objectValue
        #expect(object?["type"]?.stringValue == "object")
        let properties = object?["properties"]?.objectValue
        #expect(properties?["name"]?.objectValue?["type"]?.stringValue == "string")
        #expect(properties?["age"]?.objectValue?["type"]?.stringValue == "integer")
        #expect(properties?["active"]?.objectValue?["type"]?.stringValue == "boolean")
        #expect(properties?["rating"]?.objectValue?["type"]?.stringValue == "number")
    }

    @Test("marks optional fields as not required")
    func optionals() throws {
        let schema = try JSONSchemaGenerator.schema(for: WithOptional.self)
        guard case .array(let required) = schema.objectValue?["required"] ?? .null else {
            Issue.record("Expected required array")
            return
        }
        let names = required.compactMap(\.stringValue)
        #expect(names.contains("name"))
        #expect(!names.contains("note"))
    }

    @Test("describes arrays of strings with item schema")
    func arrays() throws {
        let schema = try JSONSchemaGenerator.schema(for: WithArray.self)
        let tagSchema = schema.objectValue?["properties"]?.objectValue?["tags"]?.objectValue
        #expect(tagSchema?["type"]?.stringValue == "array")
        #expect(tagSchema?["items"]?.objectValue?["type"]?.stringValue == "string")
    }

    @Test("recursively describes nested structs")
    func nested() throws {
        let schema = try JSONSchemaGenerator.schema(for: Nested.self)
        let innerSchema = schema.objectValue?["properties"]?.objectValue?["inner"]?.objectValue
        #expect(innerSchema?["type"]?.stringValue == "object")
        let innerProps = innerSchema?["properties"]?.objectValue
        #expect(innerProps?["name"]?.objectValue?["type"]?.stringValue == "string")
    }

    @Test("JSONSchemaProviding short-circuits Mirror inference")
    func customSchema() throws {
        let schema = try JSONSchemaGenerator.schema(for: CustomShape.self)
        let properties = schema.objectValue?["properties"]?.objectValue
        #expect(properties?["custom"]?.objectValue?["type"]?.stringValue == "string")
    }
}
