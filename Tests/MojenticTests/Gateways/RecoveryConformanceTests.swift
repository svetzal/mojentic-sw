import Foundation
@testable import Mojentic
import Testing

@Suite("Buffered recovery conformance")
struct RecoveryConformanceTests {
    @Test(arguments: RecoveryBoundary.all)
    func bothOperationsPreserveShapingAndResults(
        _ boundary: RecoveryBoundary
    ) async throws {
        let success = try boundary.success()
        let server = try RecoveryLoopback(replies: [RecoveryReply(status: 503, body: "unavailable"), success])
        let recorder = RecoveryRecorder()
        let report = RecoveryLocked<CompletionRecoveryReport?>(nil)
        var policy = recoveryPolicy(recorder)
        policy.admission = { failure, next in
            #expect(next == 2)
            #expect(failure.identity == recorder.requests.withLock { $0.first?.0 })
            #expect(failure.status == 503)
            #expect(failure.acceptance == .unknown)
            #expect(failure.reason == "selectedHTTPStatus")
            #expect(failure.progress.rawBytes == 11)
            #expect(failure.progress.headersReceived)
            #expect(failure.progress.observed == RecoverySemanticProgress())
            #expect(failure.progress.delivered == RecoverySemanticProgress())
            #expect(failure.inspectEvidence().body == Data("unavailable".utf8))
            #expect(failure.inspectEvidence().cause is RecoveryHTTPStatusFailure)
            return AsyncStream {
                $0.yield(.allow)
                $0.finish()
            }
        }
        policy.reportObserver = { final in report.withLock { $0 = final } }
        let result = try await boundary.complete(boundary.gateway(server, policy: policy))
        #expect(result.content == (boundary.structured ? #"{"answer":42}"# : "recovered"))
        #expect(result.thinking == "reasoning")
        #expect(result.providerModel == "served")
        #expect(result.usage?.promptTokens == 3)
        #expect(result.usage?.completionTokens == 4)
        let requests = server.requests.withLock { $0 }
        #expect(requests.count == 2)
        #expect(requests.first == requests.last)
        let fields = try JSONDecoder().decode(JSONValue.self, from: #require(requests.first)).objectValue
        #expect(fields?["model"] == "fixture")
        #expect(fields?["stream"] == false)
        if boundary.omlx {
            #expect(fields?["temperature"] == 0.25)
            #expect(fields?["max_tokens"] == 123)
            #expect(fields?["reasoning_effort"] == "high")
            if boundary.structured {
                #expect(fields?["response_format"] != nil)
            }
        } else {
            #expect(fields?["think"] == true)
            #expect(fields?["options"]?.objectValue?["temperature"] == 0.25)
            #expect(fields?["options"]?.objectValue?["num_predict"] == 123)
            if boundary.structured {
                #expect(fields?["format"] == ["type": "object"])
            }
        }
        if !boundary.structured {
            #expect(fields?["tools"] != nil)
        }
        let traces = recorder.requests.withLock { $0 }
        #expect(traces[0].0.logicalID == traces[1].0.logicalID)
        #expect(traces[0].0.attemptID != traces[1].0.attemptID)
        #expect(traces.map(\.0.wireNumber) == [1, 2])
        let events = recorder.events.withLock { $0 }
        #expect(
            events.map(\.transition.rawValue) == [
                "attemptStarted", "attemptFailed", "admissionPending", "admissionAllowed", "delayScheduled",
                "retryStarted", "attemptStarted", "attemptSucceeded",
            ]
        )
        let safe = try #require(String(bytes: JSONEncoder().encode(events), encoding: .utf8))
        #expect(!safe.contains("credential-sentinel"))
        #expect(!safe.contains("payload-sentinel"))
        #expect(events.last?.progress.observed == events.last?.progress.delivered)
        #expect(events.prefix(5).allSatisfy { $0.identity == traces[0].0 })
        #expect(events.suffix(3).allSatisfy { $0.identity == traces[1].0 })
        #expect(events.allSatisfy { $0.logicalID == traces[0].0.logicalID })
        #expect(events[1].progress.rawBytes == 11)
        #expect(events.last?.progress.rawBytes == success.body.utf8.count)
        let final = try #require(report.withLock { $0 })
        #expect(final.identity == traces[1].0)
        #expect(final.history.first?.identity == traces[0].0)
        #expect(final.history.count == 1)
        #expect(final.progress.delivered.reasoningBytes == 9)
        assertWireEvidence(recorder: recorder, traces: traces, success: success)
    }

