import Foundation

/// The fields of an oMLX chat response that the OpenAI decoding drops.
struct OMLXChatExtras: Decodable {
    /// `choices[0].message.reasoning_content`.
    let reasoningContent: String?
    /// `usage` exactly as reported, including oMLX's own fields.
    let usage: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case choices
        case usage
    }

    private struct Choice: Decodable {
        let message: Message?
    }

    private struct Message: Decodable {
        let reasoningContent: String?

        enum CodingKeys: String, CodingKey {
            case reasoningContent = "reasoning_content"
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let choices = try container.decodeIfPresent([Choice].self, forKey: .choices)
        reasoningContent = choices?.first?.message?.reasoningContent
        usage = try container.decodeIfPresent(JSONValue.self, forKey: .usage)
    }
}
