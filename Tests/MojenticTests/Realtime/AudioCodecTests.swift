import Foundation
import Testing

@testable import Mojentic

@Suite("AudioCodec")
struct AudioCodecTests {
    @Test("base64 round-trip preserves samples and sample rate")
    func roundTrip() throws {
        let samples: [Int16] = [0, 1, -1, 32_767, -32_768, 12_345, -12_345]
        let frame = AudioFrame(samples: samples, sampleRate: 24_000)
        let encoded = AudioCodec.base64Encode(frame)
        let decoded = try AudioCodec.base64Decode(encoded, sampleRate: 24_000)
        #expect(decoded.samples == samples)
        #expect(decoded.sampleRate == 24_000)
    }

    @Test("sample rate is plumbed through the decoder")
    func sampleRatePlumbing() throws {
        let frame = AudioFrame(samples: [42], sampleRate: 16_000)
        let encoded = AudioCodec.base64Encode(frame)
        let decoded = try AudioCodec.base64Decode(encoded, sampleRate: 16_000)
        #expect(decoded.sampleRate == 16_000)
    }

    @Test("invalid base64 throws a decoding error")
    func invalidBase64() {
        do {
            _ = try AudioCodec.base64Decode("not base64 ?!")
            Issue.record("expected throw")
        } catch let error as MojenticError {
            if case .decoding = error { return }
            Issue.record("wrong error: \(error)")
        } catch {
            Issue.record("wrong error: \(error)")
        }
    }
}
