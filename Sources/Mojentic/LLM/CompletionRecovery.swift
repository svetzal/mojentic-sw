import Foundation

/// The category of a failed completion attempt under recovery.
public enum RecoveryCategory: String, Sendable, Codable, Hashable {
    /// HTTP transport failed without confirmed remote termination.
    case transport
    /// A non-success HTTP status was received.
    case http
    /// The provider reported an application-level failure.
    case providerResponse
    /// Malformed or unsupported response evidence.
    case protocolFailure
    /// Caller cancellation is authoritative.
    case cancellation
    /// The client timed out without remote termination proof.
    case clientTimeout
    /// Caller-owned capture failed; no resend is permitted.
    case capture
}

/// Local correlation identities do not provide provider idempotency.
public struct RecoveryIdentity: Sendable, Codable, Hashable {
    /// Correlation identifier shared by all attempts of one completion.
    public let logicalID: UUID
    /// Distinct identifier for this actual HTTP send.
    public let attemptID: UUID
    /// One-based actual wire attempt number; admission waits do not increment it.
    public let wireNumber: Int
}

/// Counts semantic evidence without retaining response content.
public struct RecoverySemanticProgress: Sendable, Codable, Equatable {
    /// UTF-8 bytes of decoded reasoning evidence.
    public var reasoningBytes = 0
    /// UTF-8 bytes of decoded content evidence.
    public var contentBytes = 0
    /// Decoded tool-call entries observed or delivered.
    public var toolFragments = 0
    /// Complete decoded tool-call records.
    public var completedToolCalls = 0
}

/// Observed evidence is independent of delivery to the caller.
public struct RecoveryProgress: Sendable, Codable, Equatable {
    /// Full local identity of the streaming wire attempt, absent outside recovery telemetry.
    public var identity: RecoveryIdentity?
    /// One-based validated provider frame index, reset for each wire attempt.
    public var frameIndex: Int?
    /// Whether HTTP response headers were received.
    public var headersReceived = false
    /// Total received body bytes, including nonsemantic bytes.
    public var rawBytes = 0
    /// Semantic evidence received, independent of capture and delivery.
    public var observed = RecoverySemanticProgress()
    /// Semantic evidence returned to the caller; zero on buffered failure.
    public var delivered = RecoverySemanticProgress()
}

/// Retry-After parsing preserves absence and invalidity as distinct states.
public enum RecoveryRetryAfter: Sendable, Codable, Equatable {
    /// The response carried no Retry-After header.
    case absent
    /// The header could not be parsed as seconds or an HTTP date.
    case invalid
    /// Nonnegative delay in seconds.
    case seconds(TimeInterval)
    /// HTTP date evaluated against the injected wall clock.
    case date(Date)
}

/// A failed wire attempt with safe summaries and explicitly inspected evidence.
public struct RecoveryFailure: Error, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Correlation identity exists even when cancellation precedes dispatch.
    public let logicalID: UUID
    /// Actual wire identity, absent when dispatch did not occur.
    public let identity: RecoveryIdentity?
    /// Closed provider identity shared with admission observations and lifecycle events.
    public let provider: RecoveryProvider
    /// Shared ordinary, structured or streaming operation, independent of adapter method names.
    public let operation: RecoveryOperation
    /// Stable failure classification.
    public let category: RecoveryCategory
    /// Numeric HTTP status when headers arrived.
    public let status: Int?
    /// Parsed provider backoff evidence.
    public let retryAfter: RecoveryRetryAfter
    /// Observed and delivered counters for this attempt.
    public let progress: RecoveryProgress
    /// Buffered local requests have unknown remote acceptance after dispatch.
    public let acceptance: RecoveryAcceptance
    /// Known failure phase, absent when evidence cannot distinguish it.
    public let phase: RecoveryPhase?
    /// Classification only; eligibility never grants resend permission.
    public let eligible: Bool
    /// Stable reason code containing no provider or cause text.
    public let reason: String
    /// Allowlisted provider code with outbound credential and payload echoes rejected.
    ///
    /// Unknown codes are nil; raw values remain available through `inspectEvidence()`.
    /// Anthropic reads `error.type`; other completion adapters read `error.code`.
    public var providerCode: String? {
        evidence.providerCode
    }

    /// Validated request ID with outbound credential and decoded payload echoes rejected.
    ///
    /// Rejected values remain in inspected headers; Anthropic reads native `request-id`.
    /// Final failures, history, admission and reports share this guarantee.
    public var providerRequestID: String? {
        evidence.providerRequestID
    }

    private let evidence: RecoveryEvidence

    /// Safe summary excluding sensitive evidence.
    public var description: String {
        "Completion recovery: \(category.rawValue) (\(reason))"
    }

    /// Safe debug summary excluding sensitive evidence.
    public var debugDescription: String {
        description
    }

    /// Sensitive evidence belongs to the caller's explicit inspection boundary.
    public func inspectEvidence() -> RecoveryEvidence {
        evidence
    }

    init(
        logicalID: UUID,
        identity: RecoveryIdentity?,
        provider: RecoveryProvider,
        operation: RecoveryOperation,
        category: RecoveryCategory,
        status: Int?,
        retryAfter: RecoveryRetryAfter,
        progress: RecoveryProgress,
        phase: RecoveryPhase?,
        eligible: Bool,
        reason: String,
        evidence: RecoveryEvidence,
    ) {
        self.logicalID = logicalID
        self.identity = identity
        self.provider = provider
        self.operation = operation
        self.category = category
        self.status = status
        self.retryAfter = retryAfter
        self.progress = progress
        acceptance = identity == nil ? .no : .unknown
        self.phase = phase
        self.eligible = eligible
        self.reason = reason
        self.evidence = evidence
    }
}

