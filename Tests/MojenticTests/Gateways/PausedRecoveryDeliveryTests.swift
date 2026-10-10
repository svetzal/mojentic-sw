import Foundation
@testable import Mojentic
import Testing

struct PausedRecoveryDeliveryTests {
    @Test(arguments: StreamingBoundary.all)
    func cancellationAfterDeliveredValuesRetainsProgress(_ boundary: StreamingBoundary) async throws {
        let body = try boundary.frame(content: "é", reasoning: "ré")
        let server = try RecoveryLoopback(replies: [RecoveryReply(body: body, truncated: true, hold: true)])
        defer { server.release() }
        let recorder = RecoveryRecorder()
        let reports = RecoveryLocked<CompletionRecoveryReport?>(nil)
        var policy = recoveryPolicy(recorder)
        policy.reportObserver = { report in reports.withLock { $0 = report } }
        let gateway = boundary.gateway(server, policy)
        let ready = AsyncStream<Void>.makeStream()
        let pause = RecoveryConsumerPause()
        let values = RecoveryLocked<[String]>([])
        let task = Task {
            try await withRecoveryStreamCancellation {
                if boundary.single {
                    let stream = try gateway.completeStreamEventsRecovering(
                        model: "fixture",
                        messages: [],
                        config: .init(),
                    )
                    var iterator = stream.makeAsyncIterator()
                    while let event = await iterator.next() {
                        switch event {
                        case .content(let text): values.withLock { $0.append("content:\(text)") }
                        case .progress: values.withLock { $0.append("progress") }
                        default: Issue.record("Unexpected event before pause")
                        }
                        if case .content = event {
                            break
                        }
                    }
                    ready.continuation.yield(())
                    await pause.wait()
                    withExtendedLifetime(iterator) {}
                } else {
                    let stream = gateway.streamRecovering(
                        model: "fixture", messages: [], tools: nil, config: .init())
                    var iterator = stream.makeAsyncIterator()
                    while let event = try await iterator.next() {
                        switch event {
                        case .textDelta(let text): values.withLock { $0.append("content:\(text)") }
                        case .thinkingDelta(let text): values.withLock { $0.append("reasoning:\(text)") }
                        case .progress: values.withLock { $0.append("progress") }
                        default: Issue.record("Unexpected event before pause")
                        }
                        if values.withLock({ $0.filter { $0 != "progress" }.count }) == 2 {
                            break
                        }
                    }
                    ready.continuation.yield(())
                    await pause.wait()
                    withExtendedLifetime(iterator) {}
                }
            }
        }
        var signal = ready.stream.makeAsyncIterator()
        _ = await signal.next()
        task.cancel()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while reports.withLock({ $0 }) == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let report = reports.withLock { $0 }
        #expect(report != nil)
        #expect(server.waitForPeerClose())
        #expect(report?.progress.observed.contentBytes == 2)
        #expect(report?.progress.observed.reasoningBytes == 3)
        #expect(report?.progress.delivered.contentBytes == 2)
        #expect(report?.progress.delivered.reasoningBytes == (boundary.single ? 0 : 3))
        #expect(report?.progress.delivered.completedToolCalls == 0)
        let semantic = values.withLock { $0.filter { $0 != "progress" } }
        let expected =
            if boundary.single {
                ["content:é"]
            } else {
                if boundary.omlx {
                    ["reasoning:ré", "content:é"]
                } else {
                    ["content:é", "reasoning:ré"]
                }
            }
        #expect(semantic == expected)
        #expect(values.withLock { $0 } == expected)
        #expect(
            recorder.events.withLock { $0.map(\.transition) } == [
                .attemptStarted,
                .attemptFailed,
                .cancelled,
            ]
        )
        #expect(recorder.requests.withLock { $0.count } == 1)
        pause.resume()
        try await task.value
    }
}
