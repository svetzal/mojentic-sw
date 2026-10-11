import Foundation
@testable import Mojentic
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A body shorter than its advertised length is a lost connection on every platform.
struct RecoveryLostConnectionTests {
    private func response(status: Int, headers: [String: String]) throws -> HTTPURLResponse {
        let url = try #require(URL(string: "http://127.0.0.1"))
        return try #require(
            HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers,
            )
        )
    }

    @Test(arguments: [200, 400, 403, 503])
    func shortIdentityBodyIsLostConnection(_ status: Int) throws {
        let short = try response(status: status, headers: ["Content-Length": "36"])
        #expect(RecoveryHTTP.lostConnection(response: short, received: 16)?.code == .networkConnectionLost)
        let identity = try response(
            status: status, headers: ["Content-Length": "36", "Content-Encoding": "Identity"],
        )
        #expect(RecoveryHTTP.lostConnection(response: identity, received: 16)?.code == .networkConnectionLost)
    }

    @Test
    func completeUnknownCodedOrBodilessResponsesAreNotLost() throws {
        let complete = try response(status: 403, headers: ["Content-Length": "16"])
        #expect(RecoveryHTTP.lostConnection(response: complete, received: 16) == nil)
        let chunked = try response(status: 403, headers: ["Transfer-Encoding": "chunked"])
        #expect(RecoveryHTTP.lostConnection(response: chunked, received: 16) == nil)
        // URLSession delivers decoded bytes but advertises the encoded length.
        let gzip = try response(status: 200, headers: ["Content-Length": "36", "Content-Encoding": "gzip"])
        #expect(RecoveryHTTP.lostConnection(response: gzip, received: 16) == nil)
        let notModified = try response(status: 304, headers: ["Content-Length": "36"])
        #expect(RecoveryHTTP.lostConnection(response: notModified, received: 0) == nil)
        #expect(RecoveryHTTP.lostConnection(response: nil, received: 0) == nil)
    }
}