/// Raw headers, partial bytes and typed causes are sensitive and never serialized.
public struct RecoveryEvidence: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Sensitive response headers retained for explicit inspection.
    public let headers: [String: String]
    /// Sensitive received bytes, including partial responses.
    public let body: Data
    /// Original typed failure retained without conversion to message text.
    public let cause: (any Error)?
    /// Allowlisted provider code that does not echo outbound headers or payload strings.
    ///
    /// Unknown or echoed codes are nil; the original value remains in `body`.
    public let providerCode: String?

    /// Request-ID token that does not echo outbound headers or decoded payload strings.
    ///
    /// Rejected values remain in `headers`; Anthropic uses its native `request-id` header.
    public let providerRequestID: String?

    /// Safe summary excluding sensitive evidence.
    public var description: String {
        "Sensitive recovery evidence"
    }

    /// Safe debug summary excluding sensitive evidence.
    public var debugDescription: String {
        description
    }
}

/// A terminal report retains every completed failure within the attempt limit.
public struct RecoveryError: Error, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Correlation identity exists even when cancellation precedes dispatch.
    public let logicalID: UUID
    /// Terminal decision for this logical completion.
    public let outcome: RecoveryTransition
    /// Final structured failure, including available evidence.
    public let failure: RecoveryFailure
    /// Failed actual attempts bounded by the configured maximum attempts.
    public let history: [RecoveryFailure]
    /// Safe summary excluding sensitive evidence.
    public var description: String {
        "Completion recovery ended: \(outcome); \(failure)"
    }

    /// Safe debug summary excluding sensitive evidence.
    public var debugDescription: String {
        description
    }
}

/// Safe lifecycle telemetry contains no payload, headers or cause text.
public struct RecoveryEvent: Sendable, Codable, Equatable {
    /// Correlation identity exists even when cancellation precedes dispatch.
    public let logicalID: UUID
    /// Typed lifecycle transition.
    public let transition: RecoveryTransition
    /// Actual wire identity, absent when dispatch did not occur.
    public let identity: RecoveryIdentity?
    /// Observed and delivered counters for this attempt.
    public let progress: RecoveryProgress
    /// Stable failure classification.
    public let category: RecoveryCategory?
    /// Numeric HTTP status when headers arrived.
    public let status: Int?
    /// Scheduled recovery delay in seconds.
    public let delay: TimeInterval?
    /// Closed provider identity shared with admission observations and lifecycle events.
    public let provider: RecoveryProvider
    /// Shared ordinary, structured or streaming operation, independent of adapter method names.
    public let operation: RecoveryOperation
    /// Known failure phase, absent when evidence cannot distinguish it.
    public let phase: RecoveryPhase?
    /// Acceptance evidence for this exact request.
    public let acceptance: RecoveryAcceptance
    /// Classification only; eligibility never grants resend permission.
    public let eligible: Bool?
    /// Stable failure classification reason when available.
    public let reason: String?
}

