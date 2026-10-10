import Foundation
@testable import Mojentic
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

struct RecoveryBoundary: Sendable, CustomStringConvertible {
    let omlx: Bool
    let structured: Bool
    var description: String {
        "\(omlx ? "omlx" : "ollama")/\(structured ? "structured" : "ordinary")"
    }

    static let all = [
        Self(omlx: false, structured: false), Self(omlx: false, structured: true),
        Self(omlx: true, structured: false), Self(omlx: true, structured: true),
    ]

    func gateway(
        _ server: RecoveryLoopback,
        policy: CompletionRecoveryPolicy?,
        idleTimeout: TimeInterval = 5,
    ) -> any LLMGateway {
        if omlx {
            return OMLXGateway(
                host: server.url,
                apiKey: "credential-sentinel",
                timeout: idleTimeout,
                recovery: policy,
            )
        }
        let session = URLSessionConfiguration.ephemeral
        session.timeoutIntervalForRequest = idleTimeout
        return OllamaGateway(
            baseURL: server.url,
            client: HTTPClient(session: URLSession(configuration: session)),
            headers: ["Authorization": "credential-sentinel"],
            recovery: policy,
        )
    }

    func complete(_ gateway: any LLMGateway) async throws -> LLMGatewayResponse {
        let config = CompletionConfig(temperature: 0.25, maxTokens: 123, topP: 0.8, reasoning: .high)
        if structured {
            return try await gateway.completeStructured(
                model: "fixture",
                messages: [.user("payload-sentinel")],
                schema: ["type": "object"],
                config: config,
            ).response
        }
        return try await gateway.complete(
            model: "fixture",
            messages: [.user("payload-sentinel")],
            tools: [ResolveDateTool()],
            config: config,
        )
    }

    func success(tools: Bool = false) throws -> RecoveryReply {
        let content = structured ? #"{"answer":42}"# : "recovered"
        var message: [String: JSONValue] = ["role": "assistant", "content": .string(content)]
        message[omlx ? "reasoning_content" : "thinking"] = "reasoning"
        if tools {
            let arguments: JSONValue = omlx ? .string(#"{"relative":"tomorrow"}"#) : ["relative": "tomorrow"]
            var call: [String: JSONValue] = [
                "id": "original-tool", "function": ["name": "resolve_date", "arguments": arguments],
            ]
            if omlx {
                call["type"] = "function"
            }
            message["tool_calls"] = .array([.object(call)])
        }
        let root: JSONValue =
            if omlx {
                [
                    "model": "served", "id": "payload-sentinel",
                    "choices": .array([
                        ["message": .object(message), "finish_reason": tools ? "tool_calls" : "stop"]
                    ]),
                    "usage": ["prompt_tokens": 3, "completion_tokens": 4, "total_tokens": 7],
                ]
            } else {
                [
                    "model": "served", "message": .object(message), "done": true, "done_reason": "stop",
                    "prompt_eval_count": 3, "eval_count": 4,
                ]
            }
        return try RecoveryReply(
            headers: [
                "Warning": "credential-sentinel payload-sentinel", "X-Request-ID": "credential-sentinel",
            ],
            body: #require(String(bytes: JSONEncoder().encode(root), encoding: .utf8)),
        )
    }
}

struct RecoveryCaptureSentinel: Error, Sendable, CustomStringConvertible {
    var description: String {
        "credential-sentinel payload-sentinel"
    }
}

func recoveryPolicy(_ recorder: RecoveryRecorder, attempts: Int = 2) -> CompletionRecoveryPolicy {
    var policy = CompletionRecoveryPolicy()
    policy.maximumAttempts = attempts
    policy.baseDelay = 0
    policy.admission = { _, _ in
        AsyncStream {
            $0.yield(.allow)
            $0.finish()
        }
    }
    policy.observer = { event in recorder.events.withLock { $0.append(event) } }
    policy.wireObserver = { event in
        recorder.wires.withLock { $0.append(event) }
        if case .request(let identity, _, _, let data) = event {
            recorder.requests.withLock { $0.append((identity, data)) }
        }
    }
    return policy
}

func recoveryFailure(_ action: () async throws -> Void) async throws -> RecoveryError {
    do { try await action() } catch let error as RecoveryError { return error }
    Issue.record("Expected structured recovery failure")
    throw MojenticError.invalidArgument(message: "Expected recovery failure")
}

/// The lock protects fixture state accessed by URLSession and test tasks.
final class RecoveryLocked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ action: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try action(&value)
    }
}
