import Foundation

/// Provider evidence Ollama reports on a response or final stream frame.
struct OllamaResponseEvidence: Decodable {
    let model: String?
    let createdAt: String?
    let promptEvalCount: Int?
    let evalCount: Int?
    let totalDuration: Int?
    let loadDuration: Int?
    let promptEvalDuration: Int?
    let evalDuration: Int?

    enum CodingKeys: String, CodingKey {
        case model
        case createdAt = "created_at"
        case promptEvalCount = "prompt_eval_count"
        case evalCount = "eval_count"
        case totalDuration = "total_duration"
        case loadDuration = "load_duration"
        case promptEvalDuration = "prompt_eval_duration"
        case evalDuration = "eval_duration"
    }

    /// Reported token counts; `nil` when Ollama reported neither.
    var usage: Usage? {
        guard promptEvalCount != nil || evalCount != nil else { return nil }
        return Usage(
            promptTokens: promptEvalCount,
            completionTokens: evalCount,
            totalTokens: (promptEvalCount ?? 0) + (evalCount ?? 0),
        )
    }

    /// Reported timestamps and durations; `nil` when none were reported.
    var metadata: [String: JSONValue]? {
        var fields: [String: JSONValue] = [:]
        if let createdAt {
            fields["created_at"] = .string(createdAt)
        }
        if let totalDuration {
            fields["total_duration"] = .integer(totalDuration)
        }
        if let loadDuration {
            fields["load_duration"] = .integer(loadDuration)
        }
        if let promptEvalDuration {
            fields["prompt_eval_duration"] = .integer(promptEvalDuration)
        }
        if let evalDuration {
            fields["eval_duration"] = .integer(evalDuration)
        }
        return fields.isEmpty ? nil : fields
    }
}
