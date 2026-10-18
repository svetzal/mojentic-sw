# Swift streaming timing contract fixtures

The executable set is `swift-stream-first-token-v2-owner-anthropic-input`: the `FirstToken*Tests.swift`
public-API HTTP tests and `scripts/verify-packaged-stream-timing`.

`stream_first_token_v1.json` reuses the static `ex-stream-first-token-v1` case
catalog from mojentic-ex commit `f42c5c8d7e9fa9070fe7d86d6d4874dff07ff3b4`:
https://github.com/svetzal/mojentic-ex/blob/f42c5c8d7e9fa9070fe7d86d6d4874dff07ff3b4/test/contracts/stream_first_token_v1.json

The original catalog SHA-256 is `fddd71c8e0062c489588b2e15df749e934cf9d9412d05b4ee08eb52673425a6c`.
The adjacent manifest verifies the extended local catalog bytes. Swift consumes the named delta
cases through its public APIs and production HTTP transport; the fresh consumer's
provider derives its content and thinking deltas from these same cases.

The binding reference is `ts-stream-first-token-v1`, inspected at TypeScript
commit `b8db5d59c02297e39335ba1deed83fa04e1b8f11`:
https://github.com/svetzal/mojentic-ts/blob/b8db5d59c02297e39335ba1deed83fa04e1b8f11/src/llm/first-token-http.test.ts

Reference SHA-256: `e94d4f53928b3ea519eceedcb0f7e7a41ae2eb5da52076369d92374108b3d2a8`.
The reused catalog also identifies later reference cases; no external library's
executable snapshot or dependent adoption is required for Swift self-validation.

Timing relationships use real monotonic observations, held HTTP prefixes, delayed
capture, admitted retry delays and tool execution. The catalog's illustrative
clock milestones are not substituted for actual HTTP measurements.

The binding owner decision extends this local executable catalog with Anthropic
start, fragment, terminal and expected tool records. Initial `tool_use.input: {}`
does not start timing; the first nonempty fragment does. Successful zero-argument
calls without fragments retain duration and omit both first-token fields.
`FirstTokenAnthropicTests.initialObjectWaitsForFragment` and the fresh packaged
consumer derive their wire frames and expected tool identity/arguments from
these same records. Both exercise legacy and opted-in recovery production HTTP.
The original generic delta cases and reference identities remain unchanged.
