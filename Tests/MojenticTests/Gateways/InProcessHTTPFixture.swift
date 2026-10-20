import Foundation
@testable import Mojentic
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// In-process HTTP boundary shared by buffered and streaming public-API tests.
///
/// The custom scheme cannot fall back to a network connection. Each fixture has
/// a unique host and session; the registry only routes requests to their weak owner.
final class InProcessHTTPFixture: @unchecked Sendable {
    private final class Owner: @unchecked Sendable {
        weak var value: InProcessHTTPFixture?
        init(_ value: InProcessHTTPFixture) { self.value = value }
    }
    private static let owners = RecoveryLocked<[String: Owner]>([:])
    private let bufferedSession = URLSession(configuration: InProcessHTTPFixture.makeSessionConfiguration())
    let authenticationChallenge: Bool
    private let clock = TestStreamClock.current
    let deliveries = RecoveryLocked<Int>(0)
    let trace = RecoveryCallTrace()
    let url: URL
    let requests = RecoveryLocked<[Data]>([])
    let requestHeaders = RecoveryLocked<[String]>([])
    let responseHeaders = RecoveryLocked<[Data]>([])
    let closedClients = RecoveryLocked<Int>(0)
    let arrivals: AsyncStream<Int>
    private let arrival: AsyncStream<Int>.Continuation
    private let replies: [RecoveryReply]
    private let condition = NSCondition()
    private var suffixReleased = false
    private var released = false
    private var suffixes: [@Sendable () -> Void] = []
    private var completions: [@Sendable () -> Void] = []
    private var deliveryRequired = false
    private var delivered = 0
    private var deliveryWaiters: [(Int, @Sendable () -> Void)] = []

    init(
        replies: [RecoveryReply] = [
            RecoveryReply(status: 503, body: "credential-and-payload-sentinel"),
            RecoveryReply(body: #"{"message":{"content":"recovered","thinking":"reasoning"},"done":true}"#),
        ],
        authenticationChallenge: Bool = false,
    ) throws {
        self.authenticationChallenge = authenticationChallenge
        self.replies = replies
        url = try #require(URL(string: "mojentic-fixture://\(UUID().uuidString.lowercased())"))
        let stream = AsyncStream<Int>.makeStream()
        arrivals = stream.stream
        arrival = stream.continuation
        Self.owners.withLock { $0[url.host ?? ""] = Owner(self) }
    }

    deinit {
        // Teardown can run on Foundation's work queue; invalidation synchronizes
        // with that queue on Linux, so perform it outside the callback.
        Task.detached { [bufferedSession] in bufferedSession.invalidateAndCancel() }
        Self.owners.withLock { _ = $0.removeValue(forKey: url.host ?? "") }
        arrival.finish()
    }

    fileprivate static func fixture(for request: URLRequest) -> InProcessHTTPFixture? {
        owners.withLock { $0[request.url?.host ?? ""]?.value }
    }

    var sessionConfiguration: URLSessionConfiguration { Self.makeSessionConfiguration() }

    private static func makeSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        return configuration
    }

    var session: URLSession { bufferedSession }

    var client: HTTPClient {
        HTTPClient(session: bufferedSession)
    }

    /// Configure each recovery attempt at the HTTP boundary without global registration.
    func isolated(_ policy: CompletionRecoveryPolicy) -> CompletionRecoveryPolicy {
        var policy = policy
        policy.httpSessionConfiguration = { Self.makeSessionConfiguration() }
        return policy
    }

    func release() {
        trace.record("fixture.release")
        condition.lock()
        released = true
        let callbacks = completions
        suffixes = []
        completions = []
        condition.unlock()
        callbacks.forEach { $0() }
    }

    func releaseSuffix() {
        trace.record("fixture.suffix.release")
        condition.lock()
        suffixReleased = true
        let callbacks = suffixes
        suffixes = []
        condition.unlock()
        callbacks.forEach { $0() }
    }

    func expectDeliveryReports() {
        condition.lock()
        deliveryRequired = true
        condition.unlock()
    }

    func reportDelivery(_ count: Int) {
        condition.lock()
        delivered += count
        deliveries.withLock { $0 += count }
        let callbacks = deliveryWaiters.filter { delivered >= $0.0 }.map(\.1)
        deliveryWaiters.removeAll { delivered >= $0.0 }
        condition.unlock()
        callbacks.forEach { $0() }
    }