/// An explicit decision is required before resending ambiguous local execution.
public enum RecoveryAdmission: Sendable {
    /// Explicitly authorize the next request after caller checks.
    case allow
    /// Terminate this request without another send.
    case reject
}

/// Exact wire capture is opt-in, sensitive and caller-owned.
public enum RecoveryWireEvent: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Proposed pre-dispatch body and headers; identity becomes actual only on launch.
    case request(RecoveryIdentity, URL, [String: String], Data)
    /// Status and URLSession response header values at receipt.
    case headers(RecoveryIdentity, Int, [String: String])
    /// Exact received body chunk after semantic accounting.
    case body(RecoveryIdentity, Data)
    /// Safe summary excluding sensitive evidence.
    public var description: String {
        "Sensitive wire capture"
    }

    /// Safe debug summary excluding sensitive evidence.
    public var debugDescription: String {
        description
    }
}

/// Injectable monotonic/wall clocks, sleeper and full jitter.
public struct RecoveryTiming: Sendable {
    /// Monotonic clock in seconds for admission and backoff limits.
    public var monotonic: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Wall clock used to resolve HTTP-date Retry-After values.
    public var wall: @Sendable () -> Date = { Date() }
    /// Full jitter sample in the supplied exponential ceiling.
    public var jitter: @Sendable (TimeInterval) -> TimeInterval = { Double.random(in: 0...$0) }
    /// Cancellation-cooperative asynchronous delay in seconds.
    public var sleep: @Sendable (TimeInterval) async throws -> Void = {
        let nanoseconds = min(max(0, $0) * 1_000_000_000, Double(UInt64.max).nextDown)
        try await Task.sleep(nanoseconds: UInt64(nanoseconds))
    }

    /// Create the documented default value.
    public init() {}
}

/// Opt-in policy for one provider completion, independent of tool depth.
///
/// Admission is an asynchronous stream: remaining pending never grants permission.
/// Cancellation terminates iteration. Limits apply to recovery, never active generation.
public struct CompletionRecoveryPolicy: Sendable {
    // Internal diagnostic seam; absent in consumer-created policies.
    var httpTrace: RecoveryDeliveryScheduling.HTTPTrace?
    /// Positive limit including the initial wire request; defaults to one.
    public var maximumAttempts = 1
    /// Exponential full-jitter base in seconds.
    public var baseDelay: TimeInterval = 0.1
    /// Maximum permitted backoff, including Retry-After, in seconds.
    public var delayCeiling: TimeInterval = 30
    /// Optional recovery duration from the first failure in seconds; never limits active generation.
    public var budget: TimeInterval?
    /// Optional absolute monotonic admission/backoff deadline.
    public var deadline: TimeInterval?
    /// Selected HTTP statuses, subject to permanent-status safeguards.
    public var retryableStatuses: Set<Int> = [429, 500, 502, 503, 504]
    /// Selected categories; malformed, capture and cancellation failures remain terminal.
    public var retryableCategories: Set<RecoveryCategory> = [.transport, .http, .clientTimeout]
    /// Injectable timing dependencies for deterministic recovery.
    public var timing = RecoveryTiming()
    /// Caller-owned decision stream that controls admission for every provider when configured.
    ///
    /// Without a hook, eligible OpenAI and Anthropic failures may retry. Ollama and oMLX
    /// require admission unless acceptance is `no`. Pending is never approval; an empty
    /// stream ends with `admissionUndecided`. Cancellation or expiry terminates iteration.
    public var admission: (@Sendable (RecoveryFailure, Int) -> AsyncStream<RecoveryAdmission>)?
    /// Synchronous safe lifecycle observer; callbacks should return promptly.
    public var observer: (@Sendable (RecoveryEvent) -> Void)?
    /// Final counters and bounded inspectable history; callbacks should return promptly.
    public var reportObserver: (@Sendable (CompletionRecoveryReport) -> Void)?
    /// Explicit sensitive capture hook; throwing terminates without resend.
    public var wireObserver: (@Sendable (RecoveryWireEvent) throws -> Void)?
    /// Create the documented default value.
    public init() {}
}

/// Evidence-based remote acceptance of this exact request.
public enum RecoveryAcceptance: String, Sendable, Codable {
    /// Evidence confirms acceptance of this exact request.
    case yes
    /// Dispatch did not occur.
    case no
    /// Evidence cannot establish support or acceptance.
    case unknown
}

