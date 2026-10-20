import Foundation
@testable import Mojentic
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Interleave independent public completions at explicit boundary rendezvous.
struct RecoveryFixtureIsolationTests {
    @Test
    func unconfiguredSessionCannotConsumeFixtureReplies() async throws {
        let boundary = RecoveryBoundary(omlx: false, structured: false)
        let fixture = try InProcessHTTPFixture(replies: [boundary.success()])
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let gateway = OllamaGateway(baseURL: fixture.url, client: HTTPClient(session: session))
        // The custom scheme cannot make a connection when the session has no stub.
        await #expect(throws: MojenticError.self) {
            _ = try await boundary.complete(gateway)
        }
        #expect(fixture.requests.withLock { $0.isEmpty })
        let result = try await boundary.complete(boundary.gateway(fixture, policy: nil))
        #expect(result.content == "recovered")
        #expect(fixture.requests.withLock { $0.count } == 1)
    }

    @Test(arguments: RecoveryBoundary.all, [false, true])
    func overlappingFixturesRetainTheirOwnScripts(_ boundary: RecoveryBoundary, _ reverse: Bool) async throws
    {
        let replies = [
            [
                RecoveryReply(status: 503, headers: ["Retry-After": "0"], body: "first", hold: true),
                try boundary.success(),
            ],
            [
                RecoveryReply(status: 504, headers: ["Retry-After": "0"], body: "second", hold: true),
                try boundary.success(),
            ],
        ]
        let fixtures = try replies.map { try InProcessHTTPFixture(replies: $0) }
        let recorders = fixtures.map { _ in RecoveryRecorder() }
        let gateways = zip(fixtures, recorders).map { boundary.gateway($0, policy: recoveryPolicy($1)) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for gateway in gateways {
                group.addTask {
                    let result = try await boundary.complete(gateway)
                    #expect(result.content == (boundary.structured ? #"{"answer":42}"# : "recovered"))
                }
            }
            // Both failed responses are in flight before either is allowed to finish.
            for fixture in fixtures { await fixture.requests.wait { $0.count == 1 } }
            let order = reverse ? [1, 0] : [0, 1]
            for index in order {
                fixtures[index].release()
                await fixtures[index].requests.wait { $0.count == 2 }
            }
            try await group.waitForAll()
        }
        for index in fixtures.indices {
            let identities = try assertStatusWires(
                recorders[index], server: fixtures[index], replies: replies[index])
            let failure = try #require(
                recorders[index].events.withLock { events in
                    events.first { $0.transition == .attemptFailed }
                })
            #expect(failure.status == replies[index][0].status)
            #expect(failure.progress.rawBytes == replies[index][0].body.utf8.count)
            #expect(identities.count == 2)
            #expect(
                identities.first?.logicalID
                    != recorders[1 - index].requests.withLock { $0.first?.0.logicalID })
        }
    }
}
