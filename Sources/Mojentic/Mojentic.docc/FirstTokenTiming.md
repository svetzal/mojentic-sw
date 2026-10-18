# First-token timing

Measure the first observed token and terminal duration from the actual HTTP dispatch.

Every built-in streaming completion reports client measurements in
``CompletionEvidence/metadata``. The measurements use a monotonic clock and
milliseconds; provider durations keep their original units and values.

| Metadata key | Meaning |
| --- | --- |
| `time_to_first_token_ms` | First dispatch to the first nonempty token observation; absent without a token. |
| `first_token_kind` | `thinking`, `content`, or `tool_call`; absent without a token. |
| `request_duration_ms` | First dispatch to terminal success or failure. |

A frame with several kinds uses thinking, then content, then tool-call arguments.
Thinking counts even when the selected API suppresses reasoning delivery. A tool
name or empty argument string does not count; the first argument fragment does.
Empty frames, SSE comments, oMLX keepalives, and Anthropic signature deltas do not
count. A provider terminal error ends token observation; trailing frames cannot
backfill first-token fields. Measurements observe received frames before tool
assembly and caller-owned capture. They do not infer token counts or time to visible output.

An admitted retry retains the first dispatch origin, including admission and
backoff time. Sending tool results starts a new completion with a fresh origin.
Request encoding and capture before the first dispatch are excluded. Constructing
an asynchronous stream may launch its producer immediately; construction and the
caller's first iteration are not timing origins.

## Reading terminal evidence

Single-turn `completeStreamEvents` and broker `generateStreamEvents` put timing in
`.completed(evidence)`. Their recovering counterparts do the same. Throwing
`stream` and `streamRecovering` gateways include evidence as the third associated
value of `.done(finishReason:usage:evidence:)`:

```swift
for try await event in gateway.stream(
    model: model, messages: messages, tools: nil, config: CompletionConfig()
) {
    if case .done(_, _, let evidence) = event {
        print(evidence?.metadata?["first_token_kind"] as Any)
    }
}
```

Broker and session streams emit `.metrics(evidence)` once for each completed
provider turn, including turns that request tools. Their final `.done(response)`
also exposes the final completion's metadata through ``LLMResponse/metadata``.
Provider frame metrics in recovery streams keep their existing identity, frame
index, order, and values; client measurements appear in terminal evidence.

## Failure and cancellation

Both throwing streams and single-turn error events use `MojenticError.streamFailure`.
Its ``StreamFailure`` payload retains the original typed ``StreamFailure/cause``
and terminal ``StreamFailure/evidence``. ``RecoveryError`` keeps its existing
failure, outcome, history, and type, adding ``RecoveryError/evidence``. A stream
that fails before receiving tokens reports duration without first-token fields.
A request rejected before dispatch has no client timing origin.

Cancellation preserves observed timing when a terminal failure is delivered.
Swift `AsyncStream` cancellation can end iteration before a terminal event is
consumed. Use the existing recovery cancellation scope when ownership must extend
across consumer pauses; it does not promise delivery to an iterator that has
stopped. The configured recovery `reportObserver` also receives terminal timing
in ``CompletionRecoveryReport/evidence``, including cancellation after iteration
stops. As with other failures, partial content is evidence, not an answer.

## Supported routes and migration

Ollama, OpenAI, and oMLX support legacy and recovering tool-capable and single-turn
streams. Anthropic supports legacy tool-capable streams, recovering tool-capable
streams, and recovering single-turn streams when recovery is configured. Its
legacy single-turn API remains unsupported and sends no request.

Custom gateways can omit terminal evidence. Existing `.done` constructions still
compile because the new evidence argument defaults to `nil`; update pattern
matches to `.done(let reason, let usage, let evidence)`. Exhaustive broker/session
switches must handle `.metrics`, and exhaustive `MojenticError` switches must
handle `.streamFailure`. Inspect its original cause when matching preexisting
error cases. Older Codable `LLMResponse` records decode with absent metadata.

Anthropic's initial `tool_use.input: {}` does not start timing. The first
nonempty `input_json_delta.partial_json` fragment starts `tool_call` timing.
A successful zero-argument call without fragments retains `request_duration_ms`
with both `time_to_first_token_ms` and `first_token_kind` absent.
