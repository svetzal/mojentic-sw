import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A scripted response at the HTTP boundary.
struct RecoveryReply: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var body: String
    var truncated = false
    var hold = false
    var splitAt: Int?
    var holdSuffix = false
    var error: URLError.Code?
    var prefixDelay: TimeInterval = 0
}
