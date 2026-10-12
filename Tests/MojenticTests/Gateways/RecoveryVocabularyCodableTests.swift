import Foundation
import Mojentic
import Testing

struct RecoveryVocabularyCodableTests {
    @Test(arguments: RecoveryProvider.allCases)
    func providerRoundTrip(_ provider: RecoveryProvider) throws {
        let encoded = try JSONEncoder().encode(provider)
        #expect(try JSONDecoder().decode(String.self, from: encoded) == provider.rawValue)
        #expect(try JSONDecoder().decode(RecoveryProvider.self, from: encoded) == provider)
        // An exhaustive public API consumer compiles with or without the Anthropic trait.
        let expected: String
        switch provider {
        case .ollama: expected = "ollama"
        case .omlx: expected = "omlx"
        case .openAI: expected = "openai"
        case .anthropic: expected = "anthropic"
        }
        #expect(provider.rawValue == expected)
    }

    @Test(arguments: RecoveryOperation.allCases)
    func operationRoundTrip(_ operation: RecoveryOperation) throws {
        let encoded = try JSONEncoder().encode(operation)
        #expect(try JSONDecoder().decode(String.self, from: encoded) == operation.rawValue)
        #expect(try JSONDecoder().decode(RecoveryOperation.self, from: encoded) == operation)
        let expected: String
        switch operation {
        case .ordinary: expected = "ordinary"
        case .structured: expected = "structured"
        case .streaming: expected = "streaming"
        }
        #expect(operation.rawValue == expected)
    }

    @Test(arguments: ["", "unknown", "OpenAI", "oMLX"])
    func rejectsUnknownProvider(_ value: String) throws {
        let encoded = try JSONEncoder().encode(value)
        #expect(RecoveryProvider(rawValue: value) == nil)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RecoveryProvider.self, from: encoded)
        }
    }

    @Test(arguments: ["", "unknown", "complete", "completeStructured", "streamRecovering"])
    func rejectsUnknownOperationAndAliases(_ value: String) throws {
        let encoded = try JSONEncoder().encode(value)
        #expect(RecoveryOperation(rawValue: value) == nil)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RecoveryOperation.self, from: encoded)
        }
    }
}
