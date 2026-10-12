import Foundation
@testable import Mojentic
import Testing

/// Opt-in diagnostic evidence; records are buffered so delegates never write files.
///
/// This captures private scripted fixture bytes, independently of safe public descriptions.
final class RecoveryCallTrace: @unchecked Sendable {
    private struct Entry: Codable, Sendable {
        let time: TimeInterval
        let uptime: TimeInterval
        let event: String
        let detail: String
        let bytes: Data
        let identity: RecoveryIdentity?
        let logicalID: UUID?
        let progress: RecoveryProgress?
    }

    private let entries = RecoveryLocked<[Entry]>([])
    private let activeScopes = RecoveryLocked<Int>(0)
    private let flushLock = NSLock()
    private let destination: URL?

    init() {
        destination = ProcessInfo.processInfo.environment["RECOVERY_TRACE_DIRECTORY"].map {
            URL(fileURLWithPath: $0).appendingPathComponent("\(UUID()).json")
        }
    }

    deinit { flush() }

    func record(
        _ event: String,
        _ detail: String = "",
        bytes: Data = Data(),
        identity: RecoveryIdentity? = nil,
        logicalID: UUID? = nil,
        progress: RecoveryProgress? = nil,
    ) {
        guard destination != nil else { return }
        let entry = Entry(
            time: Date().timeIntervalSince1970,
            uptime: ProcessInfo.processInfo.systemUptime,
            event: event,
            detail: detail,
            bytes: bytes,
            identity: identity,
            logicalID: logicalID ?? identity?.logicalID,
            progress: progress,
        )
        entries.withLock { $0.append(entry) }
    }

    func flush() {
        guard let destination else { return }
        flushLock.lock()
        defer { flushLock.unlock() }
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries.withLock { $0 }).write(to: destination, options: .atomic)
        } catch {
            // A missing diagnostic is an evidence failure, never silently accepted.
            Issue.record("Recovery trace write failed: \(error)")
        }
    }

    func scope<T: Sendable>(_ operation: () async throws -> T) async rethrows -> T {
        guard destination != nil else { return try await operation() }
        activeScopes.withLock { $0 += 1 }
        defer {
            activeScopes.withLock { $0 -= 1 }
            flushIfIdle()
        }
        let delivery: @Sendable (String, String) -> Void = { self.record($0, $1) }
        let previous = RecoveryDeliveryScheduling.httpTrace
        let http: @Sendable (String, RecoveryIdentity, Data, String) -> Void = {
            self.record($0, $3, bytes: $2, identity: $1)
            previous?($0, $1, $2, $3)
        }
        let previousCompletion = RecoveryDeliveryScheduling.producerCompleted
        let completed: @Sendable (String) -> Void = {
            self.record("producer.completed", $0)
            previousCompletion?($0)
            self.flushIfIdle()
        }
        return try await RecoveryDeliveryScheduling.$trace.withValue(delivery) {
            try await RecoveryDeliveryScheduling.$producerCompleted.withValue(completed) {
                try await RecoveryDeliveryScheduling.$httpTrace.withValue(http) { try await operation() }
            }
        }
    }

    func flushIfIdle() {
        if activeScopes.withLock({ $0 }) == 0 { flush() }
    }

    func wire(_ event: RecoveryWireEvent) {
        guard destination != nil else { return }
        switch event {
        case .request(let identity, let url, let headers, let bytes):
            record("wire.request", "\(url) \(headers)", bytes: bytes, identity: identity)
        case .headers(let identity, let status, let headers):
            record("wire.headers", "status=\(status) \(headers)", identity: identity)
        case .body(let identity, let bytes):
            record("wire.body", bytes: bytes, identity: identity)
        }
    }

    func attach(to policy: inout CompletionRecoveryPolicy) {
        guard destination != nil else { return }
        policy.httpTrace = { self.record($0, $3, bytes: $2, identity: $1) }
    }

    func lifecycle(_ event: RecoveryEvent) {
        guard destination != nil else { return }
        record(
            "lifecycle",
            event.transition.rawValue,
            identity: event.identity,
            logicalID: event.logicalID,
            progress: event.progress,
        )
    }

    func report(_ report: CompletionRecoveryReport) {
        guard destination != nil else { return }
        record("report", identity: report.identity, logicalID: report.logicalID, progress: report.progress)
        for failure in report.history {
            let evidence = failure.inspectEvidence()
            let cause = evidence.cause.map { $0 as NSError }
            record(
                "report.attempt",
                "\(failure.category) cause=\(cause?.domain ?? "none")/\(cause?.code ?? 0)",
                bytes: evidence.body,
                identity: failure.identity,
                progress: failure.progress,
            )
        }
    }
}
