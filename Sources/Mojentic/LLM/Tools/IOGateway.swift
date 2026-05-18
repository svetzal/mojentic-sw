import Foundation

/// User-facing I/O boundary for tools that need to print to the user or
/// read a line from them.
///
/// The default ``StdIOGateway`` reads/writes via stdin/stdout. Tests
/// substitute ``ScriptedIOGateway`` (or a custom conforming type) to drive
/// tool behaviour deterministically.
public protocol IOGateway: Sendable {
    /// Print `message` to the user.
    func print(_ message: String) async

    /// Prompt the user with `prompt` and return the line they enter.
    ///
    /// Implementations may return `nil` at end-of-input.
    func readLine(prompt: String) async -> String?
}

/// Default `IOGateway` writing to stdout / reading from stdin.
public struct StdIOGateway: IOGateway {
    /// Create the default stdio gateway.
    public init() {}

    /// Print to stdout.
    public func print(_ message: String) async {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }

    /// Print the prompt to stdout and read a line from stdin.
    public func readLine(prompt: String) async -> String? {
        FileHandle.standardOutput.write(Data(prompt.utf8))
        return Swift.readLine()
    }
}

/// Test-friendly `IOGateway` that records `print` calls and serves pre-canned
/// `readLine` answers.
public actor ScriptedIOGateway: IOGateway {
    private var prompts: [String] = []
    private var answers: [String]
    private var output: [String] = []

    /// Create a gateway scripted with `answers` to return from `readLine`.
    public init(answers: [String] = []) {
        self.answers = answers
    }

    /// All `print` calls recorded so far.
    public func recordedOutput() -> [String] { output }

    /// All prompts seen by `readLine` so far.
    public func recordedPrompts() -> [String] { prompts }

    /// Record output without writing anywhere.
    public func print(_ message: String) async {
        output.append(message)
    }

    /// Return the next scripted answer, or `nil` when exhausted.
    public func readLine(prompt: String) async -> String? {
        prompts.append(prompt)
        guard !answers.isEmpty else { return nil }
        return answers.removeFirst()
    }
}
