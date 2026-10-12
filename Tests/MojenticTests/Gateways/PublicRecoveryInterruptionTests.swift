import Foundation
@testable import Mojentic
import Testing

struct PublicRecoveryInterruptionTests {
    @Test(arguments: PublicInterruptionCase.all)
    func publicPartialStreamNeverReplays(_ scenario: PublicInterruptionCase) async throws {
        try await probePublicInterruption(scenario.boundary, path: scenario.path, kind: scenario.kind)
    }

    @Test
    func unfinishedToolRestoresSession() async throws {
        try await probePublicInterruption(
            StreamingBoundary(omlx: false, single: false), path: "session", kind: "content-tool",
        )
    }
}

private func probePublicInterruption(
    _ boundary: StreamingBoundary, path: String, kind: String,
) async throws {
    let body = try publicInterruptionBody(boundary, kind: kind)
    let seed = try RecoveryBoundary(
        omlx: boundary.omlx,
        structured: false,
        openAI: boundary.openAI,
        anthropic: boundary.anthropic
    ).success()
    let reply = RecoveryReply(
        headers: ["X-Request-ID": "interruption-original"], body: body, truncated: true, hold: true)
    let server = try RecoveryLoopback(replies: path == "session" ? [seed, reply] : [reply])
    defer { server.release() }
    server.trace.record("call", "interruption/\(boundary)/\(path)/\(kind)")
    let recorder = RecoveryRecorder()
    let admissions = RecoveryLocked<Int>(0)
    let reports = RecoveryLocked<[CompletionRecoveryReport]>([])
    var policy = recoveryPolicy(recorder, attempts: 3)
    policy.retryableCategories.insert(.transport)
    policy.admission = { _, _ in
        admissions.withLock { $0 += 1 }
        return AsyncStream {
            $0.yield(.allow)
            $0.finish()
        }
    }
    policy.reportObserver = { value in reports.withLock { $0.append(value) } }
    let prefix = publicInterruptionPrefix(boundary, kind: kind)
    let closeOnObservation = RecoveryLocked<Bool>(false)
    if prefix.isEmpty {
        // Hidden reasoning and withheld tools have no public delivery to rendezvous on.
        // The HTTP callback parses before capture; close after the entire fixture is observed.
        let observed = RecoveryLocked<Int>(0)
        let capture = policy.wireObserver
        policy.wireObserver = { event in
            try capture?(event)
            if case .body(_, let bytes) = event, closeOnObservation.withLock({ $0 }) {
                let complete = observed.withLock {
                    $0 += bytes.count
                    return $0 == body.utf8.count
                }
                if complete { server.release() }
            }
        }
    }
    let broker = LLMBroker(gateway: boundary.gateway(server, policy))
    let count = RecoveryToolCounter()
    let tools: [any LLMTool] = [RecoveryCountingTool(calls: count)]
    let session = ChatSession(broker: broker, model: "fixture", systemPrompt: "existing-system", tools: tools)
    if path == "session" { _ = try await session.send("existing-user") }
    let original = await session.messages()
    if path == "session" {
        #expect(original == [.system("existing-system"), .user("existing-user"), .assistant("recovered")])
    }
    let capture = PublicInterruptionCapture(recorder: recorder, server: server, reports: reports)
    closeOnObservation.withLock { $0 = true }
    let failure = try await server.trace.scope {
        try await withRecoveryStreamCancellation {
            let consumer = try makePublicInterruptionConsumer(boundary, path, broker, session, tools)
            var seen: [String] = []
            for _ in prefix { try seen.append(#require(await consumer.next())) }
            #expect(seen == prefix)
            // Close only after the named public API has delivered the exact prefix.
            server.release()
            let failure = try await recoveryFailure {
                while let event = try await consumer.next() {
                    seen.append(event)
                    Issue.record("Unexpected event after interrupted prefix: \(event)")
                }
            }
            #expect(seen == prefix)
            if boundary.single { #expect(try await consumer.next() == nil) }
            return failure
        }
    }
    // The scoped error is delivered after the session producer has rolled back.
    #expect(await session.messages() == original)
    #expect(count.value.withLock { $0 } == 0)
    #expect(admissions.withLock { $0 } == 0)
    let request = try #require(recorder.requests.withLock { $0.last?.1 })
    let sent = try JSONDecoder().decode(JSONValue.self, from: request)
    if !boundary.single {
        if case .array(let advertised)? = sent.objectValue?["tools"] {
            #expect(advertised.count == 1)
        } else {
            Issue.record("Counting tool was not advertised to the provider")
        }
    }
    try capture.verify(boundary, kind: kind, body: body, failure: failure)
}

private func makePublicInterruptionConsumer(
    _ boundary: StreamingBoundary,
    _ path: String,
    _ broker: LLMBroker,
    _ session: ChatSession,
    _ tools: [any LLMTool],
) throws -> TerminalRecoveryConsumer {
    if boundary.single {
        return TerminalRecoveryConsumer(
            broker.generateRecoveryStreamEvents(model: "fixture", messages: [.user("failed-user")]))
    }
    return TerminalRecoveryConsumer(
        path == "session"
            ? session.stream("failed-user")
            : broker.stream(model: "fixture", messages: [.user("failed-user")], tools: tools))
}
