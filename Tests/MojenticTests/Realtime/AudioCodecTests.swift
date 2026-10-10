import Foundation
@testable import Mojentic
import Testing

@Suite("AudioCodec")
struct AudioCodecTests {
    @Test("base64 round-trip preserves samples and sample rate")
    func roundTrip() throws {
        let samples: [Int16] = [0, 1, -1, 32767, -32768, 12345, -12345]
        let frame = AudioFrame(samples: samples, sampleRate: 24000)
        let encoded = AudioCodec.base64Encode(frame)
        let decoded = try AudioCodec.base64Decode(encoded, sampleRate: 24000)
        #expect(decoded.samples == samples)
        #expect(decoded.sampleRate == 24000)
    }

    @Test("sample rate is plumbed through the decoder")
    func sampleRatePlumbing() throws {
        let frame = AudioFrame(samples: [42], sampleRate: 16000)
        let encoded = AudioCodec.base64Encode(frame)
        let decoded = try AudioCodec.base64Decode(encoded, sampleRate: 16000)
        #expect(decoded.sampleRate == 16000)
    }

    @Test("invalid base64 throws a decoding error")
    func invalidBase64() {
        do {
            _ = try AudioCodec.base64Decode("not base64 ?!")
            Issue.record("expected throw")
        } catch let error as MojenticError {
            if case .decoding = error {
                return
            }
            Issue.record("wrong error: \(error)")
        } catch { Issue.record("wrong error: \(error)") }
    }
}
