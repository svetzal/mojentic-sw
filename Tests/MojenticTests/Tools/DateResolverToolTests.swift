import Foundation
import Testing

@testable import Mojentic

@Suite("DateResolverTool")
struct DateResolverToolTests {
    private static func fixedDate() -> Date {
        // 2026-05-15 (Friday) at 12:00 UTC.
        var components = DateComponents()
        components.year = 2_026
        components.month = 5
        components.day = 15
        components.hour = 12
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components) ?? Date()
    }

    private static func makeTool() -> DateResolverTool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return DateResolverTool(now: { fixedDate() }, calendar: calendar)
    }

    @Test("resolves 'today' to the reference date")
    func resolveToday() async throws {
        let result = try await Self.makeTool().execute(arguments: ["relative_date": "today"])
        #expect(result.objectValue?["resolved_date"]?.stringValue == "2026-05-15")
    }

    @Test("resolves 'tomorrow' to the next day")
    func resolveTomorrow() async throws {
        let result = try await Self.makeTool().execute(arguments: ["relative_date": "tomorrow"])
        #expect(result.objectValue?["resolved_date"]?.stringValue == "2026-05-16")
    }

    @Test("resolves 'next Friday' to the following week's Friday")
    func resolveNextFriday() async throws {
        let result = try await Self.makeTool().execute(arguments: ["relative_date": "next Friday"])
        #expect(result.objectValue?["resolved_date"]?.stringValue == "2026-05-22")
    }

    @Test("resolves 'in N days' arithmetic")
    func resolveInNDays() async throws {
        let result = try await Self.makeTool().execute(arguments: ["relative_date": "in 10 days"])
        #expect(result.objectValue?["resolved_date"]?.stringValue == "2026-05-25")
    }

    @Test("rejects unknown expressions with an invalid-argument error")
    func unknownExpression() async {
        do {
            _ = try await Self.makeTool().execute(arguments: ["relative_date": "next century"])
            Issue.record("expected throw")
        } catch let error as MojenticError {
            if case .invalidArgument = error {
                return
            }
            Issue.record("unexpected error: \(error)")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
