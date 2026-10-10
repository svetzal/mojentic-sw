import Foundation

/// Pure decoding and failure-category inference for the buffered wire boundary.
extension BufferedRecovery {
    static func category(for result: RecoveryHTTPResult) -> RecoveryCategory {
        if let status = result.response?.statusCode, !(200..<300).contains(status) {
            // Known permanent statuses stay HTTP failures even with truncated bodies.
            .http
        } else if let cause = result.cause {
            switch (cause as? URLError)?.code {
            case .timedOut: .clientTimeout
            case .cancelled: .cancellation
            default: .transport
            }
        } else {
            if (try? JSONDecoder().decode(JSONValue.self, from: result.body))?.objectValue?["error"] != nil {
                .providerResponse
            } else {
                .protocolFailure
            }
        }
    }

    static func semanticEvidence(_ data: Data, provider: String) -> RecoverySemanticProgress {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data).objectValue else {
            return RecoverySemanticProgress()
        }
        let message: [String: JSONValue]? =
            if provider == "ollama" {
                root["message"]?.objectValue
            } else {
                root["choices"]?.recoveryArray?.first?.objectValue?["message"]?.objectValue
            }
        var progress = RecoverySemanticProgress()
        progress.contentBytes = message?["content"]?.stringValue?.utf8.count ?? 0
        progress.reasoningBytes =
            (message?[provider == "ollama" ? "thinking" : "reasoning_content"]?.stringValue?.utf8.count) ?? 0
        progress.toolFragments = message?["tool_calls"]?.recoveryArray?.count ?? 0
        if provider == "ollama" {
            let wire = try? JSONDecoder().decode(OllamaChatResponse.self, from: data)
            progress.completedToolCalls = wire?.message.toolCalls?.count ?? 0
        } else {
            let wire = try? JSONDecoder().decode(OpenAIChatResponse.self, from: data)
            progress.completedToolCalls = wire?.toGatewayResponse().toolCalls.count ?? 0
        }
        return progress
    }
}

extension JSONValue {
    fileprivate var recoveryArray: [JSONValue]? {
        if case .array(let values) = self {
            return values
        }
        return nil
    }
}
