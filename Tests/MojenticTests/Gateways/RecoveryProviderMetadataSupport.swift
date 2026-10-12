import Foundation
@testable import Mojentic
import Testing

/// Exercises the real recovery APIs with nested schema values and escaped user text.
func invokeMetadataBoundary(_ boundary: RecoveryStatusBoundary, gateway: any LLMGateway) async throws {
    let messages: [LLMMessage] = [
        .user("payload-sentinel"), .user("escaped \"nested-sentinel\"\n猫"),
        .user(#"{"nested":["\u0064ecoded-sentinel"]}"#),
    ]
    let schema: JSONValue = ["type": "object", "properties": ["nested": ["enum": ["schema-sentinel"]]]]
    let config = CompletionConfig(temperature: 0.25, maxTokens: 123, topP: 0.8, reasoning: .high)
    switch boundary.operation {
    case .ordinary:
        _ = try await gateway.complete(
            model: "fixture", messages: messages, tools: [ResolveDateTool()], config: config,
        )
    case .structured:
        _ = try await gateway.completeStructured(
            model: "fixture", messages: messages, schema: schema, config: config,
        )
    case .json:
        _ = try await gateway.completeJSON(
            model: "fixture", messages: messages, schema: schema, config: config)
    case .tools:
        for try await _ in gateway.streamRecovering(
            model: "fixture", messages: messages, tools: [ResolveDateTool()], config: config,
        ) {}
    case .single:
        for await event in try gateway.completeStreamEventsRecovering(
            model: "fixture", messages: messages, config: config,
        ) {
            switch event {
            case .recoveryFailure(let error): throw error
            case .error(let error): throw error
            default: break
            }
        }
    }
}

func assertMetadataPayload(_ data: Data, boundary: RecoveryStatusBoundary) throws {
    let object = try #require(JSONDecoder().decode(JSONValue.self, from: data).objectValue)
    #expect(object["model"] == "fixture")
    #expect(object["stream"] == .bool([.tools, .single].contains(boundary.operation)))
    let messages = try #require(object["messages"])
    let encoded = try #require(String(data: JSONEncoder().encode(messages), encoding: .utf8))
    #expect(encoded.contains("payload-sentinel"))
    // Compare decoded content, not its escaped JSON representation.
    guard case .array(let values) = messages else {
        Issue.record("Expected outbound messages")
        return
    }
    let users = values.filter { $0.objectValue?["role"] == "user" }
    #expect(
        users == [
            ["role": "user", "content": "payload-sentinel"],
            ["role": "user", "content": "escaped \"nested-sentinel\"\n猫"],
            ["role": "user", "content": #"{"nested":["\u0064ecoded-sentinel"]}"#],
        ])
}

func metadataReply(code: String, requestID: String, anthropic: Bool) throws -> RecoveryReply {
    let body: JSONValue = ["error": .object([anthropic ? "type" : "code": .string(code)])]
    return try RecoveryReply(
        status: 503,
        headers: [anthropic ? "request-id" : "X-Request-ID": requestID, "X-Exact": "raw-évidence"],
        body: #require(String(data: JSONEncoder().encode(body), encoding: .utf8)),
    )
}

func assertExactMetadataHeaders(_ failure: RecoveryFailure, recorder: RecoveryRecorder) throws {
    let captured = recorder.wires.withLock { events in
        events.compactMap { event -> [String: String]? in
            if case .headers(let identity, _, let headers) = event, identity == failure.identity {
                return headers
            }
            return nil
        }
    }
    #expect(captured.count == 1)
    #expect(failure.inspectEvidence().headers == (try #require(captured.first)))
}
