# Mojentic Swift — Agent Guidance

## Coordinated 3.0.0 release authorization

**Release authorized (Stacey, 2026-10-18).** All six ports passed their 3.0.0 readiness self-assessments and CI on `main`. Publish 3.0.0 now through `foundry release <port> --bump major`, following this file's normal release process. For this release, this lifts the coordinated release hold and any instruction in this section not to bump the version, tag or publish. The CHANGELOG `Unreleased` section becomes the 3.0.0 entry.

Stacey authorized the coordinated major release on October 15, 2026 in
[`mojentic-unify/RELEASE-3.0.0.md`](https://github.com/svetzal/mojentic-unify/blob/main/RELEASE-3.0.0.md).
That authorization supersedes the September 30 coordinated 2.1.0 instructions.
The release includes transient recovery with the October 12 amendment, native
reasoning, and model metadata/request fidelity across all six ports.

Release only when all six ports are ready, their conformance records cover
parts 1–3, and required gates and CI pass. Keep the publication hold until
those conditions are met. Swift's git tag is its package version; keep
`swift-tools-version` at 6.1. Follow the coordinator's release process only
when release work is explicitly assigned.

The authorized release includes native reasoning (part 2), following
`REASONING-PROTOTYPE-2026-10.md` and the Rust reference, and model metadata
and request fidelity (part 3), following `MODEL-METADATA-2026-10.md`.
Part 3 sections 3.2–3.6 request fidelity and section 1 raw-byte discovery
invariance are implemented. The current correction implements section 2
client-measured first-token timing, including the October 17 decisions.
The owner decision excludes Anthropic initial empty tool input from timing;
only nonempty input fragments start tool timing. Zero-argument calls without
fragments retain duration only; see `CONFORMANCE-3.0.0.md`.
Preserve recovery, native reasoning outside the specified shape alignment,
dependencies, swift-tools-version, versions,
tags and publication state. Foundry owns Git finalization for its isolated task
worktrees: leave changes uncommitted and do not push or modify refs there.

This file provides Swift-specific guidance for AI agents working in this
sub-project. The monorepo root `AGENTS.md` covers shared cross-port principles;
this file covers Swift-specific quality gates, tooling, and patterns.

## Project Overview

`mojentic-sw` is the Swift port of Mojentic. The Elixir implementation
(`mojentic-ex`) is the source of truth for API design and feature behaviour.
See `SWIFT.md` in the `mojentic-unify` monorepo for the full plan, roadmap, and
parity-target rationale; see `PARITY.md` for the cross-port feature matrix.

## Toolchain

- **Swift 6.1 minimum** — required for Package Traits (provider gating) and the
  current strict-concurrency feature set. `swift-tools-version` stays at 6.1.
- **Swift 6.4 current** — the toolchain CI, Foundry (`mojility-ops-01`, via
  mise) and the Mac (Xcode 27) use. SwiftLint 0.65.1.
- **Run swift-format on Linux before you trust a clean result.** Linux
  swift-format has no NaturalLanguage framework, so
  `BeginDocumentationCommentWithOneLineSummary` splits sentences at every
  period (`e.g.`, `cutoff. \`nil\``). A summary that passes on macOS can fail
  on Linux. Write the first doc-comment sentence as one sentence, then a
  blank `///` line.
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
swift test --parallel && \
swift test --traits full && \
swift package --disable-sandbox generate-documentation --target Mojentic \
  --output-path .build/docs --warnings-as-errors
```

Foundry's nightly maintenance on `mojility-ops-01` runs the same gate from
`.hone-gates.json` (gates `format`, `lint`, `build`, `test`,
`test-full-traits`, `docs`, all required). Every command works on macOS and on
Linux. Keep the two in step when the gate changes.

| Concern        | Tool                                | Command                                                              |
|----------------|-------------------------------------|----------------------------------------------------------------------|
| Format check   | swift-format                        | `swift format lint --strict --recursive Sources Tests`               |
| Format apply   | swift-format                        | `swift format --in-place --recursive Sources Tests`                  |
| Lint           | SwiftLint                           | `swiftlint --strict`                                                 |
| Build          | SwiftPM                             | `swift build -c release`                                             |
| Tests          | Swift Testing (preferred) + XCTest  | `swift test --parallel`                                              |
| Tests (all)    | Swift Testing, every provider trait | `swift test --traits full`                                           |
| Docs           | DocC                                | `swift package --disable-sandbox generate-documentation ...` (above) |
| Coverage       | llvm-cov via SwiftPM                | `swift test --enable-code-coverage`                                  |
| API surface    | `swift package diagnose-api-...`    | Run pre-release against last tagged version                          |

CI (GitHub Actions) runs on the `xcode-27` macOS image and in the
`swift:6.4-noble` Linux container with the current stable Swift toolchain,
plus a `swift:6.1-noble` job for the declared minimum. The format and lint
gates run on Linux (`ghcr.io/realm/swiftlint:0.65.1` for SwiftLint).

### Dependency diligence

Review tracked `Package.resolved` and its diff whenever dependencies move.
Keep the native resolve/build/test/format/lint/DocC checks; their success checks
resolution, compatibility and documentation, not whether dependencies are safe.
Dependabot update PRs are not configured: Foundry's nightly maintenance keeps
dependencies current.

The tooling review on October 23, 2026 used Linux Swift 6.4.1. Local
`swift package --help` exposes `resolve`, `show-dependencies` and `generate-sbom`,
but no automated advisory check. `experimental-audit-binary-artifact --help`
describes undefined-symbol checking for static libraries, not advisory matching.
An SBOM is an inventory, not a vulnerability assessment.
[Swift Package Audit](https://github.com/crleonard/swift-package-audit) documents
metadata health and optional newer-tag checks, not advisory matching. No suitable
established, maintained Swift-native automated advisory check was identified in
this review. No replacement scanner, runtime, account or service is added.
The Google osv-scanner requirement and its sole-purpose `security.yml` workflow
are removed; there is no automated dependency advisory gate or green audit claim.

Reviewed inventory at base commit `71a4597e634032e585ba59ee900aa638a27f1622`
(`HEAD`, local `main` and live `origin/main` matched before edits):

| Package | Resolved version | Pinned revision | Role |
| --- | --- | --- | --- |
| `apple/swift-log` | 1.16.2 | `c9c6bb9d275ec0d95c3ad16391f3f045dc623104` | Direct library dependency |
| `swiftlang/swift-docc-plugin` | 1.5.0 | `647c708be89f834fa6a6d4945442793a77ddf5b6` | Direct documentation tooling |
| `swiftlang/swift-docc-symbolkit` | 1.0.0 | `b45d1f2ed151d057b54504d653e0da5552844e34` | Transitive documentation dependency |

The manifest keeps `swift-log` from 1.15.1 and `swift-docc-plugin` from 1.5.0;
lockfile format 3 pins all three source-control dependencies above. This review
does not change constraints or pins and does not establish an absence of
vulnerabilities. Existing GitHub advisory/alert visibility, where available, is
supplementary evidence only; repository alert settings and alert status were not
verified here. It is neither a native scanner nor a safety guarantee.

Validation of this correction on Linux Swift 6.4.1: `swift package resolve`
and `swift package show-dependencies --format json` passed through the gate
environment wrapper, confirming the inventory without changing the lockfile.
All six exact `.hone-gates.json` commands passed through the same wrapper and
`foundry capture`: format, strict SwiftLint, release build, parallel tests
(443 tests in 129 suites), full-trait tests (463 tests in 136 suites) and DocC
with warnings as errors. Both test gates also passed the deterministic-operation
guard and `swift-deterministic-contracts-v1` executable-source/catalog manifest
verification. No application boundary or executable contract changes are
involved. These are native quality results, not an advisory audit result.

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

## Deterministic public-API conformance

Tests and verification scripts must use in-process gateway/HTTP boundary doubles,
never sockets, servers, remote registries, real sleeps or elapsed-time thresholds.
Use the per-completion clock seam for exact stream measurements and continuation
signals for ordering/cancellation. Keep `RecoveryReply` and `RecoveryLocked`
shared across recovery and native-reasoning support. Do not mock library internals.
Both test gates run the versioned contract-source manifest verification through
`scripts/with-gate-environment`; CI uses the same wrapper. See
[deterministic test guidance](docs/DETERMINISTIC-TESTS.md) for the decision map,
fixture provenance, inspection and verification scope. A changed manifest must
be reviewed with its executable assertions; hashes alone are not behavior proof.
