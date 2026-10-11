import Foundation
@testable import Mojentic

/// Persist synthetic HTTP evidence only when the foreground harness requests it.
func retainStopSequenceCapture(
    _ recorder: RecoveryRecorder, _ server: RecoveryLoopback, entrypoint: String,
) throws {
    guard let path = ProcessInfo.processInfo.environment["STOP_SEQUENCE_EVIDENCE_DIR"] else { return }
    let encoder = JSONEncoder()
    var wires: [JSONValue] = []
    for event in recorder.wires.withLock({ $0 }) {
        let identity: RecoveryIdentity
        var fields: [String: JSONValue]
        switch event {
        case .request(let value, let url, let headers, let bytes):
            identity = value
            fields = [
                "kind": "request", "url": .string(url.absoluteString),
                "headers": .object(headers.mapValues(JSONValue.string)),
                "bytes_base64": .string(bytes.base64EncodedString()),
            ]
        case .headers(let value, let status, let headers):
            identity = value
            fields = [
                "kind": "headers", "status": .integer(status),
                "headers": .object(headers.mapValues(JSONValue.string)),
            ]
        case .body(let value, let bytes):
            identity = value
            fields = ["kind": "body", "bytes_base64": .string(bytes.base64EncodedString())]
        }
        fields["identity"] = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(identity))
        wires.append(.object(fields))
    }
    let capture: JSONValue = try [
        "entrypoint": .string(entrypoint), "wire_events": .array(wires),
        "socket_request_headers": .array(server.requestHeaders.withLock { $0.map(JSONValue.string) }),
        "socket_request_bodies_base64": .array(
            server.requests.withLock {
                $0.map { .string($0.base64EncodedString()) }
            }
        ),
        "lifecycle": JSONDecoder().decode(
            JSONValue.self, from: encoder.encode(recorder.events.withLock { $0 }),
        ),
    ]
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try encoder.encode(capture).write(
        to: directory.appendingPathComponent("\(entrypoint).json"), options: .atomic,
    )
}
