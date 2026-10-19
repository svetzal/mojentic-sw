# Model metadata and first-token timing, October 2026

Status: agreed on 2026-10-15 (see Decisions). Ships in 3.0.0 in all six ports.

The contract every port implements for three changes:

1. Ask the provider how large a model's context window is.
2. Report time to first token, and what that token was, for every streamed
   completion.
3. Request fidelity: send only the parameters the caller set. Today the
   gateways send library defaults that override the provider's and the
   operator's configuration (issue `svetzal/mojentic-unify#1`).

Elixir implements it first and is the reference where this document is silent.
The other ports follow in the same release, so the same version means the
same features everywhere. The latest coordinated release is 2.1.0. Section 3
changes public types in several ports, so the whole contract ships in 3.0.0.

Sections 1 and 2 are primitives in the sense of
`ADAPTIVE-HARNESS-ENHANCEMENTS.md`: Mojentic reports what the provider says
and what the stream did. What an application does with a window size or a
latency (budgets, pressure bands, ejection, retries) stays policy and stays in
the application.

## Origin and evidence

Microgentic, the small-model coding agent built on `mojentic-ru`, needed both
for its context residency work. It built them as two local modules shaped like
gateway methods, so that they can be deleted once Mojentic provides them:

- `src/model_metadata.rs`: the provider query for a model's context window.
- `src/first_token.rs`: the clock around a stream.

Microgentic commit `746bebe` (2026-10-15) has both, with unit tests and a live
check recorded in its `RESIDENCY-MEASUREMENT-2026-10.md`. The behaviour below
is what the servers did on that date, not what their documentation says:

- oMLX: `fixtures/omlx/models.json` (captured 2026-09-29) already carries
  `max_model_len`. A capture on 2026-10-15 from the same server returned
  `max_model_len: 262144` for `Qwen3.8-27B-MLX-8bit` and `Qwen3.8-27B-oQ4e-mtp`.
- Ollama 0.40.5: `fixtures/ollama/` (captured 2026-10-15) has `/api/show`
  responses for a model without a `num_ctx` parameter, a model with one, and
  an unknown model.

## 1. Context window from the provider

### Interface

Add one gateway operation that returns the context window a provider
advertises for a model, without changing anything about later requests.

| Port | Name |
| ---- | ---- |
| Elixir | optional callback `get_model_context_window(model)` on `Mojentic.LLM.Gateway` |
| Python | `get_model_context_window(model)` |
| Rust | `async fn get_model_context_window(&self, model: &str)` on the gateway trait |
| TypeScript | `getModelContextWindow(model)` |
| Swift, Kotlin | `modelContextWindow(model:)`, `modelContextWindow(model)` |

The result has three shapes:

- **A window:** `max_context_tokens` (a positive integer) and `field`, the
  provider field it came from, for example `"max_model_len"` or
  `"model_info.qwen3_5.context_length"`. Ollama results may also carry
  `model_num_ctx` (see below). The name `max_context_tokens` matches
  the existing OpenAI model registry.
- **Not advertised:** the provider answered but gives no window for this model
  (Elixir `{:ok, nil}`, Rust `Ok(None)`, and so on).
- **An error:** the provider could not be asked, answered with a non-2xx
  status, or answered with a malformed body. Use the port's existing error
  idiom.

A gateway that has no way to know returns "not advertised". It does not guess.
In Elixir the callback is optional; a gateway that does not implement it is
treated as returning `{:ok, nil}`.

### Per provider

**oMLX.** `GET /v1/models`, with the gateway's configured host and API key.
Find the entry whose `id` equals the model. Its `max_model_len` is the window,
with `field` `"max_model_len"`. No entry, or an entry without the field, is "not
advertised". A field that is not a positive integer is an error.

**Ollama.** `POST /api/show` with `{"model": model}`. Read
`model_info.<arch>.context_length`, matching any key that ends in
`.context_length`, because the architecture prefix varies (`qwen3_5`,
`qwen4_exp` in the fixtures). `field` is `"model_info."` plus the matched key.
A missing `model_info`, or no matching key, is "not advertised". A value that
is not a positive integer is an error. HTTP 404 (unknown model) is an error.

The `parameters` text can also hold a `num_ctx` line
(`show_num_ctx_parameter.json`). That is the size the model runs at when a
request sends no `num_ctx`, which section 3 makes the default. The Ollama
result therefore also carries `model_num_ctx` when the line is present, for the
helper below. It is not the window: `max_context_tokens` stays the
`context_length`.

**OpenAI.** Return the model registry's `max_context_tokens` with `field`
`"registry"`, without a request. A model the registry does not know is "not
advertised".

**Other gateways.** Return "not advertised" until a provider capture shows
where the value lives.

