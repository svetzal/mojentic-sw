import Foundation

/// Filters provider tokens against the exact outbound request before retaining public metadata.
struct RecoveryProviderMetadata {
    let outboundStrings: [String]

    init(headers: [String: String], body: Data) {
        var strings = Array(headers.values)
        if let value = try? JSONDecoder().decode(JSONValue.self, from: body) {
            Self.collectStrings(value, into: &strings)
        }
        outboundStrings = strings.filter { !$0.isEmpty }
    }

    func code(from body: Data, provider: String, cause: (any Error)?) -> String? {
        let value = try? JSONDecoder().decode(JSONValue.self, from: body)
        let detail: JSONValue?
        if let error = value?.objectValue?["error"] {
            detail = error
        } else if let error = cause as? MojenticError, case .providerError(_, let errorDetail) = error {
            detail = errorDetail
        } else {
            detail = nil
        }
        let field = provider == "anthropic" ? "type" : "code"
        guard let code = detail?.objectValue?[field]?.stringValue,
            Self.allowedCodes(provider: provider).contains(code), !echoes(code)
        else { return nil }
        return code
    }

    func requestID(from headers: [String: String], provider: String) -> String? {
        let field = provider == "anthropic" ? "request-id" : "x-request-id"
        let matches = headers.filter { $0.key.lowercased() == field }
        guard matches.count == 1, let value = matches.first?.value,
            !value.isEmpty, value.utf8.count <= 128,
            value.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || [45, 46, 95].contains($0)
            }), !echoes(value)
        else { return nil }
        return value
    }

    private func echoes(_ value: String) -> Bool {
        // Both directions reject credentials inside authorization wrappers and payload
        // fragments inside quoted/escaped user text, as well as wrapped response echoes.
        outboundStrings.contains { $0.contains(value) || value.contains($0) }
    }

    private static func collectStrings(_ value: JSONValue, into strings: inout [String]) {
        switch value {
        case .string(let string):
            strings.append(string)
            // Payload strings may themselves carry JSON (for example tool arguments).
            if let nested = try? JSONDecoder().decode(JSONValue.self, from: Data(string.utf8)),
                nested != value
            {
                collectStrings(nested, into: &strings)
            }
        case .array(let values):
            for value in values { collectStrings(value, into: &strings) }
        case .object(let values):
            for value in values.values { collectStrings(value, into: &strings) }
        default: break
        }
    }

    private static func allowedCodes(provider: String) -> Set<String> {
        switch provider {
        case "anthropic":
            [
                "invalid_request_error", "authentication_error", "permission_error", "not_found_error",
                "request_too_large", "rate_limit_error", "api_error", "overloaded_error",
            ]
        case "openai", "omlx", "ollama":
            [
                "invalid_api_key", "insufficient_quota", "rate_limit_exceeded", "server_error",
                "model_not_found", "context_length_exceeded", "invalid_request_error",
                "content_policy_violation",
            ]
        default: []
        }
    }
}
