# Mojentic Swift — Agent Guidance

This file provides Swift-specific guidance for AI agents working in this
sub-project. The monorepo root `AGENTS.md` covers shared cross-port principles;
this file covers Swift-specific quality gates, tooling, and patterns.

## Project Overview

`mojentic-sw` is the Swift port of Mojentic. The Python implementation
(`mojentic-py`) is the source of truth for API design and feature behaviour.
See `SWIFT.md` in the `mojentic-unify` monorepo for the full plan, roadmap, and
parity-target rationale; see `PARITY.md` for the cross-port feature matrix.

## Toolchain

- **Swift 6.1 minimum** — required for Package Traits (provider gating) and the
  current strict-concurrency feature set.
- **Swift 6 language mode** — enforced via `swiftLanguageModes: [.v6]` in
  `Package.swift`. Strict concurrency is on; zero warnings tolerated.
- **Platforms**: macOS 13+, iOS 16+, tvOS 16+, watchOS 9+, visionOS 1+, Linux
  (current stable Swift toolchain).

## Mandatory Quality Gate

All gates must pass before any commit, matching the other ports. Run before
each commit:

```bash
swift format lint --strict --recursive Sources Tests && \
swiftlint --strict && \
swift build -c release && \
swift test --parallel
```

| Concern        | Tool                                | Command                                                              |
|----------------|-------------------------------------|----------------------------------------------------------------------|
| Format check   | swift-format                        | `swift format lint --strict --recursive Sources Tests`               |
| Format apply   | swift-format                        | `swift format --in-place --recursive Sources Tests`                  |
| Lint           | SwiftLint                           | `swiftlint --strict`                                                 |
| Build          | SwiftPM                             | `swift build -c release`                                             |
| Tests          | Swift Testing (preferred) + XCTest  | `swift test --parallel`                                              |
| Coverage       | llvm-cov via SwiftPM                | `swift test --enable-code-coverage`                                  |
| Security audit | Dependabot + manual lockfile review | Tracked in `Package.resolved` diffs; checklist in this file (TODO)   |
| API surface    | `swift package diagnose-api-...`    | Run pre-release against last tagged version                          |

CI (GitHub Actions) runs on macOS-latest and ubuntu-latest with the current
stable Swift toolchain, plus a job pinned to the Swift 6.1 minimum.

## Engineering Principles

Inherit from the monorepo `AGENTS.md`. Swift-specific applications:

### Functional core, imperative shell

- Pure value types (`struct`) for domain models — `Codable`, `Sendable`,
  immutable by default.
- Side effects (HTTP, file I/O, websockets) live behind `protocol` gateways.
  Gateway implementations are thin wrappers around `URLSession` /
  `URLSessionWebSocketTask` / `Foundation` — **no business logic**.
- `actor` types for stateful coordinators (broker, tracer event store, working
  memory, dispatcher, router, realtime session, websocket transport).

### Compose over inherit

- `protocol` + default extension implementations instead of inheritance.
- The `NullTracer` pattern uses a protocol with no-op defaults.

### Errors

- All public APIs that can fail are `throws` with a single `MojenticError` enum
  (typed throws where it adds clarity).
- **No `!` force-unwraps in library code.** If you need one, refactor.
- `fatalError` only for genuinely-unreachable invariant violations, never for
  recoverable conditions.

### Concurrency

- Cancellation is cooperative `Task` cancellation throughout; long-running
  tools must honour `Task.checkCancellation()` and clean up via
  `withTaskCancellationHandler`.
- Parallel tool execution uses `ThrowingTaskGroup`. Serial-default-for-chat-
  broker semantics are preserved; `ParallelToolRunner` is opt-in.
- **No `DispatchQueue`, no `OperationQueue`, no `@MainActor` in the library
  surface** — those are concerns of the consuming app.
- Every public type is `Sendable` or `@unchecked Sendable` with documented
  justification.

### Testing

- **Swift Testing** (`import Testing`, `@Test`, `#expect`) is the default for
  new test code. Use XCTest only when interoperability requires it.
- Test behaviour, not implementation. Only mock gateway/boundary types; never
  mock library internals.
- Do not test gateway classes unless they have custom logic — they're already
  thin wrappers.

## Documentation

- **DocC** is the documentation tool (`Sources/Mojentic/Mojentic.docc/`).
- Update doc comments in the same commit as the code change.
- Use Cases section uses `@Tutorials` (Building Chatbots, Structured Output,
  Building Agents, Image Analysis).
- Provided tools are documented as **examples** ("reference implementation,
  not core library feature").
- DocC is published to GitHub Pages on every `v*` tag.

## Version Synchronisation

Major and minor versions track the other ports (per
`mojentic-ru/AGENTS.md` Version Synchronisation). Patch versions move
independently. Update `CHANGELOG.md` in the same commit as code changes.

## Trunk-Based Development

Per user's global instructions: integrate directly to `main`. No long-lived
feature branches, no PRs as gates. Commit scoped, working changes; push to
`origin/main` after each commit. See user's `~/.claude/CLAUDE.md` for full
policy.
