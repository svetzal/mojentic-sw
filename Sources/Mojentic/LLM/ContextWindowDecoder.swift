import Foundation

/// Pure validation of provider metadata, independent of transport and request policy.
enum ContextWindowDecoder {
    static func object(_ bytes: Data) throws -> [String: JSONValue] {
        do {
            guard let object = try JSONDecoder().decode(JSONValue.self, from: bytes).objectValue else {
                throw invalid()
            }
            return object
        } catch {
            throw invalid()
        }
    }

    static func invalid() -> MojenticError {
        .decoding(message: "Invalid context-window metadata")
    }

    static func positive(_ value: JSONValue) throws -> Int {
        guard case .integer(let count) = value, count > 0 else { throw invalid() }
        return count
    }

    static func omlx(_ bytes: Data, model: String) throws -> ModelContextWindow? {
        let root = try object(bytes)
        guard case .array(let entries) = root["data"] else { throw invalid() }
        let objects = try entries.map { entry -> [String: JSONValue] in
            guard let object = entry.objectValue, object["id"]?.stringValue != nil else { throw invalid() }
            return object
        }
        guard let entry = objects.first(where: { $0["id"] == .string(model) }),
            let value = entry["max_model_len"]
        else { return nil }
        return try ModelContextWindow(maxContextTokens: positive(value), field: "max_model_len")
    }

    static func ollama(_ bytes: Data) throws -> ModelContextWindow? {
        let root = try object(bytes)
        guard let raw = root["model_info"] else { return nil }
        guard let info = raw.objectValue else { throw invalid() }
        guard let key = info.keys.sorted().first(where: { $0.hasSuffix(".context_length") }),
            let value = info[key]
        else { return nil }
        let maximum = try positive(value)
        var modelLimit: Int?
        if let rawParameters = root["parameters"] {
            guard let text = rawParameters.stringValue else { throw invalid() }
            for line in text.split(separator: "\n") {
                let fields = line.split(whereSeparator: \.isWhitespace)
                if fields.first == "num_ctx" {
                    guard fields.count == 2, let count = Int(fields[1]), count > 0 else { throw invalid() }
                    modelLimit = count
                    break
                }
            }
        }
        return ModelContextWindow(
            maxContextTokens: maximum, field: "model_info." + key, modelNumCtx: modelLimit)
    }
}