    @Test(arguments: RecoveryBoundary.all, [400, 401, 403])
    func permanentTruncatedStatusWins(
        _ boundary: RecoveryBoundary,
        _ status: Int,
    ) async throws {
        let server = try RecoveryLoopback(replies: [
            RecoveryReply(
                status: status,
                headers: ["X-Request-ID": "credential-sentinel"],
                body: "payload-sentinel",
                truncated: true,
            )
        ])
        let recorder = RecoveryRecorder()
        var policy = recoveryPolicy(recorder)
        policy.retryableStatuses.insert(status)
        let failure = try await recoveryFailure {
            _ = try await boundary.complete(boundary.gateway(server, policy: policy))
        }
        #expect(failure.failure.status == status)
        #expect(failure.failure.category == .http)
        #expect(!failure.failure.eligible)
        #expect(failure.history.count == 1)
        #expect(failure.failure.progress.headersReceived)
        #expect(failure.failure.progress.rawBytes == 16)
        let evidence = failure.failure.inspectEvidence()
        #expect(evidence.body == Data("payload-sentinel".utf8))
        #expect(evidence.cause is URLError)
        #expect(evidence.headers["X-Request-ID"] == "credential-sentinel")
        #expect(!String(reflecting: failure).contains("sentinel"))
        #expect(server.requests.withLock { $0.count } == 1)
        #expect(
            recorder.events.withLock { $0.map(\.transition.rawValue) } == [
                "attemptStarted", "attemptFailed", "ineligible",
            ]
        )
    }

    @Test(arguments: RecoveryBoundary.all)
    func persistent504IsBounded(
        _ boundary: RecoveryBoundary
    ) async throws {
        let server = try RecoveryLoopback(replies: [RecoveryReply(status: 504, body: "payload-sentinel")])
        let recorder = RecoveryRecorder()
        let failure = try await recoveryFailure {
            _ = try await boundary.complete(
                boundary.gateway(server, policy: recoveryPolicy(recorder, attempts: 3))
            )
        }
        #expect(failure.outcome == .exhausted)
        #expect(failure.history.map { $0.identity?.wireNumber } == [1, 2, 3])
        #expect(Set(failure.history.compactMap { $0.identity?.attemptID }).count == 3)
        #expect(Set(failure.history.compactMap { $0.identity?.logicalID }).count == 1)
        #expect(failure.history.allSatisfy { $0.status == 504 && $0.progress.rawBytes == 16 })
        #expect(failure.history.allSatisfy { $0.progress.delivered == RecoverySemanticProgress() })
        #expect(server.requests.withLock { $0.count } == 3)
    }

    @Test(arguments: RecoveryBoundary.all)
    func successfulCaptureFailureRetainsObservedAndTypedCause(
        _ boundary: RecoveryBoundary
    ) async throws {
        let server = try RecoveryLoopback(replies: [boundary.success(tools: true)])
        let recorder = RecoveryRecorder()
        var policy = recoveryPolicy(recorder)
        policy.wireObserver = { event in
            if case .body = event {
                throw RecoveryCaptureSentinel()
            }
        }
        let failure = try await recoveryFailure {
            _ = try await boundary.complete(boundary.gateway(server, policy: policy))
        }
        #expect(failure.outcome == .captureFailed)
        #expect(failure.failure.category == .capture)
        #expect(failure.failure.inspectEvidence().cause is RecoveryCaptureSentinel)
        #expect(failure.failure.progress.observed.reasoningBytes == 9)
        #expect(failure.failure.progress.observed.contentBytes == (boundary.structured ? 13 : 9))
        #expect(failure.failure.progress.observed.completedToolCalls == 1)
        #expect(failure.failure.progress.delivered == RecoverySemanticProgress())
        #expect(failure.history.count == 1)
        #expect(server.requests.withLock { $0.count } == 1)
        #expect(
            recorder.events.withLock { $0.map(\.transition.rawValue) } == [
                "attemptStarted", "attemptFailed", "captureFailed",
            ]
        )
    }

    @Test(arguments: RecoveryBoundary.all)
    func malformedResponseNeverResends(
        _ boundary: RecoveryBoundary
    ) async throws {
        let server = try RecoveryLoopback(replies: [RecoveryReply(body: "not JSON payload-sentinel")])
        let recorder = RecoveryRecorder()
        let failure = try await recoveryFailure {
            _ = try await boundary.complete(boundary.gateway(server, policy: recoveryPolicy(recorder)))
        }
        #expect(failure.failure.category == .protocolFailure)
        #expect(failure.failure.inspectEvidence().cause is DecodingError)
        #expect(!failure.failure.eligible)
        #expect(server.requests.withLock { $0.count } == 1)
    }

    @Test(arguments: RecoveryBoundary.all)
    func disabledRecoveryRetainsLegacyOneSend(
        _ boundary: RecoveryBoundary
    ) async throws {
        let server = try RecoveryLoopback(replies: [
            RecoveryReply(status: 503, body: "legacy"), boundary.success(),
        ])
        let failure = await httpFailure {
            _ = try await boundary.complete(boundary.gateway(server, policy: nil))
        }
        #expect(failure?.status == 503)
        #expect(failure?.body == "legacy")
        #expect(server.requests.withLock { $0.count } == 1)
    }

    @Test(arguments: RecoveryBoundary.all)
    func successfulLegacyAndRecoveryResultsMatch(
        _ boundary: RecoveryBoundary
    ) async throws {
        let reply = try boundary.success()
        let legacyServer = try RecoveryLoopback(replies: [reply])
        let recoveryServer = try RecoveryLoopback(replies: [reply])
        let legacy = try await boundary.complete(boundary.gateway(legacyServer, policy: nil))
        let recorder = RecoveryRecorder()
        let recovered = try await boundary.complete(
            boundary.gateway(recoveryServer, policy: recoveryPolicy(recorder))
        )
        #expect(legacy == recovered)
        let legacyBody = try JSONDecoder().decode(
            JSONValue.self,
            from: #require(legacyServer.requests.withLock { $0.first }),
        )
        let recoveredBody = try JSONDecoder().decode(
            JSONValue.self,
            from: #require(recoveryServer.requests.withLock { $0.first }),
        )
        #expect(legacyBody == recoveredBody)
        #expect(recoveryServer.requests.withLock { $0.count } == 1)
    }
}