### The window a request runs at (Ollama)

The advertised window is not always the window a request runs at. Ollama runs
a request at the `num_ctx` it receives. In v2.1.0 every Mojentic Ollama request
sends one (section 3 changes that). In microgentic's live check, Ollama
advertised 262,144 while every request ran at 32,768. An application that
accounted against the advertised figure understated context pressure
eightfold.

So the Ollama gateway also exposes a pure helper with no request:

- `effective_context_window(window_result, config)` returns
  `min(max_context_tokens, config.num_ctx)` when the config sets `num_ctx`.
  Otherwise it returns `min(max_context_tokens, model_num_ctx)` when the model
  has a `num_ctx` parameter, and `max_context_tokens` when it has none. When
  nothing is known it returns nothing.

In the last case Ollama uses the server's `OLLAMA_CONTEXT_LENGTH`, then its
built-in default. The client cannot see the server setting, so the helper
returns the advertised window as an upper bound. Applications that need the
exact figure can read `context_length` for the loaded model from
`GET /api/ps` after the first request.

Other gateways' requests do not set a context size, so their effective window
is the advertised one. Ports may expose the helper on every gateway with that
behaviour, so applications call it without a provider check.

## 2. First-token timing in stream metrics

This amends section 4 of `ADAPTIVE-HARNESS-ENHANCEMENTS.md`, "Provider stream
progress and metrics". Provider-reported durations (Ollama's
`prompt_eval_duration` and the others listed there) stay as they are. The
fields below are measured by the client, so they exist for every provider,
including ones that report no timing at all.

For every streamed completion, the terminal evidence carries:

| Field | Meaning |
| ----- | ------- |
| `time_to_first_token_ms` | Milliseconds from sending the request to the first streamed token of any kind. Absent or null when the stream produced no token. |
| `first_token_kind` | `content`, `thinking`, or `tool_call`: the kind of that first token. Absent or null with the field above. |
| `request_duration_ms` | Milliseconds from sending the request to the terminal event, on success and on failure. |

In Elixir these go in the `metadata` of `{:completed, evidence}`, and in the
error evidence where a stream ends with an error after tokens arrived. Other
ports put them wherever their terminal stream event or response metadata
already carries provider metrics.

Some providers report their own timing as well. oMLX's `usage` block carries
`time_to_first_token`, `prompt_eval_duration`, `generation_duration` and
`total_time` in seconds (`fixtures/omlx/chat_no_max_tokens.json`). Preserve
those with the other provider metrics; the client-measured fields above are
still reported, because they include network and queueing time and exist for
every provider.

Rules:

- **The clock starts when the request is sent**, not when the stream is
  constructed. Use a monotonic clock.
- **Only the first token counts.** Keep-alive frames (oMLX's first frame with
  `model: "keepalive"`) and frames with no content, thinking, or tool-call delta
  are not tokens.
- **Thinking counts.** A reasoning model's first token is usually thinking; the
  live check saw thinking first in every trial. Applications that want time to
  visible output can measure it themselves from the content events.
- **Tool-call arguments count** from the first argument fragment, not from the
  completed call.
- **Non-streamed completions** may report `request_duration_ms` alone.
- **One frame, several kinds.** When the first token-bearing frame carries
  more than one kind, the kind is chosen in this order: `thinking`, then
  `content`, then `tool_call`. The order of fields inside the frame does not
  matter.
- **Retries stay on one clock.** `time_to_first_token_ms` and
  `request_duration_ms` are measured from the first dispatch of one logical
  completion. The clock keeps running through every admitted retry of that
  completion; it does not restart for each wire attempt.
- **Each tool continuation is a new completion.** The request that sends tool
  results back starts a fresh clock.

Stacey decided these three rules on 2026-10-17 for the Mojentic 3.0.0
initiative. They match the TypeScript port and the measurement microgentic
already makes, so microgentic's benchmarks stay continuous. The TypeScript
executable set `ts-stream-first-token-v1` is the reference for this section.

Observed in microgentic's live check, for scale: oMLX `Qwen3.8-27B-oQ4e-mtp`
took 8.9 to 14.3 seconds to its first (thinking) token; Ollama
`qwen3.8:27b-mlx` took 80 to 108 ms on a warm model. Four trials are not a
measurement; they show the field is worth having.

## 3. Request fidelity: send only what the caller set

Tracked as `svetzal/mojentic-unify#1`.

### The rule

A gateway sends a request parameter only when the caller set it. An unset
field is left out, so the provider applies its own precedence (for Ollama: the
model's parameters, then the server's settings, then Ollama's built-in
defaults). A gateway never invents a value.

The one exception is a parameter the provider's API requires. There the gateway
uses a fallback that is documented and identical in every port (section 3.4).

