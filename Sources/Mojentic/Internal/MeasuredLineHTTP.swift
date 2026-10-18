import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking

    /// Observes progressive bytes without replacing the configured URLSession.
    ///
    /// The lock serializes callbacks even when the caller supplies a concurrent delegate queue.
    final class MeasuredLineHTTP: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private let timing: StreamMeasurement
        private let continuation: AsyncThrowingStream<String, any Error>.Continuation
        private let original: (any URLSessionTaskDelegate)?
        private var buffer = Data()

        init(
            timing: StreamMeasurement,
            continuation: AsyncThrowingStream<String, any Error>.Continuation,
            original: (any URLSessionTaskDelegate)?
        ) {
            self.timing = timing
            self.continuation = continuation
            self.original = original
        }

        func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            defer { lock.unlock() }
            guard let response = dataTask.response as? HTTPURLResponse,
                (200..<300).contains(response.statusCode)
            else { return }
            buffer.append(data)
            timing.observe(data)
            while let newline = buffer.firstIndex(of: 10) {
                continuation.yield(String(bytes: buffer[..<newline], encoding: .utf8) ?? "")
                buffer.removeSubrange(...newline)
            }
        }

        /// The SDK's completion can run before its queued data callbacks on Linux.
        ///
        /// Called by a barrier on the existing delegate queue so partial bytes and EOF
        /// are always observed before the line stream's terminal result.
        func finish(_ error: (any Error)?) {
            lock.lock()
            defer { lock.unlock() }
            timing.finishAttempt()
            if let error {
                continuation.finish(throwing: error)
            } else {
                if !buffer.isEmpty { continuation.yield(String(bytes: buffer, encoding: .utf8) ?? "") }
                continuation.finish()
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler:
                @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard let original else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            original.urlSession(
                session, task: task, didReceive: challenge, completionHandler: completionHandler)
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            guard let original else {
                completionHandler(request)
                return
            }
            original.urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: request,
                completionHandler: completionHandler)
        }
    }

#endif
