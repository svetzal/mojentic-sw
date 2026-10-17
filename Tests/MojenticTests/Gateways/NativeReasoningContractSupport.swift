import Foundation
import Mojentic
import Testing

/// Responses and expectations share the unchanged cross-port executable contract.
struct NativeReasoningContract {
    let fields: [String: JSONValue]

    init() throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "native_reasoning_v1", withExtension: "json", subdirectory: "Fixtures/Contracts"
            ))
        fields = try #require(JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url)).objectValue)
        #expect(fields["version"] == "native-reasoning-v1")
    }

    var controls: [JSONValue] {
        guard case .array(let values) = fields["controls"] else { return [] }
        return values
    }

    func reply(
        omlx: Bool,
        stream: Bool,
        tools: Bool = false,
        structured: Bool = false
    ) throws -> RecoveryReply {
        var message: [String: JSONValue] = [
            "role": "assistant", "content": fields[tools ? "visible" : "answer"] ?? .null,
            omlx ? "reasoning_content" : "thinking": fields["reasoning"] ?? .null,
        ]
        if structured { message["content"] = .string(#"{"answer":7}"#) }
        if tools {
            var call = try #require(fields["tool_call"]?.objectValue)
            var function = try #require(call["function"]?.objectValue)
            if !omlx {
                function["arguments"] = try JSONDecoder().decode(
                    JSONValue.self, from: Data(#require(function["arguments"]?.stringValue).utf8)
                )
            }
            call["function"] = .object(function)
            var second = call
            second["id"] = "call-native-2"
            if stream {
                call["index"] = 0
                second["index"] = 1
            }
            message["tool_calls"] = [.object(call), .object(second)]
        }
        let reason = tools ? "tool_calls" : "stop"
        let root: JSONValue =
            omlx
            ? [
                "choices": [
                    [stream ? "delta" : "message": .object(message), "finish_reason": .string(reason)]
                ]
            ]
            : ["message": .object(message), "done": true, "done_reason": "stop"]
        let json = try #require(String(data: JSONEncoder().encode(root), encoding: .utf8))
        let body = stream ? (omlx ? "data: \(json)\n\ndata: [DONE]\n\n" : json + "\n") : json
        return RecoveryReply(status: 200, body: body)
    }

    func assertControls(
        _ server: RecoveryLoopback,
        omlx: Bool,
        row: JSONValue,
        retain: Bool = false
    ) throws {
        let expected = try #require(row.objectValue?[omlx ? "omlx" : "ollama"]?.objectValue)
        for bytes in server.requests.withLock({ $0 }) {
            let body = try #require(JSONDecoder().decode(JSONValue.self, from: bytes).objectValue)
            if omlx {
                #expect(body["reasoning_effort"] == expected["reasoning_effort"])
                #expect(
                    body["chat_template_kwargs"]?.objectValue?["enable_thinking"]
                        == expected["enable_thinking"])
                #expect(
                    body["chat_template_kwargs"]?.objectValue?["preserve_thinking"] == (retain ? true : nil))
                #expect(body["think"] == nil)
            } else {
                #expect(body["think"] == expected["think"])
                #expect(body["reasoning_effort"] == nil)
                #expect(body["chat_template_kwargs"] == nil)
            }
        }
    }
}

struct ContractCountTool: LLMTool {
    let result: JSONValue
    let descriptor = ToolDescriptor(
        name: "count",
        description: "count",
        parameters: ["type": "object"])
    func execute(arguments: JSONValue) async throws -> JSONValue {
        #expect(arguments == ["value": 7])
        return result
    }
}
