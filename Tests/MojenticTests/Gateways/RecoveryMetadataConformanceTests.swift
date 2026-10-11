import Foundation
@testable import Mojentic
import Testing

struct RecoveryMetadataConformanceTests {
    @Test(arguments: StreamingBoundary.withAnthropic, [false, true])
    func publicMetadata(_ boundary: StreamingBoundary, _ brokerPath: Bool) async throws {
        if brokerPath, !boundary.single {
            return
        }
        let initial = try metadataFrame(boundary, attempt: 1)
        var semantic = try boundary.frame(content: "é猫", done: true, metrics: true)
        if boundary.anthropic {
            // The second attempt already has message_start; append only its content and finish frames.
            let startEnd = try #require(semantic.range(of: "\n\n"))
            semantic = String(semantic[startEnd.upperBound...])
        }
        let body = try metadataFrame(boundary, attempt: 2) + semantic
        let server = try RecoveryLoopback(replies: [
            RecoveryReply(body: initial, truncated: true), RecoveryReply(body: body),
        ])
        let recorder = RecoveryRecorder()
        let reports = AsyncStream<CompletionRecoveryReport>.makeStream()
        let admissions = RecoveryLocked<[RecoveryFailure]>([])
        var policy = recoveryPolicy(recorder)
        policy.admission = { failure, next in
            #expect(next == 2)
            admissions.withLock { $0.append(failure) }
            return AsyncStream {
                $0.yield(.allow)
                $0.finish()
            }
        }
        policy.reportObserver = { report in
            reports.continuation.yield(report)
            reports.continuation.finish()
        }
        let gateway = boundary.gateway(server, policy)
        let observed = try await collectMetadata(boundary, brokerPath: brokerPath, gateway: gateway)
        #expect(observed.content == "é猫")
        let requests = recorder.requests.withLock { $0 }
        #expect(requests.count == 2)
        let first = try #require(requests.first)
        let last = try #require(requests.last)
        #expect(first.0.logicalID == last.0.logicalID)
        #expect(first.0.attemptID != last.0.attemptID)
        #expect(first.0.wireNumber == 1)
        #expect(last.0.wireNumber == 2)
        #expect(requests.map(\.1) == [first.1, first.1])
        #expect(server.requests.withLock { $0 } == requests.map(\.1))
        let captured = recorder.wires.withLock { wires in
            wires.reduce(into: [RecoveryIdentity: Data]()) { bytes, event in
                if case .body(let identity, let data) = event {
                    bytes[identity, default: Data()].append(data)
                }
            }
        }
        #expect(captured == [first.0: Data(initial.utf8), last.0: Data(body.utf8)])
        var reportIterator = reports.stream.makeAsyncIterator()
        let report = try #require(await reportIterator.next())
        #expect(report.identity == last.0)
        #expect(report.logicalID == last.0.logicalID)
        #expect(report.history.map(\.identity) == [first.0])
        let failure = try #require(report.history.first)
        #expect(failure.logicalID == first.0.logicalID)
        #expect(failure.category == .transport && failure.eligible)
        #expect(failure.acceptance == .unknown)
        #expect(failure.status == 200)
        #expect(failure.progress.headersReceived)
        #expect(failure.progress.rawBytes == initial.utf8.count)
        #expect(failure.progress.observed == RecoverySemanticProgress())
        #expect(failure.progress.delivered == RecoverySemanticProgress())
        // FoundationNetworking retains libcurl's partial-transfer error as unknown;
        // Darwin retains its native lost-connection error. Both remain typed transport evidence.
        let cause = try #require(failure.inspectEvidence().cause as? URLError)
        #if os(Linux)
            #expect(cause.code == .unknown)
        #else
            #expect(cause.code == .networkConnectionLost)
        #endif
        #expect(admissions.withLock { $0.map(\.identity) } == [first.0])
        #expect(report.progress.observed.contentBytes == 5)
        #expect(report.progress.delivered.contentBytes == 5)
        let lifecycle = recorder.events.withLock { $0 }
        #expect(
            lifecycle.map(\.transition) == [
                .attemptStarted, .attemptFailed, .admissionPending, .admissionAllowed, .delayScheduled,
                .retryStarted, .attemptStarted, .attemptSucceeded,
            ]
        )
        #expect(
            lifecycle.map(\.identity) == Array(repeating: first.0, count: 5)
                + Array(repeating: last.0, count: 3)
        )
        #expect(lifecycle.allSatisfy { $0.logicalID == first.0.logicalID })
        #expect(lifecycle[1].progress == failure.progress)
        #expect(lifecycle.last?.progress == report.progress)
        assertTelemetry(
            boundary,
            first: first.0,
            last: last.0,
            progress: observed.progress,
            metrics: observed.metrics,
            order: observed.order,
        )
    }

    private struct MetadataEvents {
        let progress: [RecoveryProgress]
        let metrics: [CompletionEvidence]
        let content: String
        let order: [String]
    }

    private func collectMetadata(
        _ boundary: StreamingBoundary,
        brokerPath: Bool,
        gateway: any LLMGateway,
    ) async throws -> MetadataEvents {
        var progress: [RecoveryProgress] = []
        var metrics: [CompletionEvidence] = []
        var content = ""
        var order: [String] = []
        if boundary.single {
            let stream =
                if brokerPath {
                    LLMBroker(gateway: gateway).generateRecoveryStreamEvents(
                        model: "fixture", messages: [.user("identity")],
                    )
                } else {
                    try gateway.completeStreamEventsRecovering(
                        model: "fixture", messages: [.user("identity")], config: .init(),
                    )
                }
            for await event in stream {
                switch event {
                case .content(let text):
                    content += text
                    order.append("content")
                case .progress(let value):
                    progress.append(value)
                    order.append("progress")
                case .metrics(let value):
                    metrics.append(value)
                    order.append("metrics")
                case .completed: order.append("completed")
                default: Issue.record("Unexpected failure")
                }
            }
        } else {
            for try await event in gateway.streamRecovering(
                model: "fixture", messages: [.user("identity")], tools: nil, config: .init(),
            ) {
                switch event {
                case .textDelta(let text):
                    content += text
                    order.append("content")
                case .progress(let value):
                    progress.append(value)
                    order.append("progress")
                case .metrics(let value):
                    metrics.append(value)
                    order.append("metrics")
                case .done: order.append("completed")
                default: Issue.record("Unexpected semantic event")
                }
            }
        }
        return MetadataEvents(progress: progress, metrics: metrics, content: content, order: order)
    }

    private func metadataFrame(_ boundary: StreamingBoundary, attempt: Int) throws -> String {
        let output = attempt == 1 ? 7 : 12
        let model = "served-attempt-\(attempt)"
        let value: JSONValue =
            if boundary.anthropic {
                [
                    "type": "message_start",
                    "message": [
                        "role": "assistant", "model": .string(model), "id": .string("message-\(attempt)"),
                        "content": [], "usage": ["input_tokens": 3, "output_tokens": .integer(output)],
                    ],
                ]
            } else if boundary.omlx {
                [
                    "choices": [], "model": .string(model),
                    "usage": [
                        "prompt_tokens": 3, "completion_tokens": .integer(output),
                        "total_tokens": .integer(3 + output),
                    ],
                ]
            } else {
                [
                    "message": ["content": ""], "done": false, "model": .string(model),
                    "prompt_eval_count": 3, "eval_count": .integer(output),
                    "eval_duration": .integer(attempt * 3_000_000_000),
                ]
            }
        let encoded = try #require(String(data: JSONEncoder().encode(value), encoding: .utf8))
        if boundary.anthropic {
            return "event: message_start\ndata: \(encoded)\n\n"
        }
        return boundary.omlx ? "data: \(encoded)\n\n" : encoded + "\n"
    }

    private func assertTelemetry(
        _ boundary: StreamingBoundary,
        first: RecoveryIdentity,
        last: RecoveryIdentity,
        progress: [RecoveryProgress],
        metrics: [CompletionEvidence],
        order: [String],
    ) {
        if !boundary.omlx {
            #expect(progress.map(\.identity) == [first, last, last])
            #expect(progress.map(\.frameIndex) == [1, 1, 2])
            #expect(progress.map(\.observed.contentBytes) == [0, 0, 5])
            #expect(progress.map(\.delivered.contentBytes) == [0, 0, 5])
            #expect(
                metrics.map { $0.metadata?["eval_duration"] } == [
                    .integer(3_000_000_000), .integer(6_000_000_000), .integer(6_000_000_000),
                ]
            )
            #expect(metrics.allSatisfy { $0.providerModel == nil })
            #expect(
                order == [
                    "progress", "metrics", "progress", "metrics", "content", "progress", "metrics",
                    "completed",
                ]
            )
        } else if boundary.openAI {
            #expect(progress.isEmpty)
            #expect(metrics.allSatisfy { $0.metadata == nil && $0.providerModel == nil })
            #expect(order == ["metrics", "metrics", "content", "metrics", "completed"])
        } else if boundary.anthropic {
            #expect(progress.isEmpty)
            #expect(
                metrics.map(\.providerModel) == ["served-attempt-1", "served-attempt-2", "served-attempt-2"]
            )
            #expect(
                metrics.map { $0.metadata?["id"] } == [
                    .string("message-1"), .string("message-2"), .string("message-2"),
                ]
            )
            #expect(order == ["metrics", "metrics", "content", "metrics", "completed"])
        } else {
            #expect(progress.isEmpty && metrics.isEmpty)
            #expect(order == ["content", "completed"])
            return
        }
        let expectedIdentities = [first, last, last]
        #expect(metrics.map(\.identity) == expectedIdentities)
        #expect(metrics.map(\.frameIndex) == (boundary.anthropic ? [1, 1, 5] : [1, 1, 2]))
        #expect(metrics.map { $0.usage?.promptTokens } == [3, 3, 3])
        #expect(metrics.map { $0.usage?.completionTokens } == [7, 12, 12])
        #expect(metrics.map { $0.usage?.totalTokens } == [10, 15, 15])
    }

    @Test(arguments: StreamingBoundary.withAnthropic)
    func metadataDisconnectRequiresAdmission(_ boundary: StreamingBoundary) async throws {
        let initial = try metadataFrame(boundary, attempt: 1)
        let server = try RecoveryLoopback(replies: [RecoveryReply(body: initial, truncated: true)])
        let recorder = RecoveryRecorder()
        let reports = AsyncStream<CompletionRecoveryReport>.makeStream()
        var policy = recoveryPolicy(recorder)
        policy.admission = nil
        policy.reportObserver = {
            reports.continuation.yield($0)
            reports.continuation.finish()
        }
        let order = RecoveryLocked<[String]>([])
        let gateway = boundary.gateway(server, policy)
        let error = try await recoveryFailure { try await boundary.consume(gateway, record: order) }
        #expect(error.outcome == .admissionRequired)
        #expect(error.failure.eligible && error.failure.acceptance == .unknown)
        #expect(error.failure.progress.observed == RecoverySemanticProgress())
        #expect(error.failure.progress.delivered == RecoverySemanticProgress())
        let requests = recorder.requests.withLock { $0 }
        #expect(requests.count == 1)
        let identity = try #require(requests.first?.0)
        #expect(error.failure.identity == identity)
        #expect(server.requests.withLock { $0 } == requests.map(\.1))
        #expect(
            order.withLock { $0 }
                == (!boundary.omlx
                    ? ["progress", "metrics"]
                    : boundary.openAI || boundary.anthropic ? ["metrics"] : [])
        )
        var iterator = reports.stream.makeAsyncIterator()
        let report = try #require(await iterator.next())
        #expect(report.identity == identity)
        #expect(report.logicalID == identity.logicalID)
        #expect(report.history.map(\.identity) == [identity])
        #expect(report.progress == error.failure.progress)
        let lifecycle = recorder.events.withLock { $0 }
        #expect(lifecycle.map(\.transition) == [.attemptStarted, .attemptFailed, .admissionRequired])
        #expect(lifecycle.allSatisfy { $0.identity == identity && $0.logicalID == identity.logicalID })
    }

    @Test(arguments: [false, true])
    func ollamaLengthTelemetryBeforeFailure(_ brokerPath: Bool) async throws {
        let boundary = StreamingBoundary(omlx: false, single: brokerPath)
        let body = try boundary.frame(
            content: "é", reasoning: "猫", tool: true, done: true, reason: "length", metrics: true,
        )
        let server = try RecoveryLoopback(replies: [RecoveryReply(body: body)])
        let recorder = RecoveryRecorder()
        let gateway = boundary.gateway(server, recoveryPolicy(recorder))
        var order: [String] = []
        var progress: RecoveryProgress?
        var metrics: CompletionEvidence?
        var failure: RecoveryError?
        if brokerPath {
            for await event in LLMBroker(gateway: gateway).generateRecoveryStreamEvents(
                model: "fixture", messages: [],
            ) {
                switch event {
                case .progress(let value):
                    progress = value
                    order.append("progress")
                case .metrics(let value):
                    metrics = value
                    order.append("metrics")
                case .recoveryFailure(let error):
                    failure = error
                    order.append("failed")
                default: Issue.record("Rejected finish delivered content, tool or success")
                }
            }
        } else {
            do {
                for try await event in gateway.streamRecovering(
                    model: "fixture", messages: [], tools: nil, config: .init(),
                ) {
                    switch event {
                    case .progress(let value):
                        progress = value
                        order.append("progress")
                    case .metrics(let value):
                        metrics = value
                        order.append("metrics")
                    default: Issue.record("Rejected finish delivered content, tool or success")
                    }
                }
            } catch let error as RecoveryError {
                failure = error
                order.append("failed")
            }
        }
        #expect(order == ["progress", "metrics", "failed"])
        let wire = try #require(recorder.requests.withLock { $0.first?.0 })
        #expect(progress?.identity == wire)
        #expect(metrics?.identity == wire)
        #expect(failure?.failure.identity == wire)
        #expect(progress?.frameIndex == 1 && metrics?.frameIndex == 1)
        #expect(progress?.observed.contentBytes == 2)
        #expect(progress?.observed.reasoningBytes == 3)
        #expect(progress?.observed.toolFragments == 1)
        #expect(progress?.delivered == RecoverySemanticProgress())
        #expect(metrics?.usage?.completionTokens == 12)
        #expect(metrics?.metadata?["eval_duration"] == .integer(6_000_000_000))
        #expect(failure?.failure.progress.delivered.completedToolCalls == 0)
        #expect(server.requests.withLock { $0 } == recorder.requests.withLock { $0.map(\.1) })
    }
}
