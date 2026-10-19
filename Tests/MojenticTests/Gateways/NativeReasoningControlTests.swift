import Foundation
import Mojentic
import Testing

@Suite(.serialized)
struct NativeReasoningControlTests {
    @Test(arguments: [false, true], RecoveryStatusBoundary.Operation.allCases)
    func exactContractControlsAcrossPublicBoundaries(
        omlx: Bool, operation: RecoveryStatusBoundary.Operation
    ) async throws {
        let contract = try NativeReasoningContract()
        for row in contract.controls {
            for recovering in [false, true] {
                let stream = operation == .tools || operation == .single
                let structured = operation == .structured || operation == .json
                let success = try contract.reply(
                    omlx: omlx,
                    stream: stream,
                    structured: structured)
                let server = try InProcessHTTPFixture(
                    replies: recovering
                        ? [RecoveryReply(status: 503, body: "retry"), success] : [success])
                let gateway = RecoveryBoundary(
                    omlx: omlx,
                    structured: false
                ).gateway(
                    server,
                    policy: recovering ? recoveryPolicy(RecoveryRecorder()) : nil
                )
                let effort = row.objectValue?["effort"]?.stringValue.flatMap(ReasoningEffort.init(rawValue:))
                let config = CompletionConfig(reasoning: effort)
                switch operation {
                case .ordinary:
                    let response = try await gateway.complete(
                        model: "unrecognized",
                        messages: [.user("go")],
                        tools: nil,
                        config: config)
                    #expect(response.content == contract.fields["answer"]?.stringValue)
                    #expect(response.thinking == contract.fields["reasoning"]?.stringValue)
                case .structured:
                    let result = try await gateway.completeStructured(
                        model: "unrecognized",
                        messages: [.user("go")],
                        schema: ["type": "object"],
                        config: config)
                    #expect(result.value == ["answer": 7])
                    #expect(result.response.thinking == contract.fields["reasoning"]?.stringValue)
                case .json:
                    let value = try await gateway.completeJSON(
                        model: "unrecognized",
                        messages: [.user("go")],
                        schema: ["type": "object"],
                        config: config)
                    #expect(value == ["answer": 7])
                case .tools:
                    var thinking = ""
                    for try await event in gateway.streamRecovering(
                        model: "unrecognized",
                        messages: [.user("go")],
                        tools: nil,
                        config: config)
                    {
                        if case .thinkingDelta(let delta) = event { thinking += delta }
                    }
                    #expect(thinking == contract.fields["reasoning"]?.stringValue)
                case .single:
                    var content = ""
                    for await event in try gateway.completeStreamEventsRecovering(
                        model: "unrecognized",
                        messages: [.user("go")],
                        config: config)
                    {
                        switch event {
                        case .content(let delta): content += delta
                        case .error(let error): throw error
                        case .recoveryFailure(let error): throw error
                        default: break
                        }
                    }
                    #expect(content == contract.fields["answer"]?.stringValue)
                }
                try contract.assertControls(
                    server,
                    omlx: omlx,
                    row: row)
                #expect(server.requests.withLock { $0.count } == (recovering ? 2 : 1))
            }
        }
    }

    @Test(arguments: RecoveryBoundary.all.filter { !$0.structured })
    func rejectsUnsupportedControlsBeforeDispatch(_ boundary: RecoveryBoundary) async throws {
        let server = try InProcessHTTPFixture(replies: [])
        let gateway = boundary.gateway(
            server,
            policy: recoveryPolicy(RecoveryRecorder()))
        let configs: [CompletionConfig] =
            boundary.openAI || boundary.anthropic
            ? [
                .init(reasoning: .disabled), .init(reasoning: .enabled), .init(reasoning: .xhigh),
                .init(retainThinking: true), .init(reasoningProfile: .qwen38),
            ]
            : [
                .init(
                    reasoning: .high,
                    reasoningProfile: .qwen38),
                .init(
                    reasoning: .enabled,
                    reasoningProfile: .qwen38),
                .init(
                    reasoningProfile: .init(
                        supportedEfforts: [.enabled],
                        supportsHistory: false),
                    retainThinking: true),
            ]
        for config in configs {
            await #expect(throws: MojenticError.self) {
                _ = try await gateway.complete(
                    model: "Qwen3.8",
                    messages: [.user("go")],
                    tools: nil,
                    config: config)
            }
            await #expect(throws: MojenticError.self) {
                _ = try await gateway.completeStructured(
                    model: "fixture",
                    messages: [.user("go")],
                    schema: [:],
                    config: config)
            }
            await #expect(throws: MojenticError.self) {
                for try await _ in gateway.streamRecovering(
                    model: "fixture",
                    messages: [.user("go")],
                    tools: nil,
                    config: config)
                {}
            }
            var rejected = false
            for await event in try gateway.completeStreamEventsRecovering(
                model: "fixture",
                messages: [.user("go")],
                config: config)
            {
                if case .error = event { rejected = true }
            }
            #expect(rejected)
        }
        #expect(server.requests.withLock { $0.isEmpty })
    }

    @Test(arguments: [false, true])
    func explicitProfileAcceptsUnknownDefaultAndExactQwenEfforts(omlx: Bool) async throws {
        let contract = try NativeReasoningContract()
        for effort: ReasoningEffort? in [nil, .disabled, .low, .medium, .xhigh] {
            let server = try InProcessHTTPFixture(replies: [
                contract.reply(
                    omlx: omlx,
                    stream: false)
            ])
            let gateway = RecoveryBoundary(
                omlx: omlx,
                structured: false
            ).gateway(
                server,
                policy: nil)
            _ = try await gateway.complete(
                model: "arbitrary-name",
                messages: [.user("go")],
                tools: nil,
                config: .init(
                    reasoning: effort,
                    reasoningProfile: .qwen38,
                    retainThinking: true))
            let row = try #require(
                contract.controls.first {
                    $0.objectValue?["effort"] == effort.map { .string($0.rawValue) } ?? .null
                })
            try contract.assertControls(
                server,
                omlx: omlx,
                row: row,
                retain: true)
        }
    }
}
