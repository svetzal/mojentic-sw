# Swift streaming timing contract fixtures

The executable set is `swift-deterministic-contracts-v1`: the `FirstToken*Tests.swift`
public-API tests with in-process HTTP and line transports. The adjacent
`deterministic_contracts_v1.manifest.sha256` identifies executable sources.

`stream_first_token_v1.json` reuses the static `ex-stream-first-token-v1` case
catalog from mojentic-ex commit `f42c5c8d7e9fa9070fe7d86d6d4874dff07ff3b4`:
https://github.com/svetzal/mojentic-ex/blob/f42c5c8d7e9fa9070fe7d86d6d4874dff07ff3b4/test/contracts/stream_first_token_v1.json

The original catalog SHA-256 is `fddd71c8e0062c489588b2e15df749e934cf9d9412d05b4ee08eb52673425a6c`.
The adjacent manifest verifies the extended local catalog bytes. Swift consumes the named delta
cases through its public APIs and in-process boundary doubles derived from those cases.

The binding reference is `ts-stream-first-token-v1`, inspected at TypeScript
commit `b8db5d59c02297e39335ba1deed83fa04e1b8f11`:
https://github.com/svetzal/mojentic-ts/blob/b8db5d59c02297e39335ba1deed83fa04e1b8f11/src/llm/first-token-http.test.ts

Reference SHA-256: `e94d4f53928b3ea519eceedcb0f7e7a41ae2eb5da52076369d92374108b3d2a8`.
The reused catalog also identifies later reference cases; no external library's
executable snapshot or dependent adoption is required for Swift self-validation.

Timing relationships use the authorized `StreamMeasurement` clock seam,
per-case virtual instants and explicit transport-delivery signals. Prefix release,
admitted retry waits and tool execution advance injected time; they never sleep.
The source implementation still uses a production monotonic clock by default.

The binding owner decision extends this local executable catalog with Anthropic
start, fragment, terminal and expected tool records. Initial `tool_use.input: {}`
does not start timing; the first nonempty fragment does. Successful zero-argument
calls without fragments retain duration and omit both first-token fields.
`FirstTokenAnthropicTests.initialObjectWaitsForFragment` derives its wire frames and expected tool identity/arguments from
these same records. The tests exercise ordinary and opted-in recovery public APIs.
The network-only packaged consumer was removed; no current paired external
verification is claimed.
The original generic delta cases and reference identities remain unchanged.
