import Foundation

// MARK: - Configuration

/// Resolved oMLX gateway settings: explicit value, then environment, then default.
struct OMLXConfiguration: Sendable, Equatable {
    /// `http://localhost:8000`.
    static let defaultHost: URL = {
        guard let url = URL(string: "http://localhost:8000") else {
            preconditionFailure("Built-in oMLX host must be valid")
        }
        return url
    }()

    /// Ten minutes, in seconds.
    static let defaultTimeout: TimeInterval = 600

    /// Server address without `/v1`.
    let host: URL
    /// Bearer token; `nil` sends no `Authorization` header.
    let apiKey: String?
    /// Idle timeout in seconds for every request.
    let timeout: TimeInterval

    /// The API root: the host plus `/v1`.
    var baseURL: URL {
        host.appendingPathComponent("v1")
    }

    init(host: URL = Self.defaultHost, apiKey: String? = nil, timeout: TimeInterval = Self.defaultTimeout) {
        self.host = host
        self.apiKey = apiKey
        self.timeout = timeout
    }

    /// Resolve each setting from its explicit value, then `environment`,
    /// then the default.
    ///
    /// Empty environment values count as unset. `OMLX_TIMEOUT` is in
    /// milliseconds; a value that is not a positive number falls back to
    /// the default, as does an `OMLX_HOST` that is not a URL.
    static func resolve(
        host: URL?,
        apiKey: String?,
        timeout: TimeInterval?,
        environment: [String: String],
    ) -> OMLXConfiguration {
        func value(_ name: String) -> String? {
            guard let value = environment[name]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
                return nil
            }
            return value
        }
        let environmentHost = value("OMLX_HOST").flatMap { URL(string: $0) }
        let environmentTimeout = value("OMLX_TIMEOUT").flatMap(Double.init).flatMap {
            $0 > 0 ? $0 / 1000 : nil
        }
        return OMLXConfiguration(
            host: host ?? environmentHost ?? defaultHost,
            apiKey: apiKey.map { $0.isEmpty ? nil : $0 } ?? value("OMLX_API_KEY"),
            timeout: timeout ?? environmentTimeout ?? defaultTimeout,
        )
    }
}
