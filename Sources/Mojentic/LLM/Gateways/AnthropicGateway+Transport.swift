import Foundation

#if anthropic
    extension AnthropicGateway {
        /// Inject the line-oriented boundary while keeping public initialization unchanged.
        init(
            apiKey: String,
            baseURL: URL = AnthropicGateway.defaultBaseURL,
            apiVersion: String = AnthropicGateway.defaultAPIVersion,
            client: HTTPClient = HTTPClient(),
            registry: AnthropicModelRegistry = .shared,
            lineTransport: any LineStreamingTransport,
        ) {
            self.init(
                apiKey: apiKey,
                baseURL: baseURL,
                apiVersion: apiVersion,
                client: client,
                registry: registry,
            )
            self.lineTransport = lineTransport
        }
    }
#endif
