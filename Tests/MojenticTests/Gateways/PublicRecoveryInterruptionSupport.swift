import Foundation
@testable import Mojentic
import Testing

struct PublicInterruptionCase: Sendable, CustomStringConvertible {
    let boundary: StreamingBoundary
    let path: String
    let kind: String
    var description: String { "\(boundary)/\(path)/\(kind)" }

    static var all: [Self] {
        StreamingBoundary.withAnthropic.flatMap { boundary in
            // Single-turn APIs accept content and reasoning, but no tools.
            let paths = boundary.single ? ["single"] : ["broker", "session"]
            let kinds = boundary.single ? ["content", "reasoning"] : ["content", "reasoning", "tool"]
            return paths.flatMap { path in
                kinds.map { Self(boundary: boundary, path: path, kind: $0) }
            }
        }
    }
}

struct PublicInterruptionCapture {
    let recorder: RecoveryRecorder
    let server: InProcessHTTPFixture
    let reports: RecoveryLocked<[CompletionRecoveryReport]>
    let baseline: Int
    let eventBaseline: Int
    let wireBaseline: Int
    let reportBaseline: Int

    init(
        recorder: RecoveryRecorder,
        server: InProcessHTTPFixture,
        reports: RecoveryLocked<[CompletionRecoveryReport]>
    ) {
        self.recorder = recorder
        self.server = server
        self.reports = reports
        baseline = recorder.requests.withLock { $0.count }
        eventBaseline = recorder.events.withLock { $0.count }
        wireBaseline = recorder.wires.withLock { $0.count }
        reportBaseline = reports.withLock { $0.count }
    }

    func verify(_ boundary: StreamingBoundary, kind: String, body: String, failure: RecoveryError) throws {
        #expect(failure.outcome == .interrupted)
        #expect(!failure.failure.eligible)
        #expect(failure.history.count == 1)
        let requests = recorder.requests.withLock { Array($0.dropFirst(baseline)) }
        let request = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(server.requests.withLock { Array($0.dropFirst(baseline)) } == [request.1])
        #expect(request.0.wireNumber == 1)
        #expect(request.0.logicalID != request.0.attemptID)
        #expect(failure.logicalID == request.0.logicalID)
        #expect(failure.failure.identity == request.0)
        #expect(failure.history.first?.identity == request.0)
        #expect(failure.history.first?.logicalID == failure.logicalID)
        #expect(failure.history.first?.progress == failure.failure.progress)
        let events = recorder.events.withLock { Array($0.dropFirst(eventBaseline)) }
        #expect(events.map(\.transition) == [.attemptStarted, .attemptFailed, .interrupted])
        #expect(events.allSatisfy { $0.identity == request.0 && $0.logicalID == failure.logicalID })
        let report = try #require(reports.withLock { Array($0.dropFirst(reportBaseline)).first })
        #expect(reports.withLock { $0.count } == reportBaseline + 1)
        #expect(report.logicalID == failure.logicalID)
        #expect(report.identity == request.0)
        #expect(report.history.count == 1)
        #expect(report.history.first?.identity == request.0)
        #expect(report.progress == failure.failure.progress)
        let evidence = failure.failure.inspectEvidence()
        let cause = try #require(evidence.cause as? URLError)
        #expect(cause.code == .networkConnectionLost)
        let historyCause = try #require(failure.history.first?.inspectEvidence().cause as? URLError)
        let reportCause = try #require(report.history.first?.inspectEvidence().cause as? URLError)
        #expect((historyCause as NSError).isEqual(cause as NSError))
        #expect((reportCause as NSError).isEqual(cause as NSError))
        #expect(failure.failure.category == .transport)
        #expect(failure.failure.reason == "observedSemanticOutput")
        #expect(evidence.body == Data(body.utf8))
        #expect(failure.failure.status == 200)
        #expect(
            evidence.headers.first { $0.key.lowercased() == "x-request-id" }?.value == "interruption-original"
        )
        let progress = failure.failure.progress
        #expect(progress.headersReceived)
        #expect(progress.rawBytes == body.utf8.count)
        #expect(progress.observed.contentBytes == (kind.contains("content") ? 6 : 0))
        #expect(progress.delivered.contentBytes == (kind.contains("content") ? 6 : 0))
        #expect(progress.observed.reasoningBytes == (kind == "reasoning" ? 3 : 0))
        #expect(
            progress.delivered.reasoningBytes
                == (kind == "reasoning" && !boundary.single && !boundary.openAI ? 3 : 0)
        )
        #expect(
            progress.observed.toolFragments
                == (kind.contains("tool") ? (boundary.anthropic && kind == "tool" ? 2 : 1) : 0)
        )
        // Ollama supplies a complete argument object before the stream terminal marker.
        // It is observed as a call, but is never delivered or executed without that marker.
        #expect(progress.observed.completedToolCalls == (kind.contains("tool") && !boundary.omlx ? 1 : 0))
        #expect(progress.delivered.toolFragments == 0)
        #expect(progress.delivered.completedToolCalls == 0)
        var expectedProgress = RecoveryProgress()
        expectedProgress.headersReceived = true
        expectedProgress.rawBytes = body.utf8.count
        expectedProgress.observed.contentBytes = kind.contains("content") ? 6 : 0
        expectedProgress.delivered.contentBytes = kind.contains("content") ? 6 : 0
        expectedProgress.observed.reasoningBytes = kind == "reasoning" ? 3 : 0
        expectedProgress.delivered.reasoningBytes =
            kind == "reasoning" && !boundary.single && !boundary.openAI ? 3 : 0
        expectedProgress.observed.toolFragments =
            kind.contains("tool") ? (boundary.anthropic && kind == "tool" ? 2 : 1) : 0
        expectedProgress.observed.completedToolCalls = kind.contains("tool") && !boundary.omlx ? 1 : 0
        #expect(
            events
                == RecoveryLifecycleEvidence(boundary).interruption(
                    identity: request.0,
                    progress: expectedProgress
                )
        )
        var captured = Data()
        for wire in recorder.wires.withLock({ Array($0.dropFirst(wireBaseline)) }) {
            switch wire {
            case .request(let identity, _, _, let bytes):
                #expect(identity == request.0)
                #expect(bytes == request.1)
            case .headers(let identity, let status, _):
                #expect(identity == request.0)
                #expect(status == 200)
            case .body(let identity, let bytes):
                #expect(identity == request.0)
                captured.append(bytes)
            }
        }
        #expect(captured == Data(body.utf8))
    }
}

