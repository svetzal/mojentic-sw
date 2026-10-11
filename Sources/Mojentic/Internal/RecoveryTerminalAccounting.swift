import Foundation

/// Scoped relays retain one actual attempt until their public terminal is accepted.
///
/// Broker tool turns settle before tool execution; nested session relays share the
/// outer receipt. The lock transfers ownership of the callback, never runs it.
final class RecoveryTerminalAccounting: @unchecked Sendable {
    @TaskLocal static var current: RecoveryTerminalAccounting?
    private let lock = NSLock()
    private var pending: (@Sendable ((any Error)?) -> RecoveryError?)?

    func retain(_ finalize: @escaping @Sendable ((any Error)?) -> RecoveryError?) {
        lock.withLock {
            precondition(pending == nil, "A scoped relay settles each turn before starting the next")
            pending = finalize
        }
    }

    @discardableResult
    func settle(_ error: (any Error)? = nil) -> RecoveryError? {
        let finalize = lock.withLock {
            let saved = pending
            pending = nil
            return saved
        }
        return finalize?(error)
    }
}
