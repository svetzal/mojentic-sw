import Mojentic
import Testing

@Suite("Public recovery capabilities")
struct RecoveryCapabilityTests {

    @Test
    func ollamaCapabilities() {
        let capabilities = OllamaGateway.recoveryCapabilities
        #expect(capabilities.localRequestCancellation == .supported)
        #expect(capabilities.remoteRequestCancellation == .unsupported)
        #expect(capabilities.exactRequestStatus == .unsupported)
        #expect(capabilities.idempotency == .unknown)
        #expect(capabilities.exactAttemptTermination == .unknown)
    }

    @Test
    func oMLXCapabilities() {
        let capabilities = OMLXGateway.recoveryCapabilities
        #expect(capabilities.localRequestCancellation == .supported)
        #expect(capabilities.remoteRequestCancellation == .unsupported)
        #expect(capabilities.exactRequestStatus == .unsupported)
        #expect(capabilities.idempotency == .unknown)
        #expect(capabilities.exactAttemptTermination == .unknown)
    }

    @Test
    func openAICapabilities() {
        let capabilities = OpenAIGateway.recoveryCapabilities
        #expect(capabilities.localRequestCancellation == .supported)
        #expect(capabilities.remoteRequestCancellation == .unsupported)
        #expect(capabilities.exactRequestStatus == .unsupported)
        #expect(capabilities.idempotency == .unknown)
        #expect(capabilities.exactAttemptTermination == .unknown)
    }

    #if anthropic
        @Test
        func anthropicCapabilities() {
            let capabilities = AnthropicGateway.recoveryCapabilities
            #expect(capabilities.localRequestCancellation == .supported)
            #expect(capabilities.remoteRequestCancellation == .unsupported)
            #expect(capabilities.exactRequestStatus == .unsupported)
            #expect(capabilities.idempotency == .unknown)
            #expect(capabilities.exactAttemptTermination == .unknown)
        }
    #endif
}