func publicInterruptionPrefix(_ boundary: StreamingBoundary, kind: String) -> [String] {
    var prefix: [String] = kind.contains("content") ? ["content:é🐈"] : []
    if kind == "reasoning", !boundary.single, !boundary.openAI { prefix = ["reasoning:想"] }
    if boundary.single, boundary.anthropic { prefix.insert("metrics", at: 0) }
    if boundary.single, !boundary.omlx { prefix.append("progress") }
    return prefix
}

func publicInterruptionBody(_ boundary: StreamingBoundary, kind: String) throws -> String {
    if kind == "tool", boundary.omlx, !boundary.anthropic {
        // Valid SSE framing with unfinished JSON arguments and no finish marker.
        let fragment: JSONValue = [
            "choices": [
                [
                    "delta": [
                        "tool_calls": [
                            [
                                "index": 0, "id": "original-tool",
                                "function": ["name": "resolve_date", "arguments": #"{"relative":"#],
                            ]
                        ]
                    ]
                ]
            ]
        ]
        return try publicInterruptionSSE(fragment)
    }
    var body = try boundary.frame(
        content: kind.contains("content") ? "é🐈" : "",
        reasoning: kind == "reasoning" ? "想" : "",
        tool: kind.contains("tool"),
    )
    if kind == "tool", boundary.anthropic {
        // The tool block remains open with incomplete JSON; neither block nor message stops.
        let fragment: JSONValue = [
            "type": "content_block_delta", "index": 0,
            "delta": ["type": "input_json_delta", "partial_json": #"{"relative":"#],
        ]
        body += "event: content_block_delta\n" + (try publicInterruptionSSE(fragment))
    }
    return body
}

private func publicInterruptionSSE(_ frame: JSONValue) throws -> String {
    let encoded = try #require(String(data: JSONEncoder().encode(frame), encoding: .utf8))
    return "data: \(encoded)\n\n"
}
