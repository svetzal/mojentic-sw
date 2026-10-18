import Foundation
import Mojentic
import Testing

#if anthropic
    struct FirstTokenAnthropicTests {
        @Test(arguments: [false, true])
        func nativeLegacyAndRecoveryKinds(_ recovery: Bool) async throws {
            let boundary = StreamingBoundary(omlx: true, single: false, anthropic: true)
            for kind in ["thinking", "content", "empty"] {
                let server = try RecoveryLoopback(replies: [
                    RecoveryReply(
                        body: boundary.frame(
                            content: kind == "content" ? "answer" : "",
                            reasoning: kind == "thinking" ? "thought" : "",
                            done: true,
                            metrics: true))
                ])
                let result = try await firstTokenOutcome(
                    boundary,
                    gateway: boundary.gateway(server, recovery ? recoveryPolicy(RecoveryRecorder()) : nil),
                    recovering: recovery)
                try assertFirstToken(result, kind: kind == "empty" ? nil : kind, terminal: "done")
                #expect(result.evidence?.usage?.completionTokens == 12)
                #expect(result.evidence?.providerModel == "payload-sentinel")
                #expect(result.evidence?.finishReason == "end_turn")
            }
        }

        @Test(arguments: [false, true])
        func firstPartialJSONCountsBeforeToolAssembly(_ recovery: Bool) async throws {
            let prefix = """
                data: {"type":"message_start","message":{"id":"m","role":"assistant",\
                "model":"fixture","usage":{"input_tokens":3,"output_tokens":0}}}

                data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use",\
                "id":"t","name":"lookup","input":{}}}

                data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta",\
                "partial_json":"{"}}

                """ + "\n"
            let suffix = """
                data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta",\
                "partial_json":"}"}}

                data: {"type":"content_block_stop","index":0}

                data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":12}}

                data: {"type":"message_stop"}

                """ + "\n"
            let server = try RecoveryLoopback(replies: [
                RecoveryReply(body: prefix + suffix, splitAt: prefix.utf8.count, holdSuffix: true)
            ])
            defer { server.release() }
            let boundary = StreamingBoundary(omlx: true, single: false, anthropic: true)
            let task = Task {
                try await firstTokenOutcome(
                    boundary,
                    gateway: boundary.gateway(server, recovery ? recoveryPolicy(RecoveryRecorder()) : nil),
                    recovering: recovery)
            }
            var arrivals = server.arrivals.makeAsyncIterator()
            _ = await arrivals.next()
            try await Task.sleep(for: .milliseconds(200))
            server.releaseSuffix()
            let result = try await task.value
            try assertFirstToken(result, kind: "tool_call", terminal: "done")
            let first = try #require(timingNumber(result.evidence?.metadata?["time_to_first_token_ms"]))
            let duration = try #require(timingNumber(result.evidence?.metadata?["request_duration_ms"]))
            #expect(duration - first >= 150)
        }
    }
#endif
