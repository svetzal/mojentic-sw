import Foundation
@testable import Mojentic
import Testing

struct RecoveryHeaderEncodingTests {
    @Test
    func headerOctetsAndUTF8BodyThroughRecovery() async throws {
        let replies = [
            RecoveryReply(status: 503, headers: ["X-Exact": "raw-évidence"], body: "é猫"),
            RecoveryReply(body: #"{"message":{"content":"recovered"},"done":true}"#),
        ]
        let server = try RecoveryLoopback(replies: replies)
        let recorder = RecoveryRecorder()
        let boundary = RecoveryBoundary(omlx: false, structured: false)
        let response = try await boundary.complete(boundary.gateway(server, policy: recoveryPolicy(recorder)))
        #expect(response.content == "recovered")
        let headers = try #require(server.responseHeaders.withLock { $0.first })
        let field = Data("X-Exact: raw-évidence\r\n".utf8)
        #expect(headers.range(of: field) != nil)
        let captured = recorder.wires.withLock { events in
            events.compactMap { event -> [String: String]? in
                if case .headers(_, 503, let fields) = event { return fields }
                return nil
            }
        }
        let first = normalizedHeaders(try #require(captured.first))
        #if os(Linux)
            #expect(first["x-exact"] == "raw-évidence")
        #else
            #expect(first["x-exact"] == "raw-Ã©vidence")
        #endif
        let identities = try assertStatusWires(recorder, server: server, replies: replies)
        #expect(identities.count == 2)
    }
}
