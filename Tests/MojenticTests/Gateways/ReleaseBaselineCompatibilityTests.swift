import Foundation
import Mojentic
import Testing

/// Public consumers compiled without defaults so enum additions cannot hide API drift.
struct ReleaseBaselineCompatibilityTests {
    private func legacyError(_ error: MojenticError) -> String {
        switch error {
        case .streamFailure: "timed"
        case .http, .transport, .decoding, .schema, .toolNotFound, .toolExecution: "legacy"
        case .toolDepthExceeded, .recursionDepthExceeded, .structuredDecoding, .cancelled: "legacy"
        case .invalidArgument, .incompleteCompletion, .incompleteStream, .unexpectedToolCalls: "legacy"
        case .providerError, .requestFailed, .invalidStreamEvent, .streamEventsUnsupported: "legacy"
        }
    }

    private func legacyGateway(_ event: GatewayStreamEvent) -> String {
        switch event {
        case .textDelta(let text), .thinkingDelta(let text): text
        case .toolCallRequest(let call): call.name
        case .done: "done"
        }
    }

    private func legacyCompletion(_ event: CompletionStreamEvent) -> String {
        switch event {
        case .content(let text): text
        case .completed: "completed"
        case .error(let error): legacyError(error)
        }
    }

    private func genericSchema<T: Codable & Sendable>(_ type: T.Type) throws -> JSONValue {
        let concreteType: T.Type = type
        return try JSONSchemaGenerator.schema(for: concreteType)
    }

    private func genericSubscription<E: Event>(
        _ router: Router, agent: any BaseAgent, event: E.Type,
    ) async {
        let concreteType: E.Type = event
        await router.subscribe(agent, to: concreteType)
    }

    @Test
    func exhaustiveConsumersAndGenericSchemaCompile() throws {
        #expect(legacyGateway(.textDelta("original")) == "original")
        #expect(legacyCompletion(.error(.cancelled)) == "legacy")
        #expect(try genericSchema(CompatibilitySchema.self) != .null)
    }

    @Test
    func genericSubscriptionRoutesTheConcreteType() async {
        let router = Router()
        let agent = CompatibilityAgent()
        await genericSubscription(router, agent: agent, event: TextEvent.self)
        let subscribers = await router.route(TextEvent(content: "original"))
        #expect(subscribers.count == 1)
        #expect(subscribers.first === agent)
    }

    @Test(arguments: [false, true], ["gateway", "completion", "broker"])
    func configuredRecoveryDoesNotChangeLegacyStreams(omlx: Bool, path: String) async throws {
        let server = try RecoveryLoopback(replies: [
            RecoveryReply(status: 503, body: "original-provider-body")
        ])
        let recorder = RecoveryRecorder()
        let gateway = RecoveryBoundary(omlx: omlx, structured: false).gateway(
            server, policy: recoveryPolicy(recorder),
        )
        if path == "gateway" {
            do {
                for try await event in gateway.stream(
                    model: "fixture", messages: [], tools: nil, config: .init(),
                ) {
                    Issue.record("Unexpected legacy event: \(legacyGateway(event))")
                }
                Issue.record("Expected original HTTP failure")
            } catch let error as MojenticError {
                let failure: StreamFailure
                guard case .streamFailure(let evidence) = error else {
                    Issue.record("Expected timed HTTP failure")
                    return
                }
                failure = evidence
                #expect(failure.evidence.metadata?["request_duration_ms"] != nil)
                #expect(failure.evidence.metadata?["first_token_kind"] == nil)
                guard case .http(let status, let body) = failure.cause as? MojenticError else {
                    Issue.record("Expected original HTTP error")
                    return
                }
                #expect(status == 503)
                #expect(body == "original-provider-body")
            }
        } else {
            let stream =
                if path == "broker" {
                    LLMBroker(gateway: gateway).generateStreamEvents(model: "fixture", messages: [])
                } else {
                    try gateway.completeStreamEvents(model: "fixture", messages: [], config: .init())
                }
            var seen = 0
            for await event in stream {
                seen += 1
                guard case .error(.streamFailure(let failure)) = event,
                    case .providerError(let status, let detail) = failure.cause as? MojenticError
                else {
                    Issue.record("Expected original provider failure: \(legacyCompletion(event))")
                    continue
                }
                #expect(status == 503)
                #expect(detail == .string("original-provider-body"))
            }
            #expect(seen == 1)
        }
        #expect(server.requests.withLock { $0.count } == 1)
        #expect(recorder.requests.withLock { $0.isEmpty })
        #expect(recorder.events.withLock { $0.isEmpty })
    }
}

private struct CompatibilitySchema: Codable, Sendable, JSONSchemaProviding {
    static var jsonSchema: JSONValue {
        ["type": "object"]
    }
}

private actor CompatibilityAgent: BaseAgent {
    func handle(_: any Event) async throws -> [any Event] {
        []
    }
}
