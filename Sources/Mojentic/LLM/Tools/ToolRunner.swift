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
public struct ToolCallOutcome: Sendable, Hashable {
    /// Discriminator describing whether the tool returned a result or failed.
    public enum Kind: Sendable, Hashable {
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
/// schedules work. Phase 1 ships `SerialToolRunner`; a parallel runner
/// follows in Phase 3.
public protocol ToolRunner: Sendable {
    /// Execute the supplied batch against the supplied tool registry.
    func runBatch(
        _ calls: [ToolCallExecution],
        tools: [any LLMTool]
    ) async throws -> [ToolCallOutcome]
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
        tools: [any LLMTool]
    ) async throws -> [ToolCallOutcome] {
        var outcomes: [ToolCallOutcome] = []
        outcomes.reserveCapacity(calls.count)
        for call in calls {
            try Task.checkCancellation()
            outcomes.append(await Self.execute(call: call, tools: tools))
        }
        return outcomes
    }

    private static func execute(
        call: ToolCallExecution,
        tools: [any LLMTool]
    ) async -> ToolCallOutcome {
        guard let tool = tools.first(where: { $0.matches(call.name) }) else {
            return ToolCallOutcome(
                id: call.id,
                name: call.name,
                kind: .failure(message: "Tool '\(call.name)' not found")
            )
        }
        do {
            let result = try await tool.execute(arguments: call.arguments)
            return ToolCallOutcome(id: call.id, name: call.name, kind: .success(result))
        } catch is CancellationError {
            return ToolCallOutcome(
                id: call.id,
                name: call.name,
                kind: .failure(message: "Tool batch cancelled")
            )
        } catch {
            return ToolCallOutcome(
                id: call.id,
                name: call.name,
                kind: .failure(message: String(describing: error))
            )
        }
    }
}
