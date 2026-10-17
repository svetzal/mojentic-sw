import Foundation
@testable import Mojentic
import Testing

struct ContextWindowContract {
    let fields: [String: JSONValue]

    init() throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "context_window_v1", withExtension: "json", subdirectory: "Fixtures/Contracts"))
        fields = try #require(JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url)).objectValue)
        #expect(fields["version"] == "context-window-v1")
    }

    func rows(_ key: String) throws -> [[String: JSONValue]] {
        guard case .array(let values) = fields[key] else {
            throw MojenticError.decoding(message: "Missing contract rows: \(key)")
        }
        return try values.map { try #require($0.objectValue) }
    }

    static func window(_ value: JSONValue?) throws -> ModelContextWindow? {
        guard let value, value != .null else { return nil }
        let object = try #require(value.objectValue)
        return try ModelContextWindow(
            maxContextTokens: #require(object["max_context_tokens"]?.intValue),
            field: #require(object["field"]?.stringValue),
            modelNumCtx: object["model_num_ctx"]?.intValue)
    }

    static func gateway(
        _ provider: String, server: RecoveryLoopback, authenticated: Bool = true
    ) -> any LLMGateway {
        switch provider {
        case "ollama":
            OllamaGateway(baseURL: server.url, headers: ["X-Contract": "configured"])
        case "omlx":
            OMLXGateway(host: server.url, apiKey: authenticated ? "contract-secret" : "")
        default:
            OpenAIGateway(apiKey: "contract-secret", baseURL: server.url.appendingPathComponent("v1"))
        }
    }
}

struct ContextWindowRow: Sendable, CustomTestStringConvertible {
    let fields: [String: JSONValue]
    var testDescription: String {
        "\(fields["provider"]?.stringValue ?? "")/\(fields["name"]?.stringValue ?? "")"
    }

    static func all() throws -> [Self] {
        try ContextWindowContract().rows("cases").map { Self(fields: $0) }
    }
}
