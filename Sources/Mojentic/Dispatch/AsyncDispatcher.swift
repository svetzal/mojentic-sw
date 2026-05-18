import Foundation
import Logging

/// Event dispatcher that drives a ``Router`` of agents.
///
/// Internally owns an `AsyncStream<any Event>` queue and a consumer task.
/// Each dequeued event is routed to its subscribers and handled in a
/// `TaskGroup`; any events the agents emit are re-dispatched. Tracer
/// `agentLifecycle` events are recorded for each handle so the existing
/// tracer correlation tree extends across the agent system.
public actor AsyncDispatcher {
    private let router: Router
    private let tracer: any Tracer
    private let logger: Logger

    private var continuation: AsyncStream<any Event>.Continuation?
    private var consumer: Task<Void, Never>?
    private var inflight = 0
    private var queued = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    /// Create a dispatcher around a router, with optional tracer.
    public init(router: Router, tracer: any Tracer = NullTracer()) {
        self.router = router
        self.tracer = tracer
        self.logger = Logger(label: "mojentic.dispatcher")
    }

    /// Begin consuming dispatched events.
    ///
    /// Idempotent: calling `start()` on an already-running dispatcher is a
    /// no-op.
    public func start() {
        guard consumer == nil else { return }
        let (stream, continuation) = AsyncStream<any Event>.makeStream()
        self.continuation = continuation
        consumer = Task { [weak self] in
            for await event in stream {
                guard let self else { break }
                await self.process(event)
                await self.completeOne()
            }
        }
    }

    /// Stop consuming and drop any in-flight stream.
    public func stop() {
        continuation?.finish()
        continuation = nil
        consumer?.cancel()
        consumer = nil
    }

    /// Enqueue an event for processing.
    public func dispatch(_ event: any Event) {
        guard let continuation else {
            logger.warning("Dispatch called before start(); event dropped")
            return
        }
        queued += 1
        continuation.yield(event)
    }

    /// Suspend the caller until the queue is fully drained and all in-flight
    /// handlers have returned.
    public func wait() async {
        guard inflight > 0 || queued > 0 else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            idleWaiters.append(continuation)
        }
    }

    // MARK: - Internals

    private func process(_ event: any Event) async {
        inflight += 1
        queued -= 1
        let agents = await router.route(event)
        guard !agents.isEmpty else { return }
        await withTaskGroup(of: [any Event].self) { group in
            for agent in agents {
                let agentName = String(describing: type(of: agent))
                let tracer = self.tracer
                group.addTask { @Sendable in
                    await tracer.recordAgentLifecycle(
                        AgentLifecyclePayload(
                            correlationId: event.correlationId,
                            parentId: event.parentId,
                            agentName: agentName,
                            phase: .started
                        )
                    )
                    do {
                        let emitted = try await agent.handle(event)
                        await tracer.recordAgentLifecycle(
                            AgentLifecyclePayload(
                                correlationId: event.correlationId,
                                parentId: event.parentId,
                                agentName: agentName,
                                phase: .finished
                            )
                        )
                        return emitted
                    } catch {
                        await tracer.recordAgentLifecycle(
                            AgentLifecyclePayload(
                                correlationId: event.correlationId,
                                parentId: event.parentId,
                                agentName: agentName,
                                phase: .failed,
                                detail: String(describing: error)
                            )
                        )
                        return [
                            ErrorEvent(
                                description: String(describing: error),
                                correlationId: event.correlationId,
                                parentId: event.parentId
                            )
                        ]
                    }
                }
            }
            for await emitted in group {
                for follow in emitted {
                    dispatch(follow)
                }
            }
        }
    }

    private func completeOne() {
        inflight -= 1
        guard inflight == 0 && queued == 0 else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
