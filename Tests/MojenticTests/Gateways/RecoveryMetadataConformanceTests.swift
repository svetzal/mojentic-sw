import Foundation
@testable import Mojentic
import Testing

struct RecoveryMetadataConformanceTests {
    @Test(arguments: StreamingBoundary.withAnthropic, [false, true])
    func publicMetadata(_ boundary: StreamingBoundary, _ brokerPath: Bool) async throws {
        if brokerPath, !boundary.single {
            return
        }
        let body =
            if boundary.anthropic {
                try boundary.frame(content: "é猫", done: true, metrics: true)
            } else {
                try boundary.frame(content: "é", metrics: true)
                    + boundary.frame(content: "猫", done: true, metrics: true)
            }
        let server = try RecoveryLoopback(replies: [
            RecoveryReply(status: 503, body: "retry"), RecoveryReply(body: body),
        ])
        let recorder = RecoveryRecorder()
        let reports = AsyncStream<CompletionRecoveryReport>.makeStream()
        var policy = recoveryPolicy(recorder)
        policy.reportObserver = { report in
            reports.continuation.yield(report)
            reports.continuation.finish()
        }
        let gateway = boundary.gateway(server, policy)
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
        #expect(content == "é猫")
        let requests = recorder.requests.withLock { $0 }
        let first = try #require(requests.first)
        let last = try #require(requests.last)
        #expect(first.0.logicalID == last.0.logicalID)
        #expect(first.0.attemptID != last.0.attemptID)
        #expect(first.0.wireNumber == 1)
        #expect(last.0.wireNumber == 2)
        #expect(requests.map(\.1) == [first.1, first.1])
        #expect(server.requests.withLock { $0 } == requests.map(\.1))
        var reportIterator = reports.stream.makeAsyncIterator()
        let report = try #require(await reportIterator.next())
        #expect(report.identity == last.0)
        #expect(report.logicalID == last.0.logicalID)
        #expect(report.history.map(\.identity) == [first.0])
        #expect(report.progress.observed.contentBytes == 5)
        #expect(report.progress.delivered.contentBytes == 5)
        let lifecycle = recorder.events.withLock { $0 }
        #expect(lifecycle.first?.identity == first.0)
        #expect(lifecycle.last?.identity == last.0)
        for value in progress {
            #expect(value.identity == last.0)
        }
        for value in metrics {
            #expect(value.identity == last.0)
        }
        assertTelemetry(boundary, progress: progress, metrics: metrics, order: order)
    }

    private func assertTelemetry(
        _ boundary: StreamingBoundary,
        progress: [RecoveryProgress],
        metrics: [CompletionEvidence],
        order: [String],
    ) {
        if !boundary.omlx {
            #expect(progress.map(\.frameIndex) == [1, 2])
            #expect(progress.map(\.observed.contentBytes) == [2, 5])
            #expect(progress.map(\.delivered.contentBytes) == [2, 5])
            #expect(metrics.map(\.frameIndex) == [1, 2])
            #expect(
                metrics.map { $0.metadata?["eval_duration"] } == [
                    .integer(6_000_000_000), .integer(6_000_000_000),
                ]
            )
            #expect(
                order == ["content", "progress", "metrics", "content", "progress", "metrics", "completed"]
            )
        } else if boundary.openAI {
            #expect(progress.isEmpty)
            #expect(metrics.map(\.frameIndex) == [1, 2])
            #expect(metrics.allSatisfy { $0.metadata == nil && $0.providerModel == nil })
            #expect(order == ["content", "metrics", "content", "metrics", "completed"])
        } else if boundary.anthropic {
            #expect(progress.isEmpty)
            #expect(metrics.map(\.frameIndex) == [1, 5])
            #expect(metrics.map { $0.usage?.completionTokens } == [0, 12])
            #expect(metrics.first?.metadata?["id"] == .string("credential-sentinel"))
            #expect(order == ["metrics", "content", "metrics", "completed"])
        } else {
            #expect(progress.isEmpty && metrics.isEmpty)
            #expect(order == ["content", "content", "completed"])
        }
        if !boundary.omlx || boundary.openAI {
            #expect(metrics.map { $0.usage?.promptTokens } == [3, 3])
            #expect(metrics.map { $0.usage?.completionTokens } == [12, 12])
            #expect(metrics.map { $0.usage?.totalTokens } == [15, 15])
        }
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
