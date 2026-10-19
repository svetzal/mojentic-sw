# Native reasoning prototype contract

Status, 2026-10-15: Stacey authorized this contract for every port in 3.0.0
(`RELEASE-3.0.0.md`, part 2). Rust's prototype is the reference.

Stacey explicitly requested a Rust-first prototype on October 6, 2026, validated
in the Sandbox2 Harness using a temporary Git revision. This is an exception to
Elixir-first feature development. It does not authorize a release or changes to
other ports.

## Contract

- Preserve native assistant reasoning separately from visible content and tool
  results. Serialize as thinking for Ollama and reasoning_content for oMLX.
- Expose Disabled, Enabled, Low, Medium, High, and XHigh without conflating them.
  Ollama uses booleans for the first two and exact strings for named levels;
  oMLX uses enable_thinking and reasoning_effort respectively.
- Explicit model profiles validate supported efforts and history capability;
  profiles are selected by the caller, never guessed from a model-name fragment.
- Qwen3.8 supports disabled, low, medium, xhigh and native history. An omitted
  effort remains unknown; no cross-provider default equivalence is implied.
- Broker retention is opt-in. Preserve completed ordinary and streamed tool
  responses, but never fabricate native history from cancellation or error.
- oMLX requests preserve_thinking through chat_template_kwargs when retention is
  enabled. Record the request; forced server settings can override it.
- Structured output uses the same controls as ordinary and streaming requests.
- OpenAI does not accept the oMLX history extension. Unsupported new controls
  fail explicitly; unrelated legacy behavior remains unchanged.

## Validation and remaining work

Rust has model-profile unit tests, mock HTTP control matrices, and ordinary and
streaming broker tool-continuity tests. Harness verifies outer-turn retention,
context accounting, capped-call exclusion, and native transcript display.
No local model or stochastic benchmark was run for these compatibility tests.

Source changes to public Rust structs and enums require callers to migrate.
Finalize API/versioning, coordinate all ports, and measure benchmark efficacy
before treating this as a released cross-language feature. Native retention,
interrupted-call checkpoints, effort, and sampling are separate interventions.
