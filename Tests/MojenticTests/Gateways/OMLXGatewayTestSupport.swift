import Foundation
import Testing

@testable import Mojentic

/// The model the oMLX fixtures were captured from.
let omlxFixtureModel = "Qwen3.8-27B-MLX-8bit"

/// An oMLX gateway wired to fake transports.
func omlxGateway(
    _ transport: FakeRequestTransport = FakeRequestTransport(),
    lines: FakeLineTransport = FakeLineTransport(),
    configuration: OMLXConfiguration = OMLXConfiguration()
) -> OMLXGateway {
    OMLXGateway(configuration: configuration, transport: transport, lineTransport: lines)
}

/// The decoded JSON body of `request`.
func jsonBody(_ request: TransportRequest) throws -> [String: JSONValue] {
    try #require(request.body?.objectValue, "request had no JSON object body")
}

/// Run `operation` and return the status and body of the HTTP error it throws.
func httpFailure(_ operation: () async throws -> Void) async -> (status: Int, body: String)? {
    do {
        try await operation()
    } catch MojenticError.http(let status, let body) {
        return (status, body)
    } catch {
        Issue.record("expected an HTTP error, got \(error)")
        return nil
    }
    Issue.record("expected an HTTP error, got success")
    return nil
}

/// A tool whose descriptor the gateway forwards; it is never executed here.
struct ResolveDateTool: LLMTool {
    let descriptor = ToolDescriptor(
        name: "resolve_date",
        description: "Resolve a relative date",
        parameters: [
            "type": "object",
            "properties": ["relative": ["type": "string"]],
            "required": ["relative"],
        ]
    )

    func execute(arguments: JSONValue) async throws -> JSONValue { arguments }
}
