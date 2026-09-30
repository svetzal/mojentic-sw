import Foundation
import Testing

@testable import Mojentic

@Suite("oMLX configuration")
struct OMLXConfigurationTests {
    private func resolve(
        host: URL? = nil,
        apiKey: String? = nil,
        timeout: TimeInterval? = nil,
        environment: [String: String] = [:]
    ) -> OMLXConfiguration {
        OMLXConfiguration.resolve(host: host, apiKey: apiKey, timeout: timeout, environment: environment)
    }

    private let environment = [
        "OMLX_HOST": "http://studio.local:9000",
        "OMLX_API_KEY": "env-key",
        "OMLX_TIMEOUT": "1500",
    ]

    @Test("defaults to localhost:8000, no key and ten minutes")
    func defaults() {
        let configuration = resolve()
        #expect(configuration.host.absoluteString == "http://localhost:8000")
        #expect(configuration.apiKey == nil)
        #expect(configuration.timeout == 600)
    }

    @Test("the environment applies when no explicit value is given; OMLX_TIMEOUT is milliseconds")
    func environmentValues() {
        let configuration = resolve(environment: environment)
        #expect(configuration.host.absoluteString == "http://studio.local:9000")
        #expect(configuration.apiKey == "env-key")
        #expect(configuration.timeout == 1.5)
    }

    @Test("an explicit empty key disables environment authentication")
    func explicitEmptyKey() {
        #expect(resolve(apiKey: "", environment: environment).apiKey == nil)
    }

    @Test("explicit values take precedence over the environment")
    func explicitWins() throws {
        let host = try #require(URL(string: "http://mac.local:8123"))
        let configuration = resolve(host: host, apiKey: "explicit", timeout: 30, environment: environment)
        #expect(configuration.host == host)
        #expect(configuration.apiKey == "explicit")
        #expect(configuration.timeout == 30)
    }

    @Test(
        "empty or unusable environment values fall back to the defaults",
        arguments: ["", "soon", "0", "-5"]
    )
    func unusableEnvironment(value: String) {
        let configuration = resolve(
            environment: ["OMLX_HOST": "", "OMLX_API_KEY": "", "OMLX_TIMEOUT": value]
        )
        #expect(configuration == OMLXConfiguration())
    }

    @Test("the gateway adds /v1 to the host", arguments: ["http://localhost:8000", "http://localhost:8000/"])
    func versionPrefix(host: String) throws {
        let configuration = OMLXConfiguration(host: try #require(URL(string: host)))
        #expect(configuration.baseURL.absoluteString == "http://localhost:8000/v1")
    }

    @Test("requests go to host/v1 with the configured timeout and no authorization without a key")
    func requestWithoutKey() async throws {
        let transport = FakeRequestTransport(try .fixture("chat_thinking_disabled.json"))
        _ = try await omlxGateway(transport).complete(
            model: omlxFixtureModel,
            messages: [.user("hi")],
            tools: nil,
            config: CompletionConfig()
        )
        let request = try await transport.onlyRequest()
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "http://localhost:8000/v1/chat/completions")
        #expect(request.timeout == 600)
        #expect(request.headers["Authorization"] == nil)
    }

    @Test("an API key is sent as a bearer token")
    func requestWithKey() async throws {
        let transport = FakeRequestTransport(try .fixture("models.json"))
        _ = try await omlxGateway(transport, configuration: OMLXConfiguration(apiKey: "secret"))
            .availableModels()
        let request = try await transport.onlyRequest()
        #expect(request.headers["Authorization"] == "Bearer secret")
    }
}
