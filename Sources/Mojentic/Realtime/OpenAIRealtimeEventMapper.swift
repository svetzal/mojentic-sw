import Foundation

/// Pure translation between OpenAI Realtime API events and the
/// vendor-neutral ``RealtimeEvent`` union.
///
/// No I/O — the mapper is a value-level function so it can be exercised
/// against table-driven fixtures without touching a socket. Returns `nil`
/// for events the neutral union does not cover; consumers needing those
/// reach for ``RealtimeSession/rawEvents()``.
public enum OpenAIRealtimeEventMapper {
    /// Translate one decoded OpenAI event into a ``RealtimeEvent``.
    public static func map(_ event: JSONValue) -> RealtimeEvent? {
        guard let object = event.objectValue,
            let type = object["type"]?.stringValue
        else { return nil }
        switch type {
        case "session.created":
            let sessionId =
                object["session"]?.objectValue?["id"]?.stringValue ?? ""
            return .sessionCreated(sessionId: sessionId)
        case "session.updated":
            return .sessionUpdated
        case "input_audio_buffer.speech_started":
            return .speechStarted
        case "input_audio_buffer.speech_stopped":
            return .speechStopped
        case "conversation.item.input_audio_transcription.delta":
            guard let itemId = object["item_id"]?.stringValue,
                let delta = object["delta"]?.stringValue
            else { return nil }
            return .userTranscriptDelta(itemId: itemId, delta: delta)
        case "conversation.item.input_audio_transcription.completed":
            guard let itemId = object["item_id"]?.stringValue,
                let text = object["transcript"]?.stringValue
            else { return nil }
            return .userTranscript(itemId: itemId, text: text)
        case "response.created":
            let turnId =
                object["response"]?.objectValue?["id"]?.stringValue ?? ""
            return .responseStarted(turnId: turnId)
        case "response.text.delta", "response.output_text.delta":
            guard let delta = object["delta"]?.stringValue else { return nil }
            let turnId = object["response_id"]?.stringValue ?? ""
            return .textDelta(turnId: turnId, delta: delta)
        case "response.text.done", "response.output_text.done":
            guard let text = object["text"]?.stringValue else { return nil }
            let turnId = object["response_id"]?.stringValue ?? ""
            return .textDone(turnId: turnId, text: text)
        case "response.audio_transcript.delta", "response.output_audio_transcript.delta":
            guard let delta = object["delta"]?.stringValue else { return nil }
            let turnId = object["response_id"]?.stringValue ?? ""
            return .transcriptDelta(turnId: turnId, delta: delta)
        case "response.audio_transcript.done", "response.output_audio_transcript.done":
            guard let text = object["transcript"]?.stringValue else { return nil }
            let turnId = object["response_id"]?.stringValue ?? ""
            return .transcript(turnId: turnId, text: text)
        case "response.audio.delta", "response.output_audio.delta":
            guard let base64 = object["delta"]?.stringValue,
                let frame = try? AudioCodec.base64Decode(base64)
            else { return nil }
            let turnId = object["response_id"]?.stringValue ?? ""
            return .audioDelta(turnId: turnId, frame: frame)
        case "response.audio.done", "response.output_audio.done":
            let turnId = object["response_id"]?.stringValue ?? ""
            return .audioDone(turnId: turnId)
        case "response.output_item.added":
            guard let item = object["item"]?.objectValue,
                item["type"]?.stringValue == "function_call",
                let callId = item["call_id"]?.stringValue,
                let name = item["name"]?.stringValue
            else { return nil }
            let turnId = object["response_id"]?.stringValue ?? ""
            return .toolCallStarted(turnId: turnId, callId: callId, name: name)
        case "response.function_call_arguments.delta":
            guard let callId = object["call_id"]?.stringValue,
                let delta = object["delta"]?.stringValue
            else { return nil }
            return .toolCallArgsDelta(callId: callId, delta: delta)
        case "response.done":
            let response = object["response"]?.objectValue
            let turnId = response?["id"]?.stringValue ?? ""
            let usage = parseUsage(response?["usage"]?.objectValue)
            return .responseDone(turnId: turnId, usage: usage)
        case "error":
            let message =
                object["error"]?.objectValue?["message"]?.stringValue
                ?? "unknown realtime error"
            return .errorOccurred(message)
        default:
            return nil
        }
    }

    private static func parseUsage(_ payload: [String: JSONValue]?) -> RealtimeTokenUsage? {
        guard let payload, !payload.isEmpty else { return nil }
        return RealtimeTokenUsage(
            promptTokens: payload["input_tokens"]?.intValue,
            completionTokens: payload["output_tokens"]?.intValue,
            totalTokens: payload["total_tokens"]?.intValue
        )
    }
}
