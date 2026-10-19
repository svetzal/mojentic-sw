import Foundation
import Mojentic
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A custom scheme makes network fallback impossible, even if interception fails.
final class RecoverySeamProbeProtocol: URLProtocol {
    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "mojentic-probe"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"message":{"content":"in-process"},"done":true}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct RecoveryTransportSeamProbeTests {
    @Test(arguments: [false, true])
    func publicCompletionUsesInProcessTransport(_ recovering: Bool) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecoverySeamProbeProtocol.self]
        let registered = URLProtocol.registerClass(RecoverySeamProbeProtocol.self)
        defer { URLProtocol.unregisterClass(RecoverySeamProbeProtocol.self) }
        #expect(registered)
        var policy = CompletionRecoveryPolicy()
        policy.timing = deterministicRecoveryTiming()
        policy.maximumAttempts = 1
        let gateway = OllamaGateway(
            baseURL: try #require(URL(string: "mojentic-probe://isolated")),
            client: HTTPClient(session: URLSession(configuration: configuration)),
            recovery: recovering ? policy : nil)
        let response = try await gateway.complete(
            model: "fixture", messages: [.user("request")], tools: nil, config: CompletionConfig())
        #expect(response.content == "in-process")
    }
}
