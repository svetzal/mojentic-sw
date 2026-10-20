import Foundation
@testable import Mojentic
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

struct RecoveryBoundary: Sendable, CustomStringConvertible {
    let omlx: Bool
    let structured: Bool
    var openAI = false
    var anthropic = false
    var description: String {
        let provider = anthropic ? "anthropic" : openAI ? "openai" : omlx ? "omlx" : "ollama"
        return "\(provider)/\(structured ? "structured" : "ordinary")"
    }

    static var all: [Self] {
        var boundaries = [
            Self(omlx: false, structured: false), Self(omlx: false, structured: true),
            Self(omlx: true, structured: false), Self(omlx: true, structured: true),
            Self(omlx: true, structured: false, openAI: true),
            Self(omlx: true, structured: true, openAI: true),
        ]
        #if anthropic
            boundaries += [
                Self(omlx: true, structured: false, anthropic: true),
                Self(omlx: true, structured: true, anthropic: true),
            ]
        #endif
        return boundaries
    }

    func gateway(
        _ server: InProcessHTTPFixture,
        policy: CompletionRecoveryPolicy?,
        idleTimeout: TimeInterval = 5,
    ) -> any LLMGateway {
        server.trace.record("test", "\(Test.current?.name ?? "unknown")/\(description)")
        let policy = policy.map { server.isolated(reportingDeliveries(to: server, $0)) }
        #if anthropic
            if anthropic {
                if let policy {
                    return AnthropicGateway(
                        apiKey: "credential-sentinel",
                        baseURL: server.url,
                        client: server.client,
                        recovery: policy,
                    )
                }
                return AnthropicGateway(
                    apiKey: "credential-sentinel",
                    baseURL: server.url,
                    client: server.client,
                    lineTransport: server,
                )
            }
        #endif
        if openAI {
            if let policy {
                return OpenAIGateway(
                    apiKey: "credential-sentinel",
                    baseURL: server.url,
                    client: server.client,
                    recovery: policy,
                )
            }
            return OpenAIGateway(
                apiKey: "credential-sentinel",
                baseURL: server.url,
                client: server.client,
                lineTransport: server,
            )
        }
        if omlx {
            if let policy {
                return OMLXGateway(
                    host: server.url,
                    apiKey: "credential-sentinel",
                    timeout: idleTimeout,
                    session: server.session,
                    recovery: policy,
                )
            }
            let configuration = OMLXConfiguration(
                host: server.url, apiKey: "credential-sentinel", timeout: idleTimeout)
            return OMLXGateway(configuration: configuration, transport: server.client, lineTransport: server)
        }
        if let policy {
            return OllamaGateway(
                baseURL: server.url,
                client: server.client,
                headers: ["Authorization": "credential-sentinel"],
                recovery: policy,
            )
        }
        return OllamaGateway(
            baseURL: server.url,
            client: server.client,
            headers: ["Authorization": "credential-sentinel"],
            lineTransport: server,
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
        if anthropic {
            var blocks: [JSONValue] = [
                ["type": "text", "text": .string(content)],
                ["type": "thinking", "thinking": "reasoning", "signature": "unsupported-history"],
            ]
            if tools {
                blocks.append([
                    "type": "tool_use",
                    "id": "original-tool",
                    "name": "resolve_date",
                    "input": ["relative": "tomorrow"],
                ])
            }
            let root: JSONValue = [
                "model": "served",
                "id": "payload-sentinel",
                "content": .array(blocks),
                "stop_reason": tools ? "tool_use" : "end_turn",
                "usage": ["input_tokens": 3, "output_tokens": 4],
            ]
            return try RecoveryReply(
                headers: ["X-Request-ID": "credential-sentinel"],
                body: #require(String(data: JSONEncoder().encode(root), encoding: .utf8)),
            )
        }
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
    policy.timing = deterministicRecoveryTiming()
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

/// Reports received body bytes to the in-process boundary after the caller's wire observer, even when it throws.
private func reportingDeliveries(
    to server: InProcessHTTPFixture,
    _ policy: CompletionRecoveryPolicy,
) -> CompletionRecoveryPolicy {
    var policy = policy
    let observe = policy.wireObserver
    let lifecycle = policy.observer
    let report = policy.reportObserver
    let trace = server.trace
    trace.attach(to: &policy)
    policy.observer = { event in
        trace.lifecycle(event)
        lifecycle?(event)
    }
    policy.reportObserver = { value in
        trace.report(value)
        report?(value)
    }
    server.expectDeliveryReports()
    policy.wireObserver = { event in
        trace.wire(event)
        if case .body(_, let data) = event {
            defer { server.reportDelivery(data.count) }
            try observe?(event)
        } else {
            try observe?(event)
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
    private var waiters: [(@Sendable (Value) -> Bool, CheckedContinuation<Void, Never>)] = []
    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ action: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer {
            let ready = waiters.filter { $0.0(value) }.map(\.1)
            waiters.removeAll { $0.0(value) }
            lock.unlock()
            ready.forEach { $0.resume() }
        }
        return try action(&value)
    }

    /// Observe the state transition itself instead of polling a scheduler.
    func wait(until predicate: @escaping @Sendable (Value) -> Bool) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if predicate(value) {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append((predicate, continuation))
                lock.unlock()
            }
        }
    }
}

/// Terminal evidence preserves provider fields without borrowing metric attribution.
func assertTerminalProviderEvidence(_ terminal: CompletionEvidence, reported: CompletionEvidence) {
    #expect(terminal.finishReason == reported.finishReason)
    #expect(terminal.usage == reported.usage)
    #expect(terminal.providerModel == reported.providerModel)
    #expect(providerEvidence(terminal).metadata == reported.metadata)
    #expect(terminal.identity == nil)
    #expect(terminal.frameIndex == nil)
}
