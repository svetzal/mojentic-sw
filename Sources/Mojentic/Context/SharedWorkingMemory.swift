import Foundation

/// Concurrent-safe key/value store shared across agents in a dispatcher.
///
/// Backed by `JSONValue` so contents remain `Codable`, `Sendable`, and
/// `Hashable`. Each key is optionally namespaced by `correlationId` so
/// concurrent multi-tenant flows don't collide.
public actor SharedWorkingMemory {
    private var globalStore: [String: JSONValue] = [:]
    private var scoped: [UUID: [String: JSONValue]] = [:]

    /// Create an empty memory.
    public init() {}

    /// Read a value from the optionally-scoped namespace.
    public func get(_ key: String, scope: UUID? = nil) -> JSONValue? {
        if let scope { return scoped[scope]?[key] }
        return globalStore[key]
    }

    /// Write a value under the optionally-scoped namespace.
    public func set(_ key: String, to value: JSONValue, scope: UUID? = nil) {
        if let scope {
            var bucket = scoped[scope] ?? [:]
            bucket[key] = value
            scoped[scope] = bucket
        } else {
            globalStore[key] = value
        }
    }

    /// Remove a key.
    ///
    /// Returns `true` if anything was removed.
    @discardableResult
    public func delete(_ key: String, scope: UUID? = nil) -> Bool {
        if let scope {
            guard var bucket = scoped[scope], bucket.removeValue(forKey: key) != nil else {
                return false
            }
            scoped[scope] = bucket
            return true
        }
        return globalStore.removeValue(forKey: key) != nil
    }

    /// Return a value-type snapshot of the optionally-scoped namespace.
    public func snapshot(scope: UUID? = nil) -> [String: JSONValue] {
        if let scope { return scoped[scope] ?? [:] }
        return globalStore
    }
}