### 3.1 What the gateways do today (v2.1.0)

An audit of every chat gateway in every port on 2026-10-15 found three
`CompletionConfig` defaults sent as if the caller had chosen them:

| Field (default) | Ollama | OpenAI | oMLX | Anthropic (Python, Swift, Kotlin) |
| --- | --- | --- | --- | --- |
| `num_ctx` (32,768) | sent in five ports, overriding the model's `num_ctx` and the server's `OLLAMA_CONTEXT_LENGTH`; TypeScript sends it only when set | never sent | never sent | not used |
| `max_tokens` (16,384) | sent as `num_predict`, overriding the model's setting and Ollama's unlimited default, which silently caps long reasoning output | sent; becomes `max_completion_tokens` for reasoning models, where it also counts hidden reasoning tokens, so high effort can end at `length` | always sent (`OMLX-2026-09.md` requires it) | always sent; the API requires it |
| `temperature` (1.0) | sent, overriding a model's tuned temperature | sent; equals the provider default, and the model registries keep it valid | sent | sent |

The other optional fields (`top_p`, `top_k`, `response_format`, reasoning
effort) already follow "send only when set" almost everywhere. Client-side
fields (`max_tool_iterations`, recovery settings, Rust's `reasoning_profile`)
never reach a provider.

Evidence for `num_ctx`, 2026-10-15: the Ollama server on Stacey's Mac runs with
`OLLAMA_CONTEXT_LENGTH=131072`, and `qwen3.8-flash-next:125b-mlx` has a
`num_ctx 262144` parameter (`fixtures/ollama/show_num_ctx_parameter.json`).
Every request from microgentic (`mojentic-ru`) carried `num_ctx: 32768`.

The ports also disagree in shape:

- **`max_tokens` against `num_predict` on Ollama** follows four rules. Elixir,
  Rust and Kotlin let a positive `num_predict` win; Python lets `max_tokens`
  overwrite it; TypeScript sends `numPredict` even when it is -1; Swift has no
  `num_predict`.
- **Fixed-temperature OpenAI models.** Elixir, Python, Rust and TypeScript
  rewrite the temperature to 1.0; Swift omits it when the registry lists one
  value or none; Kotlin omits it for every reasoning model.
- **Reasoning effort on a non-reasoning OpenAI model.** Elixir, Python, Rust and
  TypeScript warn and drop it; Swift and Kotlin drop it silently.
- **Ollama `think`.** Rust sends level strings (including `"xhigh"`); every other
  port sends `true`.
- **Field coverage.** `top_p` is missing in Python and Kotlin; `top_k` in
  Python, Swift and Kotlin. TypeScript's OpenAI gateway never sends `topP`, and
  TypeScript's `frequencyPenalty` and `presencePenalty` are never read.
- **Defaults.** Swift's `max_tool_iterations` defaults to 25; every other port
  uses 10. Python and Kotlin use -1 as the `num_predict` sentinel where the
  others use an optional.

### 3.2 Changes

1. **`temperature`, `num_ctx` and `max_tokens` become optional with no default**
   in every port's `CompletionConfig`. Every gateway sends each one only when
   set, except where section 3.4 applies.
2. **One output limit.** `num_predict` is removed as a separate field.
   `max_tokens` is the only output limit: Ollama receives it as
   `options.num_predict`, OpenAI as `max_tokens` or `max_completion_tokens`,
   oMLX and Anthropic as `max_tokens`. This replaces the four precedence rules.
   Python's and Kotlin's -1 sentinel goes with it.
3. **Remove gateway-level fallbacks** that invent values: Python's
   `args.get("num_ctx", 32768)` and the deprecated broker keyword defaults, and
   TypeScript's `?? 1.0` and `?? 16384` in the OpenAI and oMLX gateways.
   Python's `ChatSession` stops passing its `max_context` as `num_ctx` unless
   the caller set one.
4. **Align the shape differences above**, taking Elixir's behaviour as the
   reference: warn when reasoning effort is dropped, and rewrite a fixed
   temperature to the model's only allowed value when the caller set one.
   Reasoning effort values and their provider mapping (including Ollama
   `think` booleans and level strings) follow `REASONING-PROTOTYPE-2026-10.md`,
   which 3.0.0 takes to every port.

### 3.3 What this breaks

| Port | Change |
| ---- | ------ |
| Elixir | Typespecs and `defstruct` defaults. Not a compile break, but every comparison with these fields needs a nil check: in Erlang term order `nil > 0` is true, and `abs(t - temperature)` in the OpenAI registry raises on nil. |
| Python | Type hints only; `None` becomes valid. Comparisons such as `num_predict > 0` raise `TypeError` on `None` and must be guarded. |
| Rust | Breaking: `temperature: f32`, `num_ctx: usize` and `max_tokens: usize` become `Option`. Struct literals and field reads stop compiling. Removing `num_predict` is also breaking. |
| TypeScript | The fields are already optional. Only the gateway fallbacks go. |
| Swift | `numCtx` is already `Int?`; only its default changes. `temperature: Double` and `maxTokens: Int` become optional, which is source-breaking. |
| Kotlin | Binary-breaking: the fields become nullable in the constructors, getters, `componentN` and `copy`, and the API dump changes. The `DEFAULT_*` constants lose their meaning. |

With major versions synchronised, this is 3.0.0 in all six ports.

### 3.4 Required parameters

**Anthropic `max_tokens`.** The API requires it. When the caller did not set
it, the gateway sends the model's maximum output from the model registry, and
4,096 for a model the registry does not know. Today the three ports disagree
(Python 2,000 on one path, Swift `max(1, …)`, Kotlin 4,096). Swift derives its
thinking budget from `max_tokens`; with an unset value it uses the same
fallback.

**oMLX `max_tokens`.** Not required. On 2026-10-15 a request with no
`max_tokens` (`Qwen3.8-27B-MLX-8bit`, `enable_thinking: false`, asked for 1,500
numbered lines) generated 6,392 tokens and ended with `finish_reason: stop`
(`fixtures/omlx/chat_no_max_tokens.json`). The server has no small default, so
oMLX follows the main rule: send `max_tokens` only when set. `OMLX-2026-09.md`
section 2 ("always, from the config") changes accordingly in 3.0.0. The capture
shows only that any server limit is above 6,392 tokens.

### 3.5 What callers notice

- Ollama requests carry no `num_ctx`, `num_predict` or `temperature` by
  default, so models run with their own and the server's settings. A caller who
  relied on the old defaults, against a server and model with no settings of
  their own, gets Ollama's built-in defaults instead: possibly a smaller
  context, and no output limit, so a model stuck in a loop runs longer. The
  CHANGELOG says so and shows how to set each field.
- OpenAI requests carry no `max_tokens` by default, so output is limited only
  by the model. That removes the reasoning truncation and can cost more.
- Code that reads these fields as plain numbers stops compiling in Rust, Swift
  and Kotlin.

### 3.6 Tests per port

- A default `CompletionConfig` sends no `num_ctx`, `num_predict`, `max_tokens`
  or `temperature` to Ollama, and no `max_tokens` or `temperature` to OpenAI.
- Each field, when set, is sent exactly once under the provider's name.
- Anthropic sends the documented fallback when `max_tokens` is unset; oMLX
  sends none.
- The shape rules in 3.2 item 4, with one test each.

## 4. Acceptance criteria, per port

- **Context window:** tests from the fixtures for an oMLX window, an oMLX model
  missing from the list, an oMLX entry without the field, a non-numeric value,
  an Ollama window under each architecture prefix, an Ollama answer with no
  `model_info`, an Ollama 404, and the OpenAI registry path.
- **No side effects:** a test shows that asking for the window leaves the next
  completion request byte-identical to one made without asking.
- **Effective window:** tests for Ollama with the advertised window above,
  below, and equal to `config.num_ctx`; with no `config.num_ctx` and a model
  `num_ctx` parameter; with neither; and with nothing advertised.
- **Request fidelity:** the tests in section 3.6.
- **First-token timing:** tests for content-first, thinking-first, and
  tool-call-first streams, a keep-alive frame before the first token, an empty
  stream, and a stream that fails after its first token. Use an injectable or
  fake clock rather than sleeps.
- **Docs:** a section for each capability in the port's gateway or streaming
  guide.
- **Records:** CHANGELOG `Unreleased` entries for each capability, and a
  `PARITY.md` row for each.
- **Commits:** on `main`, pushed, one commit per capability preferred, and no
  commit that touches more than one port.

## 5. After it ships

Microgentic moves its pinned `mojentic-ru` revision to the release, switches to
these operations, and deletes `src/model_metadata.rs` and `src/first_token.rs`
in a commit of its own. Its fallback order, accounting, and tracing stay where
they are.

## Decisions

Stacey decided the open questions on 2026-10-15:

1. **The window call is single-purpose:** `get_model_context_window` (named
   per port as in section 1). It is not the first field of a broader model-info
   call; the reasoning work keeps its own model profiles.
2. **One output limit:** `num_predict` is removed and `max_tokens` is the only
   output limit (section 3.2, item 2).
3. **Scope:** sections 1, 2 and 3 ship together in 3.0.0, in all six ports,
   Elixir first. The patch-level bugs found in the audit (#2, #3, #4) ship
   separately in 2.1.x and do not wait.
