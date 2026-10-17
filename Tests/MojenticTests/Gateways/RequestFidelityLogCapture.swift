import Logging

/// Installs one process-wide handler and records the actual gateway diagnostics.
enum RequestFidelityLogCapture {
    struct Entry: Sendable, Equatable {
        let label: String
        let level: Logger.Level
        let message: String
    }

    @TaskLocal static var recording = false

    static let entries = RecoveryLocked<[Entry]>([])
    static let install: Void = LoggingSystem.bootstrap { Handler(label: $0) }

    private struct Handler: LogHandler {
        let label: String
        var logLevel: Logger.Level = .info
        var metadata: Logger.Metadata = [:]

        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }

        func log(event: LogEvent) {
            guard recording else { return }
            entries.withLock {
                $0.append(Entry(label: label, level: event.level, message: event.message.description))
            }
        }
    }
}
