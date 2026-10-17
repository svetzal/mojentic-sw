/// Native reasoning control; an omitted value leaves provider behavior unknown.
public enum ReasoningEffort: String, Sendable, Codable, Hashable, CaseIterable {
    /// Disable native reasoning.
    case disabled
    /// Enable native reasoning without selecting an effort level.
    case enabled
    /// Low reasoning effort.
    case low
    /// Medium reasoning effort.
    case medium
    /// High reasoning effort.
    case high
    /// Extra-high reasoning effort.
    case xhigh

    var ollamaValue: JSONValue {
        switch self {
        case .disabled: .bool(false)
        case .enabled: .bool(true)
        default: .string(rawValue)
        }
    }
}

/// Caller-selected capabilities; model names never select a profile implicitly.
public struct ReasoningProfile: Sendable, Codable, Hashable {
    /// Efforts accepted by this model profile.
    public let supportedEfforts: Set<ReasoningEffort>
    /// Whether native assistant reasoning may be replayed.
    public let supportsHistory: Bool

    /// Define explicit model capabilities.
    public init(supportedEfforts: Set<ReasoningEffort>, supportsHistory: Bool) {
        self.supportedEfforts = supportedEfforts
        self.supportsHistory = supportsHistory
    }

    /// Qwen3.8 accepts disabled, low, medium and extra-high with native history.
    public static let qwen38 = ReasoningProfile(
        supportedEfforts: [.disabled, .low, .medium, .xhigh], supportsHistory: true
    )
}

/// Output format requested from the provider.
///
/// Gateways forward the requested format in both ordinary and streaming
/// requests. The format records what was *requested*; it is not proof that
/// the provider enforced it. Callers must still validate the content they
/// receive.
///
/// | Case | OpenAI `response_format` | Ollama `format` |
/// | ---- | ------------------------ | --------------- |
/// | ``text`` | `{"type": "text"}` | omitted |
/// | ``jsonObject`` | `{"type": "json_object"}` | `"json"` |
/// | ``jsonSchema(_:)`` | `{"type": "json_schema", "json_schema": {"name": "response", "schema": …}}` | the
/// schema |
public enum ResponseFormat: Sendable, Codable, Hashable {
    /// Plain text output.
    case text
    /// JSON object mode, without a schema.
    case jsonObject
    /// JSON schema mode constrained by the supplied JSON Schema.
    case jsonSchema(JSONValue)
}

/// Configuration for a single LLM completion request.
///
/// `CompletionConfig` collects the small set of knobs every provider exposes
/// in some form. Provider-specific options that don't generalise cleanly can
/// be passed through `extraOptions`; gateways forward them verbatim where the
/// underlying API supports it.
public struct CompletionConfig: Sendable, Codable, Hashable {
    /// Sampling temperature; nil leaves the provider default unchanged.
    public var temperature: Double?

    /// Caller-selected output limit; nil leaves the provider default unchanged.
    ///
    /// Anthropic requires a limit and uses the registry maximum or 4096 when unset.
    public var maxTokens: Int?

    /// Nucleus-sampling cutoff.
    ///
    /// `nil` defers to the provider default.
    public var topP: Double?

    /// Reasoning-effort hint for models that support extended thinking.
    public var reasoning: ReasoningEffort?

    /// Explicit model capabilities, selected by the caller.
    public var reasoningProfile: ReasoningProfile?

    /// Retain native reasoning in completed broker and session exchanges.
    public var retainThinking: Bool

    /// Caller-selected context size for Ollama; nil preserves model/server settings.
    public var numCtx: Int?

    /// Provider-specific overrides forwarded verbatim by the gateway.
    public var extraOptions: [String: JSONValue]

    /// Maximum number of recursive tool-call iterations the broker will
    /// dispatch before surfacing `MojenticError.toolDepthExceeded`; nil is unlimited.
    public var maxToolIterations: Int?

    /// Output format to request from the provider; `nil` leaves the
    /// provider default and the request body unchanged.
    ///
    /// Forwarded by ordinary and streaming requests. Structured-output calls
    /// (`completeJSON`) derive their own schema and ignore this field.
    public var responseFormat: ResponseFormat?

    /// Create a `CompletionConfig` with the documented defaults.
    public init(
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        topP: Double? = nil,
        reasoning: ReasoningEffort? = nil,
        reasoningProfile: ReasoningProfile? = nil,
        retainThinking: Bool = false,
        numCtx: Int? = nil,
        extraOptions: [String: JSONValue] = [:],
        maxToolIterations: Int? = 25,
        responseFormat: ResponseFormat? = nil,
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.topP = topP
        self.reasoning = reasoning
        self.reasoningProfile = reasoningProfile
        self.retainThinking = retainThinking
        self.numCtx = numCtx
        self.extraOptions = extraOptions
        self.maxToolIterations = maxToolIterations
        self.responseFormat = responseFormat
    }
}

extension CompletionConfig {
    /// Decode legacy configurations with retention disabled when its field is absent.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        temperature = try values.decodeIfPresent(Double.self, forKey: .temperature)
        maxTokens = try values.decodeIfPresent(Int.self, forKey: .maxTokens)
        topP = try values.decodeIfPresent(Double.self, forKey: .topP)
        reasoning = try values.decodeIfPresent(ReasoningEffort.self, forKey: .reasoning)
        reasoningProfile = try values.decodeIfPresent(ReasoningProfile.self, forKey: .reasoningProfile)
        retainThinking = try values.decodeIfPresent(Bool.self, forKey: .retainThinking) ?? false
        numCtx = try values.decodeIfPresent(Int.self, forKey: .numCtx)
        extraOptions = try values.decode([String: JSONValue].self, forKey: .extraOptions)
        maxToolIterations = try values.decodeIfPresent(Int.self, forKey: .maxToolIterations)
        responseFormat = try values.decodeIfPresent(ResponseFormat.self, forKey: .responseFormat)
    }

    func validateReasoning(provider: String, messages: [LLMMessage]) throws {
        if provider != "ollama", provider != "omlx" {
            if reasoningProfile != nil || retainThinking || reasoning == .disabled
                || reasoning == .enabled || reasoning == .xhigh
            {
                throw MojenticError.invalidArgument(
                    message: "Native reasoning controls unsupported by \(provider)")
            }
            return
        }
        if let profile = reasoningProfile {
            if let reasoning, !profile.supportedEfforts.contains(reasoning) {
                throw MojenticError.invalidArgument(
                    message: "Reasoning effort unsupported by selected profile")
            }
            if !profile.supportsHistory,
                retainThinking || messages.contains(where: { $0.thinking != nil })
            {
                throw MojenticError.invalidArgument(message: "Native history unsupported by selected profile")
            }
        }
    }
}
