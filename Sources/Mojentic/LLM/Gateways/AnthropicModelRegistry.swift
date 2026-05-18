import Foundation

/// Capability flags + metadata for a well-known Anthropic model.
public struct AnthropicModelCapabilities: Sendable, Hashable {
    /// Whether the model accepts the `tools` field.
    public let supportsTools: Bool
    /// Whether the model accepts inline image content.
    public let supportsVision: Bool
    /// Whether the model accepts the `thinking` field (extended thinking).
    public let supportsExtendedThinking: Bool

    /// Construct a capability record.
    public init(
        supportsTools: Bool = true,
        supportsVision: Bool = true,
        supportsExtendedThinking: Bool = false
    ) {
        self.supportsTools = supportsTools
        self.supportsVision = supportsVision
        self.supportsExtendedThinking = supportsExtendedThinking
    }
}

/// Tiny registry of well-known Anthropic model IDs.
///
/// Anthropic does not expose a `models` list endpoint reachable from the
/// public API surface, so ``AnthropicGateway/availableModels()`` returns
/// the registry's keys. Pattern matching covers model names that include
/// a date suffix (e.g. `claude-3-5-sonnet-20241022`).
public struct AnthropicModelRegistry: Sendable {
    private let entries: [String: AnthropicModelCapabilities]
    private let patterns: [(String, AnthropicModelCapabilities)]

    /// Shared registry initialised with the default model set.
    public static let shared = AnthropicModelRegistry()

    /// Construct the registry with the default known model set.
    public init() {
        let chatVisionTools = AnthropicModelCapabilities(
            supportsTools: true,
            supportsVision: true,
            supportsExtendedThinking: false
        )
        let reasoning = AnthropicModelCapabilities(
            supportsTools: true,
            supportsVision: true,
            supportsExtendedThinking: true
        )
        var registry: [String: AnthropicModelCapabilities] = [
            "claude-3-haiku-20240307": chatVisionTools,
            "claude-3-5-haiku-20241022": chatVisionTools,
            "claude-3-5-haiku-latest": chatVisionTools,
            "claude-3-5-sonnet-20240620": chatVisionTools,
            "claude-3-5-sonnet-20241022": chatVisionTools,
            "claude-3-5-sonnet-latest": chatVisionTools,
            "claude-3-opus-20240229": chatVisionTools,
            "claude-3-opus-latest": chatVisionTools,
            "claude-3-7-sonnet-latest": reasoning,
            "claude-haiku-4-5": chatVisionTools,
            "claude-sonnet-4-5": reasoning,
            "claude-opus-4-7": reasoning,
        ]
        // Preserve insertion order for deterministic availableModels() output.
        self.entries = registry
        registry.removeAll(keepingCapacity: false)
        self.patterns = [
            ("opus-4", reasoning),
            ("sonnet-4", reasoning),
            ("haiku-4", chatVisionTools),
            ("3-7-sonnet", reasoning),
            ("3-5-sonnet", chatVisionTools),
            ("3-5-haiku", chatVisionTools),
            ("3-opus", chatVisionTools),
            ("3-haiku", chatVisionTools),
        ]
    }

    /// Capabilities for `model`, falling back to coarse pattern matching.
    public func capabilities(for model: String) -> AnthropicModelCapabilities {
        if let direct = entries[model] { return direct }
        let lowered = model.lowercased()
        for (pattern, caps) in patterns where lowered.contains(pattern) {
            return caps
        }
        // Conservative default: assume the latest text-only chat capability set.
        return AnthropicModelCapabilities(
            supportsTools: true,
            supportsVision: false,
            supportsExtendedThinking: false
        )
    }

    /// Sorted list of registered model identifiers.
    public func registeredModels() -> [String] {
        entries.keys.sorted()
    }
}
