import Foundation
@testable import Mojentic
import Testing

@Suite(.serialized)
struct RecoveryMetadataIdentityTests {
    @Test
    func publicBoundaryIdentity() async throws {
        let boundary = StreamingBoundary(omlx: false, single: false)
        let body = try boundary.frame(content: "é", done: true, metrics: true)
        let server = try InProcessHTTPFixture(replies: [RecoveryReply(body: body)])
        let recorder = RecoveryRecorder()
        let gateway = boundary.gateway(server, recoveryPolicy(recorder))
        var frames: [RecoveryProgress] = []
        for try await event in gateway.streamRecovering(
            model: "fixture", messages: [.user("identity")], tools: nil, config: .init(),
        ) {
            if case .progress(let progress) = event {
                frames.append(progress)
                let object = try #require(
                    JSONSerialization.jsonObject(with: JSONEncoder().encode(progress)) as? [String: Any]
                )
                let identity = try #require(object["identity"] as? [String: Any])
                let wire = try #require(recorder.requests.withLock { $0.first?.0 })
                #expect(identity["logicalID"] as? String == wire.logicalID.uuidString)
                #expect(identity["attemptID"] as? String == wire.attemptID.uuidString)
                #expect(identity["wireNumber"] as? Int == wire.wireNumber)
            }
        }
        #expect(frames.map(\.frameIndex) == [1])
        #expect(frames.map(\.observed.contentBytes) == [2])
        #expect(server.requests.withLock { $0 } == recorder.requests.withLock { $0.map(\.1) })
    }
}
