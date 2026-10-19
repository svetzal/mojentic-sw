import Foundation
@testable import Mojentic
import Testing

/// Decode the captured HTTP body, asserting the entire ordered exchange independently of adapters.
func assertStreamingFollowUpHistory(_ body: Data, boundary: StreamingBoundary) throws {
    let fields = try #require(JSONDecoder().decode(JSONValue.self, from: body).objectValue)
    let arguments: JSONValue = ["relative": "tomorrow"]
    let result = #"{"original-result":"tool-sentinel"}"#
    let expected: JSONValue
    if boundary.anthropic {
        expected = [
            ["role": "user", "content": "original-user"],
            [
                "role": "assistant",
                "content": [
                    [
                        "type": "tool_use", "id": "original-tool", "name": "resolve_date", "input": arguments,
                    ]
                ],
            ],
            [
                "role": "user",
                "content": [
                    [
                        "type": "tool_result", "tool_use_id": "original-tool", "content": .string(result),
                    ]
                ],
            ],
        ]
    } else {
        var call: [String: JSONValue] = [
            "type": "function",
            "function": [
                "name": "resolve_date",
                "arguments": boundary.omlx ? .string(#"{"relative":"tomorrow"}"#) : arguments,
            ],
        ]
        var tool: [String: JSONValue] = ["role": "tool", "content": .string(result)]
        if boundary.omlx {
            call["id"] = "original-tool"
            tool["tool_call_id"] = "original-tool"
        }
        expected = [
            ["role": "user", "content": "original-user"],
            ["role": "assistant", "content": "", "tool_calls": .array([.object(call)])],
            .object(tool),
        ]
    }
    #expect(fields["messages"] == expected)
}

/// Match every actual HTTP boundary send to capture, admission, lifecycle, failure and final reports.
func assertStreamingFollowUpEvidence(
    _ recorder: RecoveryRecorder,
    server: InProcessHTTPFixture,
    replies: [RecoveryReply],
    admissions: [(RecoveryFailure, Int)],
    reports: [CompletionRecoveryReport],
    rejection: RecoveryError?,
) throws {
    let captures = recorder.requests.withLock { $0 }
    #expect(server.requests.withLock { $0 } == captures.map(\.1))
    #expect(captures.count == replies.count)
    let initial = try #require(captures.first?.0)
    let failed = try #require(captures.dropFirst().first?.0)
    let final = try #require(captures.last?.0)
    #expect(initial.logicalID != failed.logicalID)
    #expect(initial.wireNumber == 1 && failed.wireNumber == 1)
    #expect(Set(captures.map(\.0.attemptID)).count == captures.count)
    #expect(final.logicalID == failed.logicalID)
    #expect(final.wireNumber == (rejection == nil ? 2 : 1))
    try assertStreamingFollowUpWires(recorder.wires.withLock { $0 }, captures: captures, replies: replies)

    #expect(admissions.count == 1)
    let admission = try #require(admissions.first)
    #expect(admission.1 == 2)
    try assertStreamingFollowUpFailure(admission.0, identity: failed)
    if let rejection {
        #expect(rejection.outcome == .admissionRejected)
        #expect(rejection.history.map(\.identity) == [failed])
        try assertStreamingFollowUpFailure(rejection.failure, identity: failed)
        let rejectedHistory = try #require(rejection.history.first)
        try assertStreamingFollowUpFailure(rejectedHistory, identity: failed)
        #expect(rejection.failure.progress == admission.0.progress)
    }

    let events = recorder.events.withLock { $0 }
    let expected: [RecoveryTransition]
    let identities: [RecoveryIdentity]
    if rejection == nil {
        expected = [
            .attemptStarted, .attemptFailed, .admissionPending, .admissionAllowed, .delayScheduled,
            .retryStarted, .attemptStarted, .attemptSucceeded,
        ]
        identities = [initial, initial, failed, failed, failed, failed, failed, final, final, final]
    } else {
        expected = [.attemptStarted, .attemptFailed, .admissionPending, .admissionRejected]
        identities = [initial, initial, failed, failed, failed, failed]
    }
    #expect(events.map(\.transition) == [.attemptStarted, .attemptSucceeded] + expected)
    #expect(events.map(\.identity) == identities.map(Optional.some))
    #expect(events.map(\.logicalID) == identities.map(\.logicalID))
    #expect(reports.count == 2)
    let firstReport = try #require(reports.first)
    #expect(firstReport.identity == initial && firstReport.logicalID == initial.logicalID)
    #expect(firstReport.history.isEmpty)
    #expect(firstReport.progress.delivered.completedToolCalls == 1)
    let followUp = try #require(reports.last)
    #expect(followUp.identity == final && followUp.logicalID == failed.logicalID)
    #expect(followUp.history.map(\.identity) == [failed])
    let reportedFailure = try #require(followUp.history.first)
    try assertStreamingFollowUpFailure(reportedFailure, identity: failed)
    #expect(followUp.history.first?.progress == admission.0.progress)
    #expect(followUp.progress.delivered.completedToolCalls == 0)
    #expect(followUp.progress.delivered.contentBytes == (rejection == nil ? "recovered".utf8.count : 0))
}

private func assertStreamingFollowUpFailure(_ failure: RecoveryFailure, identity: RecoveryIdentity) throws {
    #expect(failure.identity == identity && failure.logicalID == identity.logicalID)
    #expect(failure.category == .http && failure.status == 503)
    #expect(failure.eligible && failure.acceptance == .unknown)
    #expect(failure.progress.observed == RecoverySemanticProgress())
    #expect(failure.progress.delivered == RecoverySemanticProgress())
    let cause = try #require(failure.inspectEvidence().cause as? RecoveryHTTPStatusFailure)
    #expect(cause.status == 503)
    #expect(failure.inspectEvidence().body == Data("busy".utf8))
}

private func assertStreamingFollowUpWires(
    _ wires: [RecoveryWireEvent],
    captures: [(RecoveryIdentity, Data)],
    replies: [RecoveryReply],
) throws {
    // Compare the ordered capture stream, not just an unordered collection of bodies.
    var sendIndex = -1
    var response = Data()
    var headersSeen = false
    for wire in wires {
        switch wire {
        case .request(let identity, _, _, let body):
            if sendIndex >= 0 {
                #expect(headersSeen)
                #expect(response == Data(replies[sendIndex].body.utf8))
            }
            sendIndex += 1
            let capture = try #require(captures.dropFirst(sendIndex).first)
            #expect(identity == capture.0)
            #expect(body == capture.1)
            response = Data()
            headersSeen = false
        case .headers(let identity, let status, _):
            let capture = try #require(captures.dropFirst(sendIndex).first)
            #expect(identity == capture.0)
            #expect(!headersSeen && response.isEmpty)
            #expect(status == replies[sendIndex].status)
            headersSeen = true
        case .body(let identity, let bytes):
            let capture = try #require(captures.dropFirst(sendIndex).first)
            #expect(identity == capture.0)
            #expect(headersSeen)
            response.append(bytes)
        }
    }
    #expect(sendIndex == captures.count - 1)
    #expect(headersSeen)
    let lastReply = try #require(replies.last)
    #expect(response == Data(lastReply.body.utf8))
}
