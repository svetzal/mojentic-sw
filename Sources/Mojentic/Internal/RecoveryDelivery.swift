import Foundation

/// Internal scheduling seam for the cancellation/registration interleaving.
enum RecoveryDeliveryScheduling {
    typealias HTTPTrace = @Sendable (String, RecoveryIdentity, Data, String) -> Void
    @TaskLocal static var trace: (@Sendable (String, String) -> Void)?
    @TaskLocal static var httpTrace: HTTPTrace?
    @TaskLocal static var sender: String?
    @TaskLocal static var producerCompleted: (@Sendable (String) -> Void)?
    @TaskLocal static var beforeSessionIteration: (@Sendable () async -> Void)?
    @TaskLocal static var didDeliver: (@Sendable () -> Void)?
    @TaskLocal static var finished: (@Sendable (String) -> Void)?
    @TaskLocal static var beforeSenderRegistration: (@Sendable (String) async -> Void)?
}

/// A rendezvous prevents buffered terminal metadata from establishing success.
///
/// The lock protects producer and consumer continuations; no user code runs under it.
final class RecoveryDelivery<Element: Sendable>: @unchecked Sendable {
    private let trace = RecoveryDeliveryScheduling.trace
    private let traceID = RecoveryDeliveryScheduling.trace.map { _ in UUID() }
    private let traceRole: String
    private typealias Sender = CheckedContinuation<Void, any Error>
    private typealias Reader = CheckedContinuation<Element?, any Error>
    private let lock = NSLock()
    private var pending: (Element, CheckedContinuation<Void, any Error>)?
    private var reader: CheckedContinuation<Element?, any Error>?
    private var cancellationRequested = false
    private var finalElement: Element?
    private var end: Result<Void, any Error>?

    init(traceRole: String = "gateway") {
        self.traceRole = traceRole
    }

    func send(_ element: Element) async throws {
        record("send.enter", element: element)
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            if let hook = RecoveryDeliveryScheduling.beforeSenderRegistration {
                await RecoveryDeliveryScheduling.$sender.withValue(traceRole) {
                    await hook(String(reflecting: Element.self))
                }
            }
            record("send.register", element: element)
            try await withCheckedThrowingContinuation { (continuation: Sender) in
                let action = lock.withLock { () -> (() -> Void) in
                    if cancellationRequested {
                        return { continuation.resume(throwing: CancellationError()) }
                    }
                    if let end {
                        return { continuation.resume(with: end) }
                    }
                    if let reader {
                        self.reader = nil
                        return {
                            reader.resume(returning: element)
                            continuation.resume()
                        }
                    }
                    pending = (element, continuation)
                    return {}
                }
                action()
            }
        } onCancel: {
            self.cancelSender()
        }
    }

    func next() async throws -> Element? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: Reader) in
                let action = lock.withLock { () -> (() -> Void) in
                    if cancellationRequested || Task.isCancelled, let pending {
                        self.pending = nil
                        reader = continuation
                        return { pending.1.resume(throwing: CancellationError()) }
                    }
                    if let pending {
                        self.pending = nil
                        return {
                            continuation.resume(returning: pending.0)
                            pending.1.resume()
                        }
                    }
                    if let finalElement {
                        self.finalElement = nil
                        return { continuation.resume(returning: finalElement) }
                    }
                    if let end {
                        return { continuation.resume(with: end.map { nil }) }
                    }
                    reader = continuation
                    return {}
                }
                action()
            }
        } onCancel: {
            // The enclosing stream cancels its producer; this reader awaits its cleanup.
        }
    }

    func cancel() {
        cancelSender()
    }

    private func cancelSender() {
        record("send.cancel")
        let sender = lock.withLock {
            // Remember cancellation even if the sender has not registered yet.
            // Registration and removal observe this state under the same lock.
            cancellationRequested = true
            let sender = pending?.1
            pending = nil
            return sender
        }
        sender?.resume(throwing: CancellationError())
    }

    /// Cancellation can still deliver one typed terminal event after producer cleanup.
    func terminal(_ element: Element) {
        record("terminal", element: element)
        let waiting = lock.withLock {
            let waiting = reader
            reader = nil
            if waiting == nil {
                finalElement = element
            }
            end = .success(())
            return waiting
        }
        waiting?.resume(returning: element)
    }

    func finish(_ error: (any Error)? = nil) {
        if trace != nil { record("finish", detail: String(describing: error)) }
        defer { RecoveryDeliveryScheduling.finished?(String(reflecting: Element.self)) }
        let result: Result<Void, any Error> = error.map(Result.failure) ?? .success(())
        let saved = lock.withLock {
            if end != nil {
                return (nil, nil)
                    as (CheckedContinuation<Element?, any Error>?, CheckedContinuation<Void, any Error>?)
            }
            end = result
            let saved = (reader, pending?.1)
            reader = nil
            pending = nil
            return saved
        }
        saved.0?.resume(with: result.map { nil })
        saved.1?.resume(with: result)
    }

    private func record(_ event: String, element: Element? = nil, detail: String = "") {
        guard let trace else { return }
        let sender = "\(traceID?.uuidString ?? "") role=\(traceRole) \(String(reflecting: Element.self))"
        trace(event, "\(sender) \(String(describing: element)) \(detail)")
    }
}

/// Stream lifetime owns the producer task without a producer-to-owner cycle.
final class RecoveryProducer: Sendable {
    let task: Task<Void, Never>
    init(_ task: Task<Void, Never>, traceRole: String = "gateway") {
        self.task = task
        if let completed = RecoveryDeliveryScheduling.producerCompleted {
            Task {
                await task.value
                completed(traceRole)
            }
        }
    }

    deinit { task.cancel() }
}
