import Foundation
import Testing

@testable import Mojentic

@Suite("JSONValue encoding and accessors")
struct JSONValueTests {
    @Test("round-trips primitive and nested values")
    func roundTrip() throws {
        let value: JSONValue = [
            "name": "alice",
            "age": 30,
            "tags": ["a", "b"],
            "active": true,
            "score": 1.5,
            "meta": .null,
        ]
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded.objectValue?["name"]?.stringValue == "alice")
        #expect(decoded.objectValue?["age"]?.intValue == 30)
    }

    @Test("decodes embedded floats as numbers")
    func decodeFloat() throws {
        let data = "{\"x\": 1.25}".data(using: .utf8) ?? Data()
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        if case .object(let dict) = decoded, case .number(let value) = dict["x"] ?? .null {
            #expect(value == 1.25)
        } else {
            Issue.record("Expected number")
        }
    }
}
