import Foundation
import Testing

@testable import Mojentic

/// Loads the live oMLX fixtures copied into the test bundle.
///
/// See `Tests/MojenticTests/Fixtures/omlx/README.md` for their provenance.
enum OMLXFixture {
    /// The raw bytes of the fixture file called `name`.
    static func data(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/omlx"),
            "missing fixture \(name)"
        )
        return try Data(contentsOf: url)
    }

    /// The lines of fixture `name`, as a line-streaming transport yields them.
    static func lines(_ name: String) throws -> [String] {
        let text = try #require(String(bytes: try data(name), encoding: .utf8))
        return text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    }
}

/// One scripted reply from a ``FakeRequestTransport``.
enum ScriptedReply: Sendable {
    /// A 2xx response with `body` and `headers`.
    case success(Data, headers: [HTTPHeader] = [])
    /// A non-2xx response, thrown as the real transport does.
    case failure(status: Int, body: Data)

    /// A 2xx response whose body is fixture `name`.
    static func fixture(_ name: String, headers: [HTTPHeader] = []) throws -> ScriptedReply {
        .success(try OMLXFixture.data(name), headers: headers)
    }

    /// A non-2xx response whose body is fixture `name`.
    static func fixture(_ name: String, status: Int) throws -> ScriptedReply {
        .failure(status: status, body: try OMLXFixture.data(name))
    }
}

/// Records the requests a ``FakeRequestTransport`` was asked to send.
actor RequestRecorder {
    private(set) var requests: [TransportRequest] = []

    func record(_ request: TransportRequest) {
        requests.append(request)
    }
}

/// Scripted stand-in for the buffered HTTP boundary.
///
/// Answers every request with `reply`, and records each request.
struct FakeRequestTransport: RequestTransport {
    let reply: ScriptedReply
    let recorder = RequestRecorder()

    init(_ reply: ScriptedReply = .success(Data("{}".utf8))) {
        self.reply = reply
    }

    func send(_ request: TransportRequest) async throws -> TransportResponse {
        await recorder.record(request)
        switch reply {
        case .success(let body, let headers):
            return TransportResponse(body: body, headers: headers)
        case .failure(let status, let body):
            throw MojenticError.http(status: status, body: String(bytes: body, encoding: .utf8) ?? "")
        }
    }

    /// The only request sent; fails the test when there was not exactly one.
    func onlyRequest() async throws -> TransportRequest {
        let requests = await recorder.requests
        return try #require(
            requests.count == 1 ? requests.first : nil, "expected one request, got \(requests.count)")
    }
}
