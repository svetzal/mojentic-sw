import Foundation

/// Recovery applies to buffered and streaming Ollama and oMLX completions.
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
public struct RecoveryIdentity: Sendable, Codable, Equatable {
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
    /// Local provider identity.
    public let provider: String
    /// Ordinary, structured, or streaming completion.
    public let operation: String
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
    /// Syntactically validated provider code, excluded from safe summaries and events.
    public var providerCode: String? {
        evidence.providerCode
    }

    /// Syntactically validated request ID, excluded from safe summaries and events.
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
        provider: String,
        operation: String,
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
    /// Validated token from an error object, retained only for explicit inspection.
    public var providerCode: String? {
        let value = try? JSONDecoder().decode(JSONValue.self, from: body)
        return Self.validated(value?.objectValue?["error"]?.objectValue?["code"]?.stringValue)
    }

    /// Validated request-ID token; raw headers remain available even when validation fails.
    public var providerRequestID: String? {
        Self.validated(headers.first { $0.key.lowercased() == "x-request-id" }?.value)
    }

    private static func validated(_ value: String?) -> String? {
        guard
            let value, !value.isEmpty, value.utf8.count <= 128,
            value.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || [45, 46, 95].contains($0)
            })
        else { return nil }
        return value
    }

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
    /// Local provider identity.
    public let provider: String
    /// Ordinary, structured, or streaming completion.
    public let operation: String
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
    /// Caller-owned decision stream; pending is never approval and cancellation ends iteration.
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
    /// The adapter exposes this facility.
    case supported
    /// The adapter does not expose this facility.
    case unsupported
    /// Evidence cannot establish support or acceptance.
    case unknown
}

/// Verified local-provider facilities for completion recovery.
public struct CompletionRecoveryCapabilities: Sendable {
    /// Cancelling the local HTTP task is supported, without remote termination proof.
    public let localRequestCancellation: RecoveryCapabilitySupport = .supported
    /// Remote cancellation is unsupported; local task cancellation proves no termination.
    public let remoteRequestCancellation: RecoveryCapabilitySupport = .unsupported
    /// Exact-attempt status querying is unsupported by this adapter.
    public let exactRequestStatus: RecoveryCapabilitySupport = .unsupported
    /// Provider idempotency is unsupported; no invented header is sent.
    public let idempotency: RecoveryCapabilitySupport = .unsupported
    /// Create the documented default value.
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
