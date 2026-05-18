import Foundation

/// A single recorded event in the tracer system.
///
/// Every case carries an `id`, a `correlationId` (root), an optional
/// `parentId` for nested linkage, a `timestamp`, and an optional `duration`
/// (populated on response/result events that pair with a matching call).
public enum TracerEvent: Sendable, Hashable, Codable {
    /// An LLM call dispatched to a gateway.
    case llmCall(LLMCallPayload)
    /// A response received from a gateway, paired with a prior call.
    case llmResponse(LLMResponsePayload)
    /// A single tool invocation dispatched by the runner.
    case toolCall(ToolCallPayload)
    /// The outcome of a single tool invocation, paired with a prior call.
    case toolResult(ToolResultPayload)
    /// Summary of a batch of tool calls executed in parallel.
    case toolBatch(ToolBatchPayload)
    /// Agent lifecycle event (started, finished, failed). Phase 4 wires these.
    case agentLifecycle(AgentLifecyclePayload)

    /// Stable identifier for this event.
    ///
    /// Used as `parentId` for child events.
    public var id: UUID {
        switch self {
        case .llmCall(let payload): return payload.id
        case .llmResponse(let payload): return payload.id
        case .toolCall(let payload): return payload.id
        case .toolResult(let payload): return payload.id
        case .toolBatch(let payload): return payload.id
        case .agentLifecycle(let payload): return payload.id
        }
    }

    /// Root correlation id this event belongs to.
    public var correlationId: UUID {
        switch self {
        case .llmCall(let payload): return payload.correlationId
        case .llmResponse(let payload): return payload.correlationId
        case .toolCall(let payload): return payload.correlationId
        case .toolResult(let payload): return payload.correlationId
        case .toolBatch(let payload): return payload.correlationId
        case .agentLifecycle(let payload): return payload.correlationId
        }
    }

    /// Immediate parent event id, when nested.
    public var parentId: UUID? {
        switch self {
        case .llmCall(let payload): return payload.parentId
        case .llmResponse(let payload): return payload.parentId
        case .toolCall(let payload): return payload.parentId
        case .toolResult(let payload): return payload.parentId
        case .toolBatch(let payload): return payload.parentId
        case .agentLifecycle(let payload): return payload.parentId
        }
    }

    /// Wall-clock timestamp at which the event was recorded.
    public var timestamp: Date {
        switch self {
        case .llmCall(let payload): return payload.timestamp
        case .llmResponse(let payload): return payload.timestamp
        case .toolCall(let payload): return payload.timestamp
        case .toolResult(let payload): return payload.timestamp
        case .toolBatch(let payload): return payload.timestamp
        case .agentLifecycle(let payload): return payload.timestamp
        }
    }

    /// Duration for response/result events that pair with a matching call.
    public var duration: Duration? {
        switch self {
        case .llmResponse(let payload): return payload.duration
        case .toolResult(let payload): return payload.duration
        case .toolBatch(let payload): return payload.duration
        default: return nil
        }
    }
}

// MARK: - Payloads

/// Payload for an `.llmCall` event.
public struct LLMCallPayload: Sendable, Hashable, Codable {
    /// Stable event id.
    public let id: UUID
    /// Root correlation id.
    public let correlationId: UUID
    /// Parent event id when nested.
    public let parentId: UUID?
    /// When the event was emitted.
    public let timestamp: Date
    /// Model identifier the broker is calling.
    public let model: String
    /// Snapshot of the messages sent to the gateway.
    public let messages: [LLMMessage]
    /// Tool names exposed to the model on this call, when any.
    public let tools: [String]?

    /// Construct a call payload.
    public init(
        id: UUID = UUID(),
        correlationId: UUID,
        parentId: UUID? = nil,
        timestamp: Date = Date(),
        model: String,
        messages: [LLMMessage],
        tools: [String]?
    ) {
        self.id = id
        self.correlationId = correlationId
        self.parentId = parentId
        self.timestamp = timestamp
        self.model = model
        self.messages = messages
        self.tools = tools
    }
}

/// Payload for an `.llmResponse` event.
public struct LLMResponsePayload: Sendable, Hashable, Codable {
    /// Stable event id.
    public let id: UUID
    /// Root correlation id.
    public let correlationId: UUID
    /// Parent event id — typically the matching `.llmCall`.
    public let parentId: UUID?
    /// When the event was emitted.
    public let timestamp: Date
    /// Wall-clock duration of the gateway call.
    public let duration: Duration
    /// Model identifier the broker called.
    public let model: String
    /// Raw gateway response payload.
    public let response: LLMGatewayResponse