@Suite("Recovery protocol and identity safeguards")
struct RecoverySafeguardTests {
    @Test(arguments: RecoveryBoundary.all)
    func redirectsAreNotFollowed(
        _ boundary: RecoveryBoundary
    ) async throws {
        let server = try RecoveryLoopback(replies: [
            RecoveryReply(
                status: 307,
                headers: ["Location": "http://127.0.0.1:1/forbidden"],
                body: "redirect",
            )
        ])
        let failure = try await recoveryFailure {
            _ = try await boundary.complete(
                boundary.gateway(server, policy: recoveryPolicy(RecoveryRecorder()))
            )
        }
        #expect(failure.failure.status == 307)
        #expect(failure.failure.inspectEvidence().cause is RecoveryHTTPStatusFailure)
        #expect(server.requests.withLock { $0.count } == 1)
    }

    @Test(arguments: [false, true])
    func structuredJSONFailureRetainsReceivedSemanticEvidence(
        _ omlx: Bool
    ) async throws {
        let ordinary = RecoveryBoundary(omlx: omlx, structured: false)
        let structured = RecoveryBoundary(omlx: omlx, structured: true)
        let server = try RecoveryLoopback(replies: [ordinary.success()])
        let failure = try await recoveryFailure {
            _ = try await structured.gateway(server, policy: recoveryPolicy(RecoveryRecorder())).completeJSON(
                model: "fixture",
                messages: [.user("original")],
                schema: ["type": "object"],
                config: CompletionConfig(),
            )
        }
        #expect(failure.outcome == .malformedResponse)
        #expect(failure.failure.inspectEvidence().cause is DecodingError)
        #expect(failure.failure.progress.observed.reasoningBytes == 9)
        #expect(failure.failure.progress.observed.contentBytes == 9)
        #expect(failure.failure.progress.delivered == RecoverySemanticProgress())
        #expect(server.requests.withLock { $0.count } == 1)
    }

