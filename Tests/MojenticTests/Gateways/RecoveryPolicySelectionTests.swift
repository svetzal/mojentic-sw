import Foundation
@testable import Mojentic
import Testing

// Bound simultaneous in-process fixtures while retaining every public matrix case.
@Suite(.serialized)
struct RecoveryPolicySelectionTests {
    @Test(arguments: RecoveryStatusBoundary.all, [500, 502])
    func removingDefaultStatusChangesClassification(
        _ boundary: RecoveryStatusBoundary, _ status: Int
    ) async throws {
        let defaults: Set<Int> = [429, 500, 502, 503, 504]
        try await assertTerminalStatus(
            boundary,
            status: status,
            attempts: 3,
            truncated: false,
            selection: .init(statuses: defaults, eligible: true),
        )
        try await assertTerminalStatus(
            boundary,
            status: status,
            attempts: 3,
            truncated: false,
            selection: .init(statuses: defaults.subtracting([status]), eligible: false),
        )
    }

    @Test(arguments: RecoveryStatusBoundary.all)
    func addingNonDefaultStatusChangesClassification(_ boundary: RecoveryStatusBoundary) async throws {
        let defaults: Set<Int> = [429, 500, 502, 503, 504]
        try await assertTerminalStatus(
            boundary,
            status: 418,
            attempts: 3,
            truncated: false,
            selection: .init(statuses: defaults, eligible: false),
        )
        try await assertTerminalStatus(
            boundary,
            status: 418,
            attempts: 3,
            truncated: false,
            selection: .init(statuses: defaults.union([418]), eligible: true),
        )
    }

    @Test(arguments: RecoveryStatusBoundary.all, [500, 502])
    func disablingHTTPChangesClassification(_ boundary: RecoveryStatusBoundary, _ status: Int) async throws {
        try await assertTerminalStatus(
            boundary,
            status: status,
            attempts: 3,
            truncated: true,
            selection: .init(statuses: [status], eligible: true),
        )
        try await assertTerminalStatus(
            boundary,
            status: status,
            attempts: 3,
            truncated: true,
            selection: .init(
                statuses: [status],
                categories: [.transport, .clientTimeout],
                eligible: false,
            ),
        )
    }

    @Test(arguments: RecoveryStatusBoundary.all)
    func removingTransportChangesClassification(_ boundary: RecoveryStatusBoundary) async throws {
        try await assertTerminalStatus(
            boundary,
            status: 200,
            attempts: 3,
            truncated: true,
            selection: .init(eligible: true),
        )
        try await assertTerminalStatus(
            boundary,
            status: 200,
            attempts: 3,
            truncated: true,
            selection: .init(categories: [.http, .clientTimeout], eligible: false),
        )
    }
}