    /// Construct a response payload.
    public init(
        id: UUID = UUID(),
        correlationId: UUID,
        parentId: UUID?,
        timestamp: Date = Date(),
        duration: Duration,
        model: String,
        response: LLMGatewayResponse
    ) {
        self.id = id
        self.correlationId = correlationId
        self.parentId = parentId
        self.timestamp = timestamp
        self.duration = duration
        self.model = model
        self.response = response
    }
}

/// Payload for a `.toolCall` event.
public struct ToolCallPayload: Sendable, Hashable, Codable {
    /// Stable event id.
    public let id: UUID
    /// Root correlation id.
    public let correlationId: UUID
    /// Parent event id — typically the dispatching `.llmResponse` or a parent
    /// `.toolBatch`.
    public let parentId: UUID?
    /// When the event was emitted.
    public let timestamp: Date
    /// Identifier of the originating ``ToolCallExecution``.
    public let callId: String
    /// Tool name being invoked.
    public let name: String
    /// Arguments the model supplied.
    public let arguments: JSONValue

    /// Construct a tool-call payload.
    public init(
        id: UUID = UUID(),
        correlationId: UUID,
        parentId: UUID?,
        timestamp: Date = Date(),
        callId: String,
        name: String,
        arguments: JSONValue
    ) {
        self.id = id
        self.correlationId = correlationId
        self.parentId = parentId
        self.timestamp = timestamp
        self.callId = callId
        self.name = name
        self.arguments = arguments
    }
}

/// Payload for a `.toolResult` event.
public struct ToolResultPayload: Sendable, Hashable, Codable {
    /// Stable event id.
    public let id: UUID
    /// Root correlation id.
    public let correlationId: UUID
    /// Parent event id — typically the matching `.toolCall`.
    public let parentId: UUID?
    /// When the event was emitted.
    public let timestamp: Date
    /// Wall-clock duration of the tool invocation.
    public let duration: Duration
    /// Outcome returned by the tool.
    public let outcome: ToolCallOutcome

    /// Construct a tool-result payload.
    public init(
        id: UUID = UUID(),
        correlationId: UUID,
        parentId: UUID?,
        timestamp: Date = Date(),
        duration: Duration,
        outcome: ToolCallOutcome
    ) {
        self.id = id
        self.correlationId = correlationId
        self.parentId = parentId
        self.timestamp = timestamp
        self.duration = duration
        self.outcome = outcome
    }
}

/// Payload for a `.toolBatch` event summarising a parallel-runner batch.
public struct ToolBatchPayload: Sendable, Hashable, Codable {
    /// Stable event id.
    public let id: UUID
    /// Root correlation id.
    public let correlationId: UUID
    /// Parent event id — typically the dispatching `.llmResponse`.
    public let parentId: UUID?
    /// When the event was emitted.
    public let timestamp: Date
    /// Total wall-clock duration of the batch.
    public let duration: Duration
    /// Number of tool calls dispatched in the batch.
    public let count: Int

    /// Construct a batch summary payload.
    public init(
        id: UUID = UUID(),
        correlationId: UUID,
        parentId: UUID?,
        timestamp: Date = Date(),
        duration: Duration,
        count: Int
    ) {
        self.id = id
        self.correlationId = correlationId
        self.parentId = parentId
        self.timestamp = timestamp
        self.duration = duration
        self.count = count
    }
}

/// Payload for an `.agentLifecycle` event.
///
/// Phase 4 wires emissions; Phase 3 only defines the shape.
public struct AgentLifecyclePayload: Sendable, Hashable, Codable {
    /// Discriminator for the lifecycle phase being reported.
    public enum Phase: String, Sendable, Hashable, Codable {
        /// Agent started handling an event.
        case started
        /// Agent finished handling an event successfully.
        case finished
        /// Agent failed handling an event.
        case failed
    }

    /// Stable event id.
    public let id: UUID
    /// Root correlation id.
    public let correlationId: UUID
    /// Parent event id when nested.
    public let parentId: UUID?
    /// When the event was emitted.
    public let timestamp: Date
    /// Agent name (typically the type name).
    public let agentName: String
    /// Lifecycle phase being reported.
    public let phase: Phase
    /// Optional human-readable detail (error message, etc.).
    public let detail: String?

    /// Construct a lifecycle payload.
    public init(
        id: UUID = UUID(),
        correlationId: UUID,
        parentId: UUID?,
        timestamp: Date = Date(),
        agentName: String,
        phase: Phase,
        detail: String? = nil
    ) {
        self.id = id
        self.correlationId = correlationId
        self.parentId = parentId
        self.timestamp = timestamp
        self.agentName = agentName
        self.phase = phase
        self.detail = detail
    }
}
