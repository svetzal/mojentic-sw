import Foundation
import Testing

@testable import Mojentic

struct StreamingBoundary: Sendable, CustomStringConvertible {
    let omlx: Bool
    let single: Bool
    var description: String { "\(omlx ? "omlx" : "ollama")/\(single ? "single" : "tools")" }
    static let all = [
        Self(omlx: false, single: false), Self(omlx: true, single: false),
        Self(omlx: false, single: true), Self(omlx: true, single: true),
    ]

    func gateway(_ server: RecoveryLoopback, _ policy: CompletionRecoveryPolicy?) -> any LLMGateway {
        RecoveryBoundary(omlx: omlx, structured: false).gateway(server, policy: policy)
    }

    func frame(
        content: String = "",
        reasoning: String = "",
        tool: Bool = false,
        done: Bool = false,
        reason: String = "stop",
        metrics: Bool = false
    ) throws -> String {
        var message: [String: JSONValue] = ["content": .string(content)]
        if !reasoning.isEmpty { message[omlx ? "reasoning_content" : "thinking"] = .string(reasoning) }
        if tool {
            if omlx {
                message["tool_calls"] = [
                    [
                        "index": 0, "id": "original-tool",
                        "function": ["name": "resolve_date", "arguments": #"{"relative":"tomorrow"}"#],
                    ]
                ]
            } else {
                message["tool_calls"] = [
                    [
                        "id": "original-tool",
                        "function": ["name": "resolve_date", "arguments": ["relative": "tomorrow"]],
                    ]
                ]
            }
        }
        var root: [String: JSONValue]
        if omlx {
            var choice: [String: JSONValue] = ["delta": .object(message)]
            if done { choice["finish_reason"] = .string(tool ? "tool_calls" : reason) }
            root = [
                "choices": .array([.object(choice)]), "model": "payload-sentinel",
                "id": "credential-sentinel",
            ]
            if metrics { root["usage"] = ["prompt_tokens": 3, "completion_tokens": 12, "total_tokens": 15] }
        } else {
            root = ["message": .object(message), "done": .bool(done), "model": "payload-sentinel"]
            if done { root["done_reason"] = .string(reason) }
            if metrics {
                root["prompt_eval_count"] = 3
                root["eval_count"] = 12
                root["eval_duration"] = 6_000_000_000
                root["created_at"] = "credential-sentinel"
            }
        }
        let encoded = try #require(
            String(data: JSONEncoder().encode(JSONValue.object(root)), encoding: .utf8))
        return omlx ? "data: \(encoded)\n\n" + (done ? "data: [DONE]\n\n" : "") : encoded + "\n"
    }

    func consume(_ gateway: any LLMGateway, record: RecoveryLocked<[String]>? = nil) async throws {
        if single {
            for await event in try gateway.completeStreamEvents(
                model: "fixture", messages: [.user("payload-sentinel")], config: .init()
            ) {
                switch event {
                case .content(let text): record?.withLock { $0.append("content:\(text)") }
                case .progress: record?.withLock { $0.append("progress") }
                case .metrics: record?.withLock { $0.append("metrics") }
                case .completed: record?.withLock { $0.append("completed") }
                case .error(.recovery(let error)): throw error
                case .error(let error): throw error
                }
            }
        } else {
            for try await event in gateway.stream(
                model: "fixture", messages: [.user("payload-sentinel")], tools: nil, config: .init()
            ) {
                switch event {
                case .textDelta(let text): record?.withLock { $0.append("content:\(text)") }
                case .thinkingDelta(let text): record?.withLock { $0.append("reasoning:\(text)") }
                case .toolCallRequest: record?.withLock { $0.append("tool") }
                case .progress: record?.withLock { $0.append("progress") }
                case .metrics: record?.withLock { $0.append("metrics") }
                case .done: record?.withLock { $0.append("completed") }
                }
            }
        }
    }
}
