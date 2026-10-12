import Foundation
@testable import Mojentic

/// Selects a named public producer, independently of same-type sender scheduling.
final class SenderRegistrationSchedule: Sendable {
    let completed = RecoveryLocked<[(RecoveryIdentity, Data)]>([])
    let finished = RecoveryLocked<[String]>([])
    let producersCompleted = RecoveryLocked<[String]>([])
    let delivered = AsyncStream<Void>.makeStream()
    let arrived = AsyncStream<Void>.makeStream()
    let registration = RecoveryConsumerPause()
    let innerReady = RecoveryConsumerPause()
    let heldRole = RecoveryLocked<String?>(nil)
    private let roleCounts = RecoveryLocked<[String: Int]>([:])
    private let typeCounts = RecoveryLocked<[String: Int]>([:])
    private let trace: RecoveryCallTrace
    private let path: String
    private let target: String
    private let innerFirst: Bool

    init(trace: RecoveryCallTrace, path: String, target: String, innerFirst: Bool) {
        self.trace = trace
        self.path = path
        self.target = target
        self.innerFirst = innerFirst
    }

    func run(_ operation: () async throws -> Void) async rethrows {
        typealias HTTPTrace = @Sendable (String, RecoveryIdentity, Data, String) -> Void
        let onHTTP: HTTPTrace = { event, identity, bytes, _ in
            if event == "http.completed" { self.completed.withLock { $0.append((identity, bytes)) } }
        }
        let onDelivery: @Sendable () -> Void = {
            self.trace.record("progress.delivered")
            self.delivered.continuation.yield(())
        }
        let onFinish: @Sendable (String) -> Void = { type in
            self.trace.record("producer.finished", type)
            self.finished.withLock { $0.append(type) }
        }
        let onRegistration: @Sendable (String) async -> Void = { await self.beforeRegistration($0) }
        let onCompletion: @Sendable (String) -> Void = { role in
            self.trace.record("producer.completed", role)
            self.producersCompleted.withLock { $0.append(role) }
            self.trace.flushIfIdle()
        }
        try await RecoveryDeliveryScheduling.$httpTrace.withValue(onHTTP) {
            try await trace.scope {
                try await RecoveryDeliveryScheduling.$didDeliver.withValue(onDelivery) {
                    try await RecoveryDeliveryScheduling.$finished.withValue(onFinish) {
                        try await RecoveryDeliveryScheduling.$producerCompleted.withValue(onCompletion) {
                            try await RecoveryDeliveryScheduling.$beforeSenderRegistration.withValue(
                                onRegistration
                            ) { try await operation() }
                        }
                    }
                }
            }
        }
    }

    func beforeRegistration(_ type: String) async {
        let role = RecoveryDeliveryScheduling.sender ?? "unknown"
        let roleNumber = roleCounts.withLock { counts in
            counts[role, default: 0] += 1
            return counts[role, default: 0]
        }
        // Force the alternate legal interleaving without a sleep or timeout change.
        // The outer sender has not registered; neither the consumer nor fixture is released.
        if innerFirst, role == path, roleNumber == 1 {
            await innerReady.wait()
        }
        let number = typeCounts.withLock { counts in
            counts[type, default: 0] += 1
            return counts[type, default: 0]
        }
        trace.record("registration.arrived", "\(type) number=\(number) role=\(role) target=\(path)")
        if innerFirst, role == (path == "broker" ? "gateway" : "broker"), roleNumber == 2 {
            innerReady.resume()
        }
        if type == target, role == path, roleNumber == 1 {
            heldRole.withLock { $0 = role }
            trace.record("registration.held", "\(type) role=\(role)")
            arrived.continuation.yield(())
            await registration.wait()
            trace.record("registration.resumed", "\(type) role=\(role)")
        }
    }
}