    func waitForRequest(_ number: Int) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while requests.withLock({ $0.count }) < number { condition.wait() }
        return true
    }

    func waitForPeerClose() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while closedClients.withLock({ $0 }) == 0 { condition.wait() }
        return true
    }

    fileprivate func closed() {
        trace.record("boundary.closed")
        condition.lock()
        closedClients.withLock { $0 += 1 }
        condition.broadcast()
        condition.unlock()
    }

    /// Returns the complete request body that the URL protocol received.
    ///
    /// Darwin's URLSession moves the body into `httpBodyStream` before the
    /// protocol sees the request, so `httpBody` is nil there. FoundationNetworking
    /// keeps `httpBody`.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(contentsOf: buffer[0..<count])
        }
        return body
    }

    fileprivate func respond(
        request: URLRequest,
        headers: (Int, [String: String]) -> Void,
        data: @escaping @Sendable (Data) -> Void,
        finish: @escaping @Sendable (URLError.Code?) -> Void
    ) {
        let body = Self.body(of: request)
        condition.lock()
        let index = requests.withLock { values in
            values.append(body)
            return values.count - 1
        }
        requestHeaders.withLock {
            $0.append(
                "\(request.httpMethod ?? "POST") \(request.url?.path ?? "") HTTP/1.1\r\n"
                    + (request.allHTTPHeaderFields ?? [:]).map { "\($0.key): \($0.value)" }.joined(
                        separator: "\r\n"))
        }
        delivered = 0
        condition.broadcast()
        condition.unlock()
        trace.record("boundary.request", bytes: body)
        let reply = replies[min(index, replies.count - 1)]
        if let error = reply.error {
            finish(error)
            arrival.yield(index + 1)
            return
        }
        var fields = reply.headers
        fields["Content-Length"] = String(reply.body.utf8.count + (reply.truncated ? 20 : 0))
        fields["Connection"] = "close"
        fields["Content-Type"] = "application/json"
        responseHeaders.withLock {
            $0.append(Data(reply.headers.map { "\($0.key): \($0.value)\r\n" }.joined().utf8))
        }
        headers(reply.status, fields)
        let bytes = Data(reply.body.utf8)
        let split = reply.splitAt ?? (reply.hold && !reply.truncated ? bytes.count / 2 : bytes.count)
        clock?.advance(Int64(reply.prefixDelay * 1000))
        if split > 0 { data(Data(bytes.prefix(split))) }
        let finishAt: @Sendable (Int) -> Void = { [weak self] count in
            guard let self else { return }
            let complete: @Sendable () -> Void = { finish(reply.truncated ? .networkConnectionLost : nil) }
            self.condition.lock()
            if self.deliveryRequired && self.delivered < count && reply.truncated {
                self.deliveryWaiters.append((count, complete))
                self.condition.unlock()
            } else {
                self.condition.unlock()
                complete()
            }
        }
        let supplied = RecoveryLocked(false)
        let supply: @Sendable () -> Void = {
            let first = supplied.withLock { value in
                defer { value = true }
                return !value
            }
            if first, split < bytes.count { data(Data(bytes.dropFirst(split))) }
        }
        let suffix: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            supply()
            self.condition.lock()
            let shouldFinish = !reply.hold || self.released
            self.condition.unlock()
            if shouldFinish { finishAt(bytes.count) }
        }
        let close: @Sendable () -> Void = {
            if !reply.holdSuffix { supply() }
            finishAt(supplied.withLock { $0 } ? bytes.count : split)
        }
        condition.lock()
        let alreadyReleased = released
        let alreadySupplied = suffixReleased
        if reply.holdSuffix && !alreadySupplied && !alreadyReleased { suffixes.append(suffix) }
        if (reply.hold || reply.holdSuffix) && !alreadyReleased { completions.append(close) }
        condition.unlock()
        if reply.holdSuffix {
            if alreadySupplied { suffix() }
            if alreadyReleased { close() }
        } else if !reply.hold || alreadyReleased {
            supply()
            finishAt(bytes.count)
        }
        arrival.yield(index + 1)
    }
}

