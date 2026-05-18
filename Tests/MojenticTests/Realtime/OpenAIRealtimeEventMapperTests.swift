import Foundation
import Testing

@testable import Mojentic

@Suite("OpenAIRealtimeEventMapper")
struct OpenAIRealtimeEventMapperTests {
    @Test("session.created surfaces the session id")
    func sessionCreated() {
        let event: JSONValue = [
            "type": "session.created",
            "session": ["id": "sess_123"],
        ]
        let mapped = OpenAIRealtimeEventMapper.map(event)
        guard case .sessionCreated(let id) = mapped else {
            Issue.record("expected sessionCreated")
            return
        }
        #expect(id == "sess_123")
    }

    @Test("response.text.delta becomes textDelta")
    func textDelta() {
        let event: JSONValue = [
            "type": "response.text.delta",
            "response_id": "resp_1",
            "delta": "hello ",
        ]
        guard case .textDelta(let turnId, let delta) = OpenAIRealtimeEventMapper.map(event)
        else {
            Issue.record("expected textDelta")
            return
        }
        #expect(turnId == "resp_1")
        #expect(delta == "hello ")
    }

    @Test("response.output_item.added(function_call) becomes toolCallStarted")
    func toolCallStarted() {
        let event: JSONValue = [
            "type": "response.output_item.added",
            "response_id": "resp_1",
            "item": [
                "type": "function_call",
                "call_id": "call_1",
                "name": "get_weather",
            ],
        ]
        guard
            case .toolCallStarted(let turnId, let callId, let name) =
                OpenAIRealtimeEventMapper.map(event)
        else {
            Issue.record("expected toolCallStarted")
            return
        }
        #expect(turnId == "resp_1")
        #expect(callId == "call_1")
        #expect(name == "get_weather")
    }

    @Test("response.audio.delta decodes base64 PCM into an AudioFrame")
    func audioDelta() throws {
        let samples: [Int16] = [100, 200, -100, -200]
        let encoded = AudioCodec.base64Encode(AudioFrame(samples: samples))
        let event: JSONValue = [
            "type": "response.audio.delta",
            "response_id": "resp_1",
            "delta": .string(encoded),
        ]
        guard case .audioDelta(_, let frame) = OpenAIRealtimeEventMapper.map(event) else {
            Issue.record("expected audioDelta")
            return
        }
        #expect(frame.samples == samples)
    }

    @Test("response.done surfaces usage when present")
    func responseDoneUsage() {
        let event: JSONValue = [
            "type": "response.done",
            "response": [
                "id": "resp_1",
                "usage": [
                    "input_tokens": 12,
                    "output_tokens": 34,
                    "total_tokens": 46,
                ],
            ],
        ]
        guard case .responseDone(let turnId, let usage) = OpenAIRealtimeEventMapper.map(event)
        else {
            Issue.record("expected responseDone")
            return
        }
        #expect(turnId == "resp_1")
        #expect(usage?.promptTokens == 12)
        #expect(usage?.totalTokens == 46)
    }

    @Test("unknown events return nil so the session falls back to rawEvents")
    func unknownEvent() {
        let event: JSONValue = ["type": "totally.unrelated"]
        #expect(OpenAIRealtimeEventMapper.map(event) == nil)
    }

    @Test("error events extract the provider message")
    func errorEvent() {
        let event: JSONValue = [
            "type": "error",
            "error": ["message": "rate limited"],
        ]
        guard case .errorOccurred(let message) = OpenAIRealtimeEventMapper.map(event) else {
            Issue.record("expected errorOccurred")
            return
        }
        #expect(message == "rate limited")
    }
}
