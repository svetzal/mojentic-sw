import Foundation
import Mojentic

// This example deliberately permits one duplicate request only against a caller-owned
// scripted loopback server. A production controller must decide admission itself.
@main
struct RecoveryExample {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count == 3,
            arguments[2] == "--admit-scripted-retry",
            let host = URL(string: arguments[1]),
            host.scheme == "http", host.host == "127.0.0.1", host.port != nil,
            host.user == nil, host.password == nil, host.query == nil, host.fragment == nil,
            host.path.isEmpty || host.path == "/"
        else {
            print("Usage: RecoveryExample http://127.0.0.1:PORT --admit-scripted-retry")
            exit(2)
        }

        var policy = CompletionRecoveryPolicy()
        policy.maximumAttempts = 2  // Includes the initial request.
        policy.baseDelay = 0
        policy.delayCeiling = 1
        policy.budget = 5  // Bounds recovery waits, not active generation.
        policy.admission = { failure, nextWireNumber in
            // Unknown remote acceptance is retained. This flag authorizes duplicate work
            // on a synthetic server; a 503 itself never proves remote termination.
            let allowed =
                failure.provider == .omlx && failure.operation == .ordinary
                && failure.category == .http && failure.status == 503
                && failure.eligible && failure.acceptance == .unknown && nextWireNumber == 2
            print("admission next=\(nextWireNumber) decision=\(allowed ? "allow" : "reject")")
            return AsyncStream { continuation in
                continuation.yield(allowed ? .allow : .reject)
                continuation.finish()
            }
        }
        policy.observer = { event in
            if event.transition == .attemptFailed {
                print(
                    "attemptFailed wire=\(event.identity?.wireNumber ?? 0) "
                        + "status=\(event.status ?? 0) eligible=\(event.eligible == true) "
                        + "acceptance=\(event.acceptance.rawValue)")
            } else if event.transition == .attemptSucceeded {
                print("attemptSucceeded wire=\(event.identity?.wireNumber ?? 0)")
            }
        }
        let gateway = OMLXGateway(
            host: host,
            apiKey: ProcessInfo.processInfo.environment["RECOVERY_EXAMPLE_API_KEY"] ?? "",
            timeout: 10,
            recovery: policy)
        do {
            let response = try await gateway.complete(
                model: "scripted-model", messages: [.user("Demonstrate bounded recovery.")],
                tools: nil, config: .init())
            print(response.content)
        } catch let error as RecoveryError {
            // Safe summary only. inspectEvidence() and wire capture are sensitive.
            print(error.description)
            exit(1)
        } catch is CancellationError {
            print("Completion cancelled")
            exit(1)
        } catch {
            // Invalid policy limits may throw MojenticError before recovery dispatch.
            // Do not print arbitrary error text, URLs, credentials or raw evidence.
            print("Completion failed before a recovery result was available")
            exit(1)
        }
    }
}
