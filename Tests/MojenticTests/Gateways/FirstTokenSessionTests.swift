import Foundation
import Mojentic
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

struct FirstTokenSessionTests {
    @Test
    func encodingFailureRetainsOriginalErrorBeforeDispatch() async throws {
        let server = try RecoveryLoopback(replies: [])
        let gateway = OllamaGateway(baseURL: server.url)
        do {
            for try await _ in gateway.stream(
                model: "fixture", messages: [], tools: nil, config: .init(temperature: .nan))
            {
                Issue.record("Encoding failure must produce no stream events")
            }
            Issue.record("Expected typed encoding failure")
        } catch let error as MojenticError {
            guard case .transport(let message) = error else {
                Issue.record("Pre-dispatch encoding error was replaced")
                return
            }
            #expect(message.contains("Failed to encode streaming body"))
        }
        #expect(server.requests.withLock { $0.isEmpty })
    }

    @Test
    func measuredStreamingPreservesConfiguredSessionAuthentication() async throws {
        let boundary = StreamingBoundary(omlx: true, single: true, openAI: true)
        let server = try RecoveryLoopback(replies: [
            RecoveryReply(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"timing\""], body: "auth"),
            RecoveryReply(body: boundary.frame(content: "answer", done: true)),
        ])
        let delegate = TimingCredentialDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let gateway = OpenAIGateway(
            apiKey: "fixture", baseURL: server.url, client: HTTPClient(session: session))
        let result = try await firstTokenOutcome(boundary, gateway: gateway, recovering: false)
        try assertFirstToken(result, kind: "content", terminal: "completed")
        #expect(result.content == "answer")
        #expect(delegate.sessions.withLock { $0 } == [ObjectIdentifier(session)])
        let requests = server.requests.withLock { $0 }
        #expect(requests.count == 2)
        #expect(requests.first == requests.last)
        #expect(
            server.requestHeaders.withLock { $0.last?.lowercased().contains("authorization: basic") } == true)
    }
}

/// The lock protects identities reported on URLSession's delegate queue.
private final class TimingCredentialDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let sessions = RecoveryLocked<[ObjectIdentifier]>([])

    func urlSession(
        _ session: URLSession,
        task _: URLSessionTask,
        didReceive _: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        sessions.withLock { $0.append(ObjectIdentifier(session)) }
        completionHandler(
            .useCredential, URLCredential(user: "fixture", password: "secret", persistence: .none))
    }
}
