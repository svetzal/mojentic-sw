import Foundation
import Mojentic
import Testing

let historyThinking = "reasoning é猫\nexact"

func reasoningHistory(populated: Bool) -> [LLMMessage] {
    let call = LLMToolCall(id: "history-call", name: "resolve_date", arguments: ["relative": "tomorrow"])
    let assistant: LLMMessage =
        if populated {
            .assistant("original content", toolCalls: [call], thinking: historyThinking)
        } else {
            .assistant("original content", toolCalls: [call])
        }
    return [
        LLMMessage(role: .user, content: "original user", thinking: populated ? "omit user" : nil),
        assistant,
        LLMMessage(
            role: .tool,
            content: "original result",
            toolCallId: "history-call",
            thinking: populated ? "omit tool" : nil,
        ),
        .user("continue"),
    ]
}

func reasoningReply(_ boundary: RecoveryStatusBoundary) throws -> RecoveryReply {
    if boundary.operation == .tools || boundary.operation == .single {
        let stream = StreamingBoundary(
            omlx: boundary.provider.omlx,
            single: boundary.operation == .single,
            openAI: boundary.provider.openAI,
            anthropic: boundary.provider.anthropic,
        )
        return try RecoveryReply(body: stream.frame(content: "recovered", done: true))
    }
    return try boundary.buffered.success()
}

/// Invoke public completion APIs with caller-owned history, bypassing broker/session history policy.
func invokeReasoningHistory(
    _ boundary: RecoveryStatusBoundary, gateway: any LLMGateway, messages: [LLMMessage], legacy: Bool = false,
) async throws {
    switch boundary.operation {
    case .ordinary:
        let result = try await gateway.complete(
            model: "fixture", messages: messages, tools: [ResolveDateTool()], config: .init(),
        )
        #expect(result.content == "recovered")
    case .structured:
        let result = try await gateway.completeStructured(
            model: "fixture", messages: messages, schema: ["type": "object"], config: .init(),
        )
        #expect(result.value == ["answer": 42])
    case .json:
        let result = try await gateway.completeJSON(
            model: "fixture", messages: messages, schema: ["type": "object"], config: .init(),
        )
        #expect(result == ["answer": 42])
    case .tools:
        var content = ""
        if legacy {
            for try await event in gateway.stream(
                model: "fixture", messages: messages, tools: [ResolveDateTool()], config: .init(),
            ) {
                if case .textDelta(let text) = event {
                    content += text
                }
            }
        } else {
            for try await event in gateway.streamRecovering(
                model: "fixture", messages: messages, tools: [ResolveDateTool()], config: .init(),
            ) {
                if case .textDelta(let text) = event {
                    content += text
                }
            }
        }
        #expect(content == "recovered")
    case .single:
        var content = ""
        if legacy {
            for await event in try gateway.completeStreamEvents(
                model: "fixture", messages: messages, config: .init(),
            ) {
                switch event {
                case .content(let text): content += text
                case .error(let error): throw error
                case .completed: break
                }
            }
        } else {
            for await event in try gateway.completeStreamEventsRecovering(
                model: "fixture", messages: messages, config: .init(),
            ) {
                switch event {
                case .content(let text): content += text
                case .error(let error): throw error
                case .recoveryFailure(let error): throw error
                default: break
                }
            }
        }
        #expect(content == "recovered")
    }
}

/// Decode only actual socket bytes and compare the complete native history, independently of adapters.
func assertReasoningSocketHistory(
    _ server: RecoveryLoopback, provider: RecoveryBoundary, populated: Bool,
) throws {
    let expected: [JSONValue]
    if provider.anthropic {
        expected = [
            ["role": "user", "content": "original user"],
            [
                "role": "assistant",
                "content": [
                    ["type": "text", "text": "original content"],
                    [
                        "type": "tool_use", "id": "history-call", "name": "resolve_date",
                        "input": ["relative": "tomorrow"],
                    ],
                ],
            ],
            [
                "role": "user",
                "content": [
                    ["type": "tool_result", "tool_use_id": "history-call", "content": "original result"]
                ],
            ],
            ["role": "user", "content": "continue"],
        ]
    } else {
        let arguments: JSONValue =
            provider.omlx ? .string(#"{"relative":"tomorrow"}"#) : ["relative": "tomorrow"]
        var call: [String: JSONValue] = [
            "type": "function", "function": ["name": "resolve_date", "arguments": arguments],
        ]
        if provider.omlx {
            call["id"] = "history-call"
            call["type"] = "function"
        }
        var assistant: [String: JSONValue] = [
            "role": "assistant", "content": "original content", "tool_calls": [.object(call)],
        ]
        if populated, !provider.openAI {
            assistant[provider.omlx ? "reasoning_content" : "thinking"] = .string(historyThinking)
        }
        var tool: [String: JSONValue] = ["role": "tool", "content": "original result"]
        if provider.omlx {
            tool["tool_call_id"] = "history-call"
        }
        expected = [
            ["role": "user", "content": "original user"], .object(assistant), .object(tool),
            ["role": "user", "content": "continue"],
        ]
    }
    for bytes in server.requests.withLock({ $0 }) {
        let root = try JSONDecoder().decode(JSONValue.self, from: bytes)
        #expect(root.objectValue?["messages"] == .array(expected))
    }
}