    @Test(arguments: RecoveryBoundary.all)
    func failedSecondRequestCaptureDoesNotInventAnotherAttempt(
        _ boundary: RecoveryBoundary
    ) async throws {
        let server = try RecoveryLoopback(replies: [RecoveryReply(status: 503, body: "busy")])
        let recorder = RecoveryRecorder()
        var policy = recoveryPolicy(recorder)
        policy.wireObserver = { event in
            if case .request(let identity, _, _, _) = event, identity.wireNumber == 2 {
                throw RecoveryCaptureSentinel()
            }
        }
        let failure = try await recoveryFailure {
            _ = try await boundary.complete(boundary.gateway(server, policy: policy))
        }
        #expect(failure.outcome == .captureFailed)
        #expect(failure.failure.identity == failure.history.first?.identity)
        #expect(failure.failure.progress.rawBytes == 4)
        #expect(failure.failure.inspectEvidence().body == Data("busy".utf8))
        #expect(failure.failure.inspectEvidence().cause is RecoveryCaptureSentinel)
        #expect(failure.history.first?.inspectEvidence().cause is RecoveryHTTPStatusFailure)
        #expect(failure.history.count == 1)
        #expect(failure.history.first?.identity?.wireNumber == 1)
        #expect(failure.logicalID == failure.history.first?.logicalID)
        #expect(server.requests.withLock { $0.count } == 1)
        #expect(!recorder.events.withLock { $0.map(\.transition.rawValue) }.contains("retryStarted"))
    }

    @Test(arguments: [false, true])
    func ordinaryJSONFormatKeepsLegacySuccessfulResult(
        _ omlx: Bool
    ) async throws {
        let boundary = RecoveryBoundary(omlx: omlx, structured: false)
        let reply = try boundary.success()
        let oldServer = try RecoveryLoopback(replies: [reply])
        let newServer = try RecoveryLoopback(replies: [reply])
        let config = CompletionConfig(responseFormat: .jsonObject)
        let old = try await boundary.gateway(oldServer, policy: nil).complete(
            model: "fixture",
            messages: [.user("original")],
            tools: nil,
            config: config,
        )
        let new = try await boundary.gateway(newServer, policy: recoveryPolicy(RecoveryRecorder())).complete(
            model: "fixture",
            messages: [.user("original")],
            tools: nil,
            config: config,
        )
        #expect(old == new)
        #expect(new.content == "recovered")
    }

    @Test(arguments: RecoveryBoundary.all)
    func receivedSemanticProgressSurvivesMalformedTail(
        _ boundary: RecoveryBoundary
    ) async throws {
        let good = try boundary.success(tools: true)
        let server = try RecoveryLoopback(replies: [
            RecoveryReply(body: good.body + "malformed-tail", hold: true, splitAt: good.body.utf8.count)
        ])
        defer { server.release() }
        let ready = AsyncStream<Void>.makeStream()
        let received = RecoveryLocked<Int>(0)
        var policy = recoveryPolicy(RecoveryRecorder())
        policy.wireObserver = { event in
            if case .body(_, let data) = event {
                let count = received.withLock {
                    $0 += data.count
                    return $0
                }
                if count == good.body.utf8.count {
                    ready.continuation.yield(())
                }
            }
        }
        let gateway = boundary.gateway(server, policy: policy)
        let task = Task { try await boundary.complete(gateway) }
        var iterator = ready.stream.makeAsyncIterator()
        _ = await iterator.next()
        server.release()
        let failure = try await recoveryFailure { _ = try await task.value }
        #expect(failure.failure.category == .protocolFailure)
        #expect(failure.failure.progress.observed.reasoningBytes == 9)
        #expect(failure.failure.progress.observed.completedToolCalls == 1)
        #expect(failure.failure.progress.delivered == RecoverySemanticProgress())
        #expect(failure.failure.progress.rawBytes == good.body.utf8.count + 14)
        #expect(server.requests.withLock { $0.count } == 1)
    }
}

private func assertWireEvidence(
    recorder: RecoveryRecorder,
    traces: [(RecoveryIdentity, Data)],
    success: RecoveryReply,
) {
    let wire = recorder.wires.withLock { $0 }
    var firstBody = Data()
    var secondBody = Data()
    var statuses: [Int] = []
    for item in wire {
        switch item {
        case .headers(let identity, let status, _):
            #expect(identity == (status == 503 ? traces[0].0 : traces[1].0))
            statuses.append(status)
        case .body(let identity, let bytes):
            #expect(identity == traces[0].0 || identity == traces[1].0)
            if identity == traces[0].0 {
                firstBody.append(bytes)
            } else {
                secondBody.append(bytes)
            }
        case .request: break
        }
    }
    #expect(statuses == [503, 200])
    #expect(firstBody == Data("unavailable".utf8))
    #expect(secondBody == Data(success.body.utf8))
    #expect(!String(reflecting: wire).contains("sentinel"))
}
