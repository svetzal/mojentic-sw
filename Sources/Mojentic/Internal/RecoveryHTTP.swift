import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Boundary for one evidence-preserving buffered wire send.
protocol BufferedRecoveryTransport: Sendable {
    func send(_ request: URLRequest) async -> RecoveryHTTPResult
}

/// Owns one URLSession task and buffers evidence even when transport fails.
///
/// The session delegate queue is serial; the lock also synchronizes cancellation.
final class RecoveryHTTP: NSObject, URLSessionDataDelegate, BufferedRecoveryTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var response: HTTPURLResponse?
    private var continuation: CheckedContinuation<RecoveryHTTPResult, Never>?
    private var task: URLSessionDataTask?
    private var cancelled = false
    private var captureCause: (any Error)?
    private var observed = RecoverySemanticProgress()
    private let identity: RecoveryIdentity
    private let observer: (@Sendable (RecoveryWireEvent) throws -> Void)?
    private let semantics: @Sendable (Data) -> RecoverySemanticProgress

    init(
        identity: RecoveryIdentity,
        observer: (@Sendable (RecoveryWireEvent) throws -> Void)?,
        semantics: @escaping @Sendable (Data) -> RecoverySemanticProgress
    ) {
        self.identity = identity
        self.observer = observer
        self.semantics = semantics
    }

    func send(_ request: URLRequest) async -> RecoveryHTTPResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpCookieStorage = nil
                configuration.urlCredentialStorage = nil
                configuration.httpShouldSetCookies = false
                configuration.urlCache = nil
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request)
                lock.lock()
                self.continuation = continuation
                self.task = task
                let cancelled = self.cancelled
                lock.unlock()
                task.resume()
                if cancelled { task.cancel() }
            }
        } onCancel: {
            self.lock.lock()
            self.cancelled = true
            let task = self.task
            self.lock.unlock()
            task?.cancel()
        }
    }

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        self.response = response as? HTTPURLResponse
        lock.unlock()
        do {
            if let response = response as? HTTPURLResponse {
                let headers = RecoveryHTTPResult(response: response, body: Data(), cause: nil).headers
                try observer?(.headers(identity, response.statusCode, headers))
            }
            completionHandler(.allow)
        } catch {
            lock.lock()
            captureCause = error
            lock.unlock()
            completionHandler(.cancel)
        }
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        bytes.append(data)
        let received = bytes
        lock.unlock()
        let semantic = semantics(received)
        lock.lock()
        observed.reasoningBytes = max(observed.reasoningBytes, semantic.reasoningBytes)
        observed.contentBytes = max(observed.contentBytes, semantic.contentBytes)
        observed.toolFragments = max(observed.toolFragments, semantic.toolFragments)
        observed.completedToolCalls = max(observed.completedToolCalls, semantic.completedToolCalls)
        lock.unlock()
        do {
            try observer?(.body(identity, data))
        } catch {
            lock.lock()
            captureCause = error
            let task = self.task
            lock.unlock()
            task?.cancel()
        }
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        needNewBodyStream completionHandler:
            @escaping @Sendable (InputStream?) -> Void
    ) {
        // Refuse body replay by URLSession; all admission belongs to the recovery engine.
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task _: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        let result = RecoveryHTTPResult(
            response: response,
            body: bytes,
            cause: captureCause ?? error,
            captureFailed: captureCause != nil,
            observed: observed
        )
        let continuation = self.continuation
        self.continuation = nil
        self.task = nil
        lock.unlock()
        continuation?.resume(returning: result)
        session.finishTasksAndInvalidate()
    }
}

struct RecoveryHTTPResult: Sendable {
    let response: HTTPURLResponse?
    let body: Data
    let cause: (any Error)?
    var captureFailed = false
    var observed = RecoverySemanticProgress()

    var headers: [String: String] {
        guard let response else { return [:] }
        return response.allHeaderFields.reduce(into: [:]) { result, entry in
            result[String(describing: entry.key)] = String(describing: entry.value)
        }
    }
}
