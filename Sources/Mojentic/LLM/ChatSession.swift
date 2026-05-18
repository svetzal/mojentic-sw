import Foundation

/// Stateful, multi-turn conversation wrapper around `LLMBroker`.
///
/// `ChatSession` owns the message history, an optional system prompt, an
/// optional tool set, and an optional `ContextWindowManager` that trims the
/// history before each send. It is the per-port "Streaming Send" parity
/// surface: `send` and `stream` both auto-manage history.
///
/// `actor` because history mutation must not race with concurrent sends.
public actor ChatSession {
    private let broker: LLMBroker
    private let model: String
    private let tools: [any LLMTool]
    private let config: CompletionConfig
    private let contextManager: (any ContextWindowManager)?
    private let systemPrompt: String?
    private var history: [LLMMessage]

    /// Create a chat session.
    ///
    /// - Parameters:
    ///   - broker: The broker that runs completions.
    ///   - model: Model identifier passed to the broker on every call.
    ///   - systemPrompt: Optional system turn pinned at the head of the
    ///     conversation.
    ///   - tools: Tools exposed to the model on every send.
    ///   - config: Completion configuration applied to every send.
    ///   - contextWindowManager: Optional manager invoked before each send to
    ///     trim the history.
    public init(
        broker: LLMBroker,
        model: String,
        systemPrompt: String? = nil,
        tools: [any LLMTool] = [],
        config: CompletionConfig = CompletionConfig(),
        contextWindowManager: (any ContextWindowManager)? = nil
    ) {
        self.broker = broker
        self.model = model
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.config = config
        self.contextManager = contextWindowManager
        if let systemPrompt {
            self.history = [LLMMessage.system(systemPrompt)]
        } else {
            self.history = []
        }
    }

    /// Returns a snapshot of the current conversation history.
    public func messages() -> [LLMMessage] { history }

    /// Reset the history.
    ///
    /// Preserves the original system prompt.
    public func clear() {
        if let systemPrompt {
            history = [LLMMessage.system(systemPrompt)]
        } else {
            history = []
        }
    }

    /// Append the user turn, run the broker, append the final assistant turn,
    /// and return the response.
    public func send(_ text: String) async throws -> LLMResponse {
        let userMessage = LLMMessage.user(text)
        history.append(userMessage)
        do {
            let trimmed = try await prepared(history)
            let response = try await broker.complete(
                model: model,
                messages: trimmed,
                tools: tools,
                config: config
            )
            history.append(LLMMessage.assistant(response.content))
            return response
        } catch {
            // Roll the user turn back so the conversation state stays consistent.
            if history.last == userMessage {
                history.removeLast()
            }
            throw error
        }
    }

    /// Multimodal send: pair text with image attachments before sending.
    public func send(text: String, images: [ImageContent]) async throws -> LLMResponse {
        let userMessage = LLMMessage.user(text: text, images: images)
        history.append(userMessage)
        do {
            let trimmed = try await prepared(history)
            let response = try await broker.complete(
                model: model,
                messages: trimmed,
                tools: tools,
                config: config
            )
            history.append(LLMMessage.assistant(response.content))
            return response
        } catch {
            if history.last == userMessage {
                history.removeLast()
            }
            throw error
        }
    }

    /// Streaming variant of `send`.
    ///
    /// Accumulates content deltas, surfaces them to the caller in real time,
    /// then commits the finalised assistant turn once the stream completes
    /// successfully.
    ///
    /// On stream error or cancellation the partial assistant turn is **not**
    /// committed — the convo state stays consistent.
    public nonisolated func stream(_ text: String) -> AsyncThrowingStream<StreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runStream(text: text, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: MojenticError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runStream(
        text: String,
        continuation: AsyncThrowingStream<StreamEvent, any Error>.Continuation
    ) async throws {
        let userMessage = LLMMessage.user(text)
        history.append(userMessage)
        var accumulated = ""
        var finalResponse: LLMResponse?
        do {
            let trimmed = try await prepared(history)
            let upstream = broker.stream(
                model: model,
                messages: trimmed,
                tools: tools,
                config: config
            )
            for try await event in upstream {
                switch event {
                case .textDelta(let delta):
                    accumulated += delta
                case .done(let response):
                    finalResponse = response
                default:
                    break
                }
                continuation.yield(event)
            }
        } catch {
            if history.last == userMessage {
                history.removeLast()
            }
            throw error
        }
        let content = finalResponse?.content ?? accumulated
        history.append(LLMMessage.assistant(content))
    }

    private func prepared(_ messages: [LLMMessage]) async throws -> [LLMMessage] {
        guard let contextManager else { return messages }
        return try await contextManager.trim(messages, reserving: config.maxTokens)
    }
}