/// A phase is absent when the HTTP stack cannot distinguish it.
public enum RecoveryPhase: String, Sendable, Codable {
    /// Establishing the connection.
    case connecting
    /// Sending the encoded body.
    case sending
    /// Waiting for response headers.
    case awaitingHeaders
    /// Receiving the buffered body.
    case receiving
    /// Receiving or validating provider streaming frames.
    case streaming
    /// Decoding the provider response.
    case decoding
}

/// Capability support does not imply proof that an individual request ended.
public enum RecoveryCapabilitySupport: String, Sendable, Codable {
    /// The inspected documentation describes this facility for the exact endpoint.
    case supported
    /// The inspected endpoint documentation describes no such facility.
    case unsupported
    /// Documentation is absent or ambiguous, or exact-attempt evidence is unavailable.
    case unknown
}

/// Documented facilities for the four maintained completion recovery adapters.
///
/// See <doc:RecoveryCapabilities> for each endpoint, evidence source and inspection date.
/// These values describe facilities, not evidence that a particular request ended.
public struct CompletionRecoveryCapabilities: Sendable {
    /// Cancelling the local HTTP task is supported, without remote termination proof.
    public let localRequestCancellation: RecoveryCapabilitySupport = .supported
    /// The inspected completion endpoints describe no active-request cancellation operation.
    public let remoteRequestCancellation: RecoveryCapabilitySupport = .unsupported
    /// The inspected completion endpoints describe no active exact-attempt status query.
    public let exactRequestStatus: RecoveryCapabilitySupport = .unsupported
    /// The inspected references give no inference idempotency guarantee; no header is invented.
    public let idempotency: RecoveryCapabilitySupport = .unknown
    /// No adapter has evidence that this exact remote attempt terminated.
    public let exactAttemptTermination: RecoveryCapabilitySupport = .unknown
    /// Create the values documented for Ollama, oMLX, OpenAI Chat Completions and Anthropic Messages.
    public init() {}
}

/// Final safe counters and explicitly inspectable failed attempts for one call.
public struct CompletionRecoveryReport: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Correlation identity exists even when cancellation precedes dispatch.
    public let logicalID: UUID
    /// Actual wire identity, absent when dispatch did not occur.
    public let identity: RecoveryIdentity?
    /// Observed and delivered counters for this attempt.
    public let progress: RecoveryProgress
    /// Failed actual attempts bounded by the configured maximum attempts.
    public let history: [RecoveryFailure]
    /// Safe summary excluding sensitive evidence.
    public var description: String {
        "Buffered completion report (\(history.count) failed attempts)"
    }

    /// Safe debug summary excluding sensitive evidence.
    public var debugDescription: String {
        description
    }
}

/// Typed lifecycle transitions and terminal outcomes for completion recovery.
public enum RecoveryTransition: String, Sendable, Codable, Equatable {
    /// Lifecycle transition: attempt started.
    case attemptStarted
    /// Lifecycle transition: attempt succeeded.
    case attemptSucceeded
    /// Lifecycle transition: attempt failed.
    case attemptFailed
    /// Lifecycle transition: admission pending.
    case admissionPending
    /// Lifecycle transition: admission allowed.
    case admissionAllowed
    /// Lifecycle transition: admission rejected.
    case admissionRejected
    /// The configured admission stream ended without an explicit decision; no resend occurs.
    case admissionUndecided
    /// Lifecycle transition: admission required.
    case admissionRequired
    /// Lifecycle transition: delay scheduled.
    case delayScheduled
    /// Lifecycle transition: retry started.
    case retryStarted
    /// Lifecycle transition: exhausted.
    case exhausted
    /// Lifecycle transition: ineligible.
    case ineligible
    /// Lifecycle transition: limit refused.
    case limitRefused
    /// Lifecycle transition: cancelled.
    case cancelled
    /// Lifecycle transition: capture failed.
    case captureFailed
    /// Lifecycle transition: malformed response.
    case malformedResponse
    /// Lifecycle transition: encoding.
    case encoding
    /// Semantic output was observed before a failed completion.
    case interrupted
}

/// Typed HTTP rejection when the transport itself completed successfully.
public struct RecoveryHTTPStatusFailure: Error, Sendable {
    /// Numeric received HTTP status.
    public let status: Int
}
