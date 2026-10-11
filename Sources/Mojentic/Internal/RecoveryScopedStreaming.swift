import Foundation

/// Keeps scoped broker/session relays from draining terminal metadata into buffers.
enum RecoveryScopedStreaming {
    typealias Delivery<Element: Sendable> = @Sendable (Element) async throws -> Void
    typealias Operation<Element: Sendable> = @Sendable (@escaping Delivery<Element>) async throws -> Void
    typealias CompletionDelivery = Delivery<RecoveryCompletionStreamEvent>
    typealias CompletionRelay =
        @Sendable (@escaping CompletionDelivery) async throws -> RecoveryCompletionStreamEvent

    static func throwing<Element: Sendable>(
        operation: @escaping Operation<Element>
    ) -> AsyncThrowingStream<Element, any Error> {
        let delivery = RecoveryDelivery<Element>()
        let scope = RecoveryCancellationScope.current
        let id = UUID()
        scope?.prepare(id)
        let inherited = RecoveryTerminalAccounting.current
        let accounting = inherited ?? RecoveryTerminalAccounting()
        let task = Task {
            await RecoveryTerminalAccounting.$current.withValue(accounting) {
                defer { scope?.remove(id) }
                do {
                    try await operation { try await delivery.send($0) }
                    if inherited == nil {
                        accounting.settle()
                    }
                    delivery.finish()
                } catch {
                    let failure = inherited == nil ? accounting.settle(error) : nil
                    delivery.finish(failure ?? (error is CancellationError ? MojenticError.cancelled : error))
                }
            }
        }
        scope?.register(task, id: id)
        let owner = RecoveryProducer(task)
        return AsyncThrowingStream(unfolding: {
            try await withTaskCancellationHandler {
                try await delivery.next()
            } onCancel: {
                delivery.cancel()
                owner.task.cancel()
            }
        })
    }

    static func completion(
        operation: @escaping CompletionRelay
    ) -> AsyncStream<RecoveryCompletionStreamEvent> {
        let delivery = RecoveryDelivery<RecoveryCompletionStreamEvent>()
        let scope = RecoveryCancellationScope.current
        let id = UUID()
        scope?.prepare(id)
        let inherited = RecoveryTerminalAccounting.current
        let accounting = inherited ?? RecoveryTerminalAccounting()
        let task = Task {
            await RecoveryTerminalAccounting.$current.withValue(accounting) {
                defer { scope?.remove(id) }
                do {
                    let terminal = try await operation { try await delivery.send($0) }
                    try await delivery.send(terminal)
                    if inherited == nil {
                        accounting.settle()
                    }
                } catch {
                    if let failure = inherited == nil ? accounting.settle(error) : nil {
                        delivery.terminal(.recoveryFailure(failure))
                    } else if let failure = error as? RecoveryError {
                        delivery.terminal(.recoveryFailure(failure))
                    } else {
                        delivery.terminal(.error(.cancelled))
                    }
                }
                delivery.finish()
            }
        }
        scope?.register(task, id: id)
        let owner = RecoveryProducer(task)
        return AsyncStream(
            unfolding: { try? await delivery.next() },
            onCancel: {
                delivery.cancel()
                owner.task.cancel()
            },
        )
    }
}
