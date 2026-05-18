import Foundation

/// Resolves a small set of natural-language relative date expressions to
/// ISO-8601 dates (`YYYY-MM-DD`).
///
/// This is a reference implementation of an `LLMTool`, intentionally narrow
/// in scope. It handles patterns like "today", "tomorrow", "yesterday",
/// "next Friday", "last Monday", and "in N days". Anything more elaborate
/// should be solved with a richer NLP library wired in by the consumer.
public struct DateResolverTool: LLMTool {
    /// Closure returning the current reference date.
    ///
    /// Injectable for tests.
    private let now: @Sendable () -> Date

    /// Calendar used for arithmetic.
    ///
    /// Injectable for tests and non-Gregorian use.
    private let calendar: Calendar

    /// Create a date resolver, optionally injecting a clock and calendar.
    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) {
        self.now = now
        var cal = calendar
        cal.timeZone = calendar.timeZone
        self.calendar = cal
    }

    /// Descriptor surfaced to the LLM for this tool.
    public var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: "resolve_date",
            description:
                "Resolve a natural-language relative date (e.g. 'tomorrow', 'next Friday') "
                + "to an absolute ISO-8601 date. If no reference date is provided the current date is used.",
            parameters: [
                "type": "object",
                "properties": [
                    "relative_date": [
                        "type": "string",
                        "description": "The natural-language relative date expression.",
                    ],
                    "reference_date": [
                        "type": "string",
                        "description":
                            "Optional ISO-8601 (YYYY-MM-DD) reference date. Defaults to today.",
                    ],
                ],
                "required": ["relative_date"],
                "additionalProperties": false,
            ]
        )
    }

    /// Execute the resolver against `arguments`.
    public func execute(arguments: JSONValue) async throws -> JSONValue {
        guard let object = arguments.objectValue,
            let relative = object["relative_date"]?.stringValue
        else {
            throw MojenticError.invalidArgument(
                message: "resolve_date requires a 'relative_date' string"
            )
        }
        let reference = object["reference_date"]?.stringValue.flatMap(Self.parseISODate)
        let resolved = try resolve(relative: relative, reference: reference ?? now())
        let iso = Self.formatISODate(resolved, calendar: calendar)
        return [
            "relative_date": .string(relative),
            "resolved_date": .string(iso),
            "summary": .string("The date on '\(relative)' is \(iso)"),
        ]
    }

    private func resolve(relative: String, reference: Date) throws -> Date {
        let normalised = relative.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalised == "today" { return reference }
        if normalised == "tomorrow" {
            return try addDays(1, to: reference)
        }
        if normalised == "yesterday" {
            return try addDays(-1, to: reference)
        }
        if let days = matchInNDays(normalised) {
            return try addDays(days, to: reference)
        }
        if let target = matchWeekday(normalised, reference: reference) {
            return target
        }
        throw MojenticError.invalidArgument(
            message: "Could not resolve relative date '\(relative)'"
        )
    }

    private func addDays(_ days: Int, to date: Date) throws -> Date {
        guard let result = calendar.date(byAdding: .day, value: days, to: date) else {
            throw MojenticError.invalidArgument(message: "Date arithmetic failed for '\(date)'")
        }
        return result
    }

    private func matchInNDays(_ text: String) -> Int? {
        // Match "in N days" or "N days ago".
        let parts = text.split(separator: " ").map(String.init)
        if parts.count == 3, parts[0] == "in", parts[2] == "days", let count = Int(parts[1]) {
            return count
        }
        if parts.count == 3, parts[2] == "ago", parts[1] == "days", let count = Int(parts[0]) {
            return -count
        }
        return nil
    }

    private func matchWeekday(_ text: String, reference: Date) -> Date? {
        // Match "next <weekday>" / "last <weekday>".
        let weekdays: [String: Int] = [
            "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
            "thursday": 5, "friday": 6, "saturday": 7,
        ]
        let parts = text.split(separator: " ").map(String.init)
        guard parts.count == 2, let target = weekdays[parts[1]] else { return nil }
        let current = calendar.component(.weekday, from: reference)
        let direction = parts[0]
        let delta: Int
        switch direction {
        case "next":
            let diff = (target - current + 7) % 7
            delta = diff == 0 ? 7 : diff
        case "last":
            let diff = (current - target + 7) % 7
            delta = diff == 0 ? -7 : -diff
        default:
            return nil
        }
        return calendar.date(byAdding: .day, value: delta, to: reference)
    }

    private static func parseISODate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    private static func formatISODate(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
