import Foundation

/// A single tool-call dispatch unit.
public struct ToolCallExecution: Sendable, Hashable {
    /// Opaque identifier carried through to the matching outcome.
    public let id: String
    /// Tool name to dispatch to.
    public let name: String
    /// Arguments forwarded to the tool's `execute` method.
    public let arguments: JSONValue

    /// Create a dispatch unit.
    public init(id: String, name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// Outcome of executing a single tool call.
///
/// Discriminated by `kind`: `.success(value)` wraps the tool result;
/// `.failure(message)` records the error message so tracing can persist it.
public struct ToolCallOutcome: Sendable, Hashable, Codable {
    /// Discriminator describing whether the tool returned a result or failed.
    public enum Kind: Sendable, Hashable, Codable {
        /// Tool returned a value.
        case success(JSONValue)
        /// Tool failed with a captured error message.
        case failure(message: String)
    }

    /// The id carried across from the matching `ToolCallExecution`.
    public let id: String
    /// The tool name that was dispatched.
    public let name: String
    /// Result discriminator + payload.
    public let kind: Kind

    /// Create an outcome record.
    public init(id: String, name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    /// True when the tool returned a successful result.
    public var ok: Bool {
        if case .success = kind { return true }
        return false
    }
}

/// Strategy for executing a batch of tool calls.
///
/// Output order must match input order regardless of how the implementation
/// schedules work. Phase 1 shipped `SerialToolRunner`; Phase 3 adds
/// ``ParallelToolRunner`` for opt-in concurrent execution.
public protocol ToolRunner: Sendable {
    /// Execute the supplied batch against the supplied tool registry, with
    /// observability wired through `tracer` and `context`.
    ///
    /// `context` carries the correlation id of the calling broker so emitted
    /// tracer events nest under that root.
    func runBatch(
        _ calls: [ToolCallExecution],
        tools: [any LLMTool],
        tracer: any Tracer,
        context: TracerContext
    ) async throws -> [ToolCallOutcome]
}

extension ToolRunner {
    /// Convenience overload for callers that don't yet wire a tracer.
    ///
    /// Default delegates to the tracer-aware overload using a fresh
    /// ``TracerContext`` and a ``NullTracer``.
    public func runBatch(
        _ calls: [ToolCallExecution],
        tools: [any LLMTool]
    ) async throws -> [ToolCallOutcome] {
        try await runBatch(
            calls,
            tools: tools,
            tracer: NullTracer(),
            context: TracerContext()
        )
    }
}

/// Tools that need the parent tracer context (e.g. ``ToolWrapper`` running a
/// nested broker call) can opt in by conforming to this protocol.
///
/// The runner detects the conformance and invokes ``executeWithContext`` so
/// the nested call's tracer events nest under the calling tool's events.
public protocol TracerContextAwareTool: LLMTool {
    /// Execute the tool with a tracer context derived from the parent call.
    func executeWithContext(
        arguments: JSONValue,
        tracer: any Tracer,
        context: TracerContext
    ) async throws -> JSONValue
}

/// Serial tool runner: dispatches one tool call at a time in input order.
///
/// `actor`-isolated so concurrent broker invocations cannot interleave their
/// batches against a shared runner instance.
public actor SerialToolRunner: ToolRunner {
    /// Create a serial runner.
    ///
    /// Runners are stateless across batches.
    public init() {}

    /// Run the supplied batch one call at a time in input order.
    public func runBatch(
        _ calls: [ToolCallExecution],
        tools: [any LLMTool],
        tracer: any Tracer,
        context: TracerContext
    ) async throws -> [ToolCallOutcome] {
        var outcomes: [ToolCallOutcome] = []
        outcomes.reserveCapacity(calls.count)
        for call in calls {
            try Task.checkCancellation()
            outcomes.append(
                await Self.execute(
                    call: call,
                    tools: tools,
                    tracer: tracer,
                    context: context
                )
            )
        }
        return outcomes
    }

    static func execute(
        call: ToolCallExecution,
        tools: [any LLMTool],
        tracer: any Tracer,
        context: TracerContext
    ) async -> ToolCallOutcome {
        guard let tool = tools.first(where: { $0.matches(call.name) }) else {
            return ToolCallOutcome(
                id: call.id,
                name: call.name,
                kind: .failure(message: "Tool '\(call.name)' not found")
            )
        }
        let callPayload = ToolCallPayload(
            correlationId: context.correlationId,
            parentId: context.parentId,
            callId: call.id,
            name: call.name,
            arguments: call.arguments
        )
        await tracer.recordToolCall(callPayload)
        let clock = ContinuousClock()
        let start = clock.now
        let childContext = context.child(parent: callPayload.id)
        let outcome: ToolCallOutcome
        do {
            let result: JSONValue
            if let aware = tool as? any TracerContextAwareTool {
                result = try await aware.executeWithContext(
                    arguments: call.arguments,
                    tracer: tracer,
                    context: childContext
                )
            } else {
                result = try await tool.execute(arguments: call.arguments)
            }
            outcome = ToolCallOutcome(id: call.id, name: call.name, kind: .success(result))
        } catch is CancellationError {
            outcome = ToolCallOutcome(
                id: call.id,
                name: call.name,
                kind: .failure(message: "Tool batch cancelled")
            )
        } catch {
            outcome = ToolCallOutcome(
                id: call.id,
                name: call.name,
                kind: .failure(message: String(describing: error))
            )
        }
        let duration = start.duration(to: clock.now)
        await tracer.recordToolResult(
            ToolResultPayload(
                correlationId: context.correlationId,
                parentId: callPayload.id,
                duration: duration,
                outcome: outcome
            )
        )
        return outcome
    }
}
