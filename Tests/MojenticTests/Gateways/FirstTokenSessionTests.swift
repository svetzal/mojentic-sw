import Foundation
@testable import Mojentic
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Suite(DeterministicStreamTime(), .serialized)
struct FirstTokenSessionTests {
    @Test
    func encodingFailureRetainsOriginalErrorBeforeDispatch() async throws {
        let server = try InProcessHTTPFixture(replies: [])
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
    func measuredStreamingPreservesConfiguredSessionAndHeaders() async throws {
        let boundary = StreamingBoundary(omlx: true, single: true, openAI: true)
        let server = try InProcessHTTPFixture(replies: [
            RecoveryReply(status: 503, body: "configured-session-response")
        ])
        let configuration = server.sessionConfiguration
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let gateway = OpenAIGateway(
            apiKey: "fixture", baseURL: server.url, client: HTTPClient(session: session))
        let result = try await firstTokenOutcome(boundary, gateway: gateway, recovering: false)
        try assertFirstToken(result, kind: nil, terminal: "error")
        guard case .providerError(let status, let detail) = result.failure as? MojenticError else {
            Issue.record("Configured session must preserve the typed HTTP response")
            return
        }
        #expect(status == 503)
        #expect(detail == .string("configured-session-response"))
        #expect(result.content.isEmpty)
        #expect(server.requests.withLock { $0.count } == 1)
        let headers = try #require(server.requestHeaders.withLock { $0.first }).lowercased()
        #expect(headers.contains("authorization: bearer fixture"))
    }

    @Test
    func measuredStreamingForwardsAuthenticationToOriginalSession() async throws {
        let boundary = StreamingBoundary(omlx: true, single: true, openAI: true)
        let server = try InProcessHTTPFixture(
            replies: [
                RecoveryReply(
                    status: 401, headers: ["WWW-Authenticate": "Basic realm=\"timing\""], body: "auth")
            ], authenticationChallenge: true)
        let delegate = TimingCredentialDelegate()
        let session = URLSession(
            configuration: server.sessionConfiguration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let gateway = OpenAIGateway(
            apiKey: "fixture", baseURL: server.url, client: HTTPClient(session: session))
        let result = try await firstTokenOutcome(boundary, gateway: gateway, recovering: false)
        #expect(delegate.sessions.withLock { $0 } == [ObjectIdentifier(session)])
        #expect(delegate.methods.withLock { $0 } == [NSURLAuthenticationMethodHTTPBasic])
        #expect(result.failure != nil)
        #expect(result.content.isEmpty)
        #expect(server.requests.withLock { $0.count } == 1)
        try assertFirstToken(result, kind: nil, terminal: "error")
    }

}

/// The lock protects identities reported on URLSession's delegate queue.
private final class TimingCredentialDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let sessions = RecoveryLocked<[ObjectIdentifier]>([])
    let methods = RecoveryLocked<[String]>([])

    func urlSession(
        _ session: URLSession,
        task _: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        sessions.withLock { $0.append(ObjectIdentifier(session)) }
        methods.withLock { $0.append(challenge.protectionSpace.authenticationMethod) }
        // Cancel in process: FoundationNetworking's credential retry bypasses
        // URLProtocol and attempts a real connection, which is outside this suite.
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}
