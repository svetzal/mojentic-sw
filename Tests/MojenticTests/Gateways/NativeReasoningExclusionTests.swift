import Foundation
import Mojentic
import Testing

@Suite(.serialized)
struct NativeReasoningExclusionTests {
    @Test(arguments: [false, true])
    func cancelledBufferedResponseCannotReturnRetainedHistory(omlx: Bool) async throws {
        let contract = try NativeReasoningContract()
        let server = try InProcessHTTPFixture(replies: [contract.reply(omlx: omlx, stream: false)])
        let tracer = PausedNativeResponseTracer()
        let broker = LLMBroker(
            gateway: RecoveryBoundary(omlx: omlx, structured: false).gateway(server, policy: nil),
            tracer: tracer)
        let task = Task {
            try await broker.complete(
                model: "fixture",
                messages: [.user("go")],
                config: .init(retainThinking: true))
        }
        for await _ in tracer.ready { break }
        task.cancel()
        await tracer.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(server.requests.withLock { $0.count } == 1)
    }

    @Test(arguments: [false, true])
    func cancellationAfterNativeDeltaDoesNotRetainOrDispatch(omlx: Bool) async throws {
        let contract = try NativeReasoningContract()
        let reasoning = try #require(contract.fields["reasoning"])
        let message: JSONValue = [omlx ? "reasoning_content" : "thinking": reasoning, "content": ""]
        let frame: JSONValue =
            omlx
            ? ["choices": [["delta": message, "finish_reason": .null]]]
            : ["message": message, "done": false]
        let json = try #require(String(data: JSONEncoder().encode(frame), encoding: .utf8))
        let prefix = omlx ? "data: \(json)\n\n" : json + "\n"
        var reply = try contract.reply(
            omlx: omlx,
            stream: true,
            tools: true)
        reply.body = prefix + reply.body
        reply.splitAt = prefix.utf8.count
        reply.holdSuffix = true
        let server = try InProcessHTTPFixture(replies: [reply])
        defer { server.releaseSuffix() }
        let gateway = RecoveryBoundary(
            omlx: omlx,
            structured: false
        ).gateway(
            server,
            policy: .init())
        let executed = RecoveryLocked(false)
        let session = ChatSession(
            broker: LLMBroker(gateway: gateway),
            model: "fixture",
            tools: [DispatchRecordingTool(executed: executed)],
            config: .init(retainThinking: true))
        let signal = AsyncStream<Void>.makeStream()
        let task = Task {
            do {
                for try await event in session.stream("go") {
                    if case .done = event { Issue.record("Cancelled stream produced a final response") }
                    if case .thinkingDelta(let delta) = event {
                        #expect(delta == reasoning.stringValue)
                        signal.continuation.yield(())
                    }
                }
                try Task.checkCancellation()
            } catch {}
        }
        for await _ in signal.stream { break }
        task.cancel()
        await task.value
        #expect(await session.messages().isEmpty)
        #expect(!executed.withLock { $0 })
        #expect(server.requests.withLock { $0.count } == 1)
    }

    @Test(arguments: [false, true])
    func incompleteStreamCannotBecomeRetainedHistory(omlx: Bool) async throws {
        let contract = try NativeReasoningContract()
        let message: JSONValue = [
            "content": contract.fields["visible"] ?? .null,
            omlx ? "reasoning_content" : "thinking": contract.fields["reasoning"] ?? .null,
        ]
        let root: JSONValue =
            omlx
            ? ["choices": [["delta": message]]]
            : ["message": message, "done": false]
        let json = try #require(String(data: JSONEncoder().encode(root), encoding: .utf8))
        let server = try InProcessHTTPFixture(replies: [
            RecoveryReply(body: omlx ? "data: \(json)\n\n" : json + "\n")
        ])
        let session = ChatSession(
            broker: LLMBroker(
                gateway: RecoveryBoundary(
                    omlx: omlx,
                    structured: false
                )
                .gateway(
                    server,
                    policy: nil)),
            model: "fixture",
            config: .init(retainThinking: true))
        await #expect(throws: (any Error).self) {
            for try await _ in session.stream("go") {}
        }
        #expect(await session.messages().isEmpty)
    }
}

private struct DispatchRecordingTool: LLMTool {
    let executed: RecoveryLocked<Bool>
    let descriptor = ToolDescriptor(
        name: "count",
        description: "count",
        parameters: ["type": "object"])
    func execute(arguments: JSONValue) async throws -> JSONValue {
        executed.withLock { $0 = true }
        return .null
    }
}

private actor PausedNativeResponseTracer: Tracer {
    nonisolated let ready: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private var pending: CheckedContinuation<Void, Never>?

    init() {
        let stream = AsyncStream<Void>.makeStream()
        ready = stream.stream
        signal = stream.continuation
    }

    func recordLLMResponse(_ payload: LLMResponsePayload) async {
        await withCheckedContinuation { continuation in
            pending = continuation
            signal.yield(())
        }
    }

    func release() {
        pending?.resume()
        pending = nil
    }
}
