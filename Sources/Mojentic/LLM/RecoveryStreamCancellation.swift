import Foundation

/// Owns local recovery producers throughout a consumer operation, including pauses.
///
/// Create and consume recovery streams inside `operation`. Cancelling the caller
/// cancels their locally owned HTTP tasks even while the consumer awaits unrelated
/// work. Scope exit also cancels unfinished producers. This does not establish
/// remote request termination. Streams created outside the scope retain their
/// ordinary iteration and lifetime cancellation behavior.
///
/// The scope is inherited by broker and session tasks. It does not propagate into
/// detached tasks; create and consume those streams in their own scope.
///
/// - Parameter operation: The operation that creates and consumes recovery streams.
/// - Returns: The operation's result.
/// - Throws: Any error thrown by the operation.
public func withRecoveryStreamCancellation<Result: Sendable>(
    operation: @Sendable () async throws -> Result
) async rethrows -> Result {
    let scope = RecoveryCancellationScope()
    defer { scope.cancel() }
    return try await withTaskCancellationHandler {
        try await RecoveryCancellationScope.$current.withValue(scope) { try await operation() }
    } onCancel: {
        scope.cancel()
    }
}

/// The lock serializes registration with cancellation; callbacks run outside it.
final class RecoveryCancellationScope: @unchecked Sendable {
    @TaskLocal static var current: RecoveryCancellationScope?
    private let lock = NSLock()
    private var cancelled = false
    private enum Producer {
        case starting
        case running(Task<Void, Never>)
    }

    private var producers: [UUID: Producer] = [:]

    func prepare(_ id: UUID) {
        lock.withLock {
            if !cancelled {
                producers[id] = .starting
            }
        }
    }

    func register(_ task: Task<Void, Never>, id: UUID) {
        let cancel = lock.withLock {
            if cancelled || producers[id] == nil {
                return true
            }
            producers[id] = .running(task)
            return false
        }
        if cancel {
            task.cancel()
        }
    }

    func remove(_ id: UUID) {
        _ = lock.withLock { producers.removeValue(forKey: id) }
    }

    func cancel() {
        let tasks = lock.withLock {
            cancelled = true
            let tasks = producers.values.compactMap { producer -> Task<Void, Never>? in
                if case .running(let task) = producer {
                    return task
                }
                return nil
            }
            producers.removeAll()
            return tasks
        }
        for task in tasks {
            task.cancel()
        }
    }
}