/// URLProtocol is deliberately non-Sendable.
///
/// Only this locked delivery owner crosses threads; callbacks and cancellation acquire the same lock.
private final class FixtureDelivery: NSObject, URLAuthenticationChallengeSender, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private weak var owner: FixtureURLProtocol?
    private var stopped = false
    private weak var fixture: InProcessHTTPFixture?
    init(_ owner: FixtureURLProtocol, fixture: InProcessHTTPFixture) {
        self.owner = owner
        self.fixture = fixture
    }
    func data(_ bytes: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, let owner else { return }
        owner.client?.urlProtocol(owner, didLoad: bytes)
    }
    func finish(_ error: URLError.Code?) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, let owner else { return }
        stopped = true
        fixture?.closed()
        if let error {
            owner.client?.urlProtocol(owner, didFailWithError: URLError(error))
        } else {
            owner.client?.urlProtocolDidFinishLoading(owner)
        }
    }
    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        if !stopped {
            stopped = true
            fixture?.closed()
        }
    }
    func use(_: URLCredential, for _: URLAuthenticationChallenge) { finish(.userAuthenticationRequired) }
    func continueWithoutCredential(for _: URLAuthenticationChallenge) { finish(.userAuthenticationRequired) }
    func cancel(_: URLAuthenticationChallenge) { cancel() }
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {
        continueWithoutCredential(for: challenge)
    }
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {
        continueWithoutCredential(for: challenge)
    }

}

private final class FixtureURLProtocol: URLProtocol {
    private var delivery: FixtureDelivery?
    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "mojentic-fixture"
    }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture = InProcessHTTPFixture.fixture(for: request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let delivery = FixtureDelivery(self, fixture: fixture)
        self.delivery = delivery
        let challenge = fixture.authenticationChallenge
        fixture.respond(
            request: request,
            headers: { status, fields in
                if challenge {
                    let space = URLProtectionSpace(
                        host: url.host ?? "fixture",
                        port: 0,
                        protocol: url.scheme,
                        realm: "timing",
                        authenticationMethod: NSURLAuthenticationMethodHTTPBasic,
                    )
                    client?.urlProtocol(
                        self,
                        didReceive: URLAuthenticationChallenge(
                            protectionSpace: space,
                            proposedCredential: nil,
                            previousFailureCount: 0,
                            failureResponse: nil,
                            error: nil,
                            sender: delivery,
                        ))
                    return
                }
                guard
                    let response = HTTPURLResponse(
                        url: url, statusCode: status, httpVersion: nil, headerFields: fields)
                else { return }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            },
            data: { if !challenge { delivery.data($0) } },
            finish: { if !challenge { delivery.finish($0) } })
    }
    override func stopLoading() { delivery?.cancel() }

}

extension InProcessHTTPFixture: LineStreamingTransport {
    func streamLines(
        url: URL, body: some Encodable, headers: [String: String]
    ) async throws -> AsyncThrowingStream<String, any Error> {
        try await makeLines(url: url, body: body, headers: headers, timing: nil)
    }

    func streamLines(
        url: URL, body: some Encodable, headers: [String: String], timing: StreamMeasurement
    ) async throws -> AsyncThrowingStream<String, any Error> {
        timing.start()
        return try await makeLines(url: url, body: body, headers: headers, timing: timing)
    }

    private func makeLines(
        url: URL, body: some Encodable, headers: [String: String], timing: StreamMeasurement?
    ) async throws -> AsyncThrowingStream<String, any Error> {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        request.httpBody = try encoder.encode(body)
        request.allHTTPHeaderFields = headers
        let stream = AsyncThrowingStream<String, any Error>.makeStream()
        let buffer = RecoveryLocked(Data())
        let received = RecoveryLocked(Data())
        let status = RecoveryLocked(200)
        stream.continuation.onTermination = { [weak self] _ in self?.closed() }
        respond(
            request: request,
            headers: { code, _ in status.withLock { $0 = code } },
            data: { [weak self] bytes in
                received.withLock { $0.append(bytes) }
                timing?.observe(bytes)
                buffer.withLock { value in
                    value.append(bytes)
                    while let newline = value.firstIndex(of: 10) {
                        stream.continuation.yield(String(bytes: value[..<newline], encoding: .utf8) ?? "")
                        value.removeSubrange(...newline)
                    }
                }
                self?.reportDelivery(bytes.count)
            },
            finish: { error in
                let code = status.withLock { $0 }
                if code >= 400 {
                    stream.continuation.finish(
                        throwing: MojenticError.http(
                            status: code, body: String(bytes: received.withLock { $0 }, encoding: .utf8) ?? ""
                        ))
                } else if let error {
                    stream.continuation.finish(throwing: URLError(error))
                } else {
                    stream.continuation.finish()
                }
            })
        return stream.stream
    }
}
