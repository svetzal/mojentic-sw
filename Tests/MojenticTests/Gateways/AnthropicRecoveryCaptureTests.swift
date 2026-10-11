import Foundation
@testable import Mojentic
import Testing

#if anthropic
    struct AnthropicRecoveryCaptureTests {
        @Test(arguments: ["buffered", "structured", "tools", "single"], [false, true])
        func captureAndCancellationRetainExactObservedEvidence(_ path: String, _ cancel: Bool) async throws {
            let streamed = path == "tools" || path == "single"
            let tool = path != "single"
            let body: String =
                if streamed {
                    try StreamingBoundary(omlx: true, single: !tool, anthropic: true).frame(
                        content: "é", reasoning: "思", tool: tool, done: true, metrics: true,
                    )
                } else {
                    #"""
                    {"id":"credential-sentinel","model":"payload-sentinel","content":[
                    {"type":"thinking","thinking":"思"},{"type":"text","text":"é"},
                    {"type":"tool_use","id":"t","name":"resolve_date","input":{}}],
                    "stop_reason":"tool_use","usage":{"input_tokens":3,"output_tokens":12}}
                    """#
                }
            let server = try RecoveryLoopback(replies: [RecoveryReply(body: body)])
            let recorder = RecoveryRecorder()
            let handle = RecoveryLocked<Task<Void, any Error>?>(nil)
            let start = AsyncStream<Void>.makeStream()
            let seen = RecoveryLocked<[String]>([])
            var policy = recoveryPolicy(recorder)
            let capture = policy.wireObserver
            policy.wireObserver = { event in
                try capture?(event)
                if case .body = event {
                    if cancel {
                        handle.withLock { $0?.cancel() }
                    }
                    throw RecoveryCaptureSentinel()
                }
            }
            let gateway = AnthropicGateway(
                apiKey: "credential-sentinel", baseURL: server.url, recovery: policy,
            )
            let task = Task {
                var signal = start.stream.makeAsyncIterator()
                _ = await signal.next()
                if streamed {
                    try await StreamingBoundary(omlx: true, single: !tool, anthropic: true).consume(
                        gateway, record: seen,
                    )
                } else if path == "structured" {
                    _ = try await gateway.completeStructured(
                        model: "fixture",
                        messages: [.user("payload-sentinel")],
                        schema: ["type": "object"],
                        config: .init(),
                    )
                } else {
                    _ = try await gateway.complete(
                        model: "fixture",
                        messages: [.user("payload-sentinel")],
                        tools: nil,
                        config: .init(),
                    )
                }
            }
            handle.withLock { $0 = task }
            start.continuation.yield(())
            start.continuation.finish()
            let error = try await recoveryFailure { try await task.value }
            #expect(error.outcome == (cancel ? .cancelled : .captureFailed))
            #expect(error.history.count == 1)
            let failed = try #require(error.history.first)
            #expect(failed.status == 200)
            #expect(failed.progress.headersReceived)
            #expect(failed.progress.rawBytes == body.utf8.count)
            #expect(failed.progress.observed.contentBytes == 2)
            #expect(failed.progress.observed.reasoningBytes == 3)
            #expect(failed.progress.observed.toolFragments == (tool ? 1 : 0))
            #expect(failed.progress.observed.completedToolCalls == (tool ? 1 : 0))
            #expect(failed.progress.delivered == RecoverySemanticProgress())
            #expect(failed.inspectEvidence().cause is RecoveryCaptureSentinel)
            #expect(failed.inspectEvidence().body == Data(body.utf8))
            #expect(failed.category == (cancel ? .cancellation : .capture))
            #expect(seen.withLock { $0.isEmpty })
            #expect(
                recorder.events.withLock { $0.map(\.transition) } == [
                    .attemptStarted, .attemptFailed, error.outcome,
                ]
            )
            #expect(error.failure.identity == failed.identity)
            #expect(error.failure.identity == recorder.requests.withLock { $0.first?.0 })
            #expect(!String(describing: error).contains("sentinel"))
            #expect(!String(reflecting: error).contains("sentinel"))
            let safeEvents = try JSONEncoder().encode(recorder.events.withLock { $0 })
            #expect(!(String(data: safeEvents, encoding: .utf8) ?? "").contains("sentinel"))
            assertRecoveryRequests(recorder, server)
        }

        @Test(arguments: [false, true])
        func partialToolArgumentsInterruptWithoutDelivery(_ single: Bool) async throws {
            let boundary = StreamingBoundary(omlx: true, single: single, anthropic: true)
            let initial = try boundary.frame(tool: true)
            let partial = #"""
                {"type":"content_block_delta","index":0,\#
                "delta":{"type":"input_json_delta","partial_json":"{\"relative\":"}}
                """#
            let delta = "event: content_block_delta\ndata: \(partial)\n\n"
            let body = initial + delta
            let server = try RecoveryLoopback(replies: [RecoveryReply(body: body, truncated: true)])
            let recorder = RecoveryRecorder()
            let seen = RecoveryLocked<[String]>([])
            let error = try await recoveryFailure {
                try await boundary.consume(boundary.gateway(server, recoveryPolicy(recorder)), record: seen)
            }
            #expect(error.outcome == .interrupted)
            #expect(error.failure.progress.observed.toolFragments == (single ? 1 : 2))
            #expect(error.failure.progress.observed.completedToolCalls == 0)
            #expect(error.failure.progress.delivered == RecoverySemanticProgress())
            #expect(error.failure.inspectEvidence().body == Data(body.utf8))
            if single {
                guard case .unexpectedToolCalls? = error.failure.inspectEvidence().cause as? MojenticError
                else {
                    Issue.record("Missing original single-turn tool rejection")
                    return
                }
            } else {
                #expect(error.failure.inspectEvidence().cause is URLError)
            }
            #expect(seen.withLock { $0 } == ["metrics"])
            #expect(error.history.count == 1)
            #expect(
                recorder.events.withLock { $0.map(\.transition) } == [
                    .attemptStarted, .attemptFailed, .interrupted,
                ]
            )
            assertRecoveryRequests(recorder, server)
        }
    }
#endif
