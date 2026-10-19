# Sending only caller-selected parameters

Leave optional request fields unset to preserve the provider's configuration.

``CompletionConfig/temperature``, ``CompletionConfig/maxTokens`` and
``CompletionConfig/numCtx`` default to `nil`. Gateways omit unset values.
Ollama then applies model parameters, server settings and built-in defaults.
OpenAI and oMLX use their own output limits; without an explicit limit an OpenAI
request may generate more tokens and cost more.

To reproduce the earlier defaults:

```swift
let config = CompletionConfig(temperature: 1.0, maxTokens: 16384, numCtx: 32768)
```

`maxTokens` is the only output limit. Ollama maps it to `options.num_predict`;
OpenAI uses the registry's `max_tokens` or `max_completion_tokens` name; oMLX
and Anthropic use `max_tokens`. A caller-set zero is still an explicit value,
including for temperature. Providers validate supplied values.

Anthropic requires an output limit. When unset, it uses
``AnthropicModelRegistry/maxOutputTokens(for:)`` or 4096 when output metadata
is unknown. Output metadata uses exact registered identifiers and aliases;
capability pattern matching does not infer limits. Extended thinking keeps
its existing budget calculation, `max(1024, resolvedOutputLimit / 4)`.

The exact output metadata covers the complete registered set:

| Registered IDs and supported exact aliases | Maximum output tokens |
| --- | --- |
| `claude-3-haiku-20240307` | 4096 |
| `claude-3-opus-20240229`, `claude-3-opus-latest` | 4096 |
| `claude-3-5-haiku-20241022`, `claude-3-5-haiku-latest` | 8192 |
| `claude-3-5-sonnet-20240620`, `claude-3-5-sonnet-20241022`, `claude-3-5-sonnet-latest` | 8192 |
| `claude-3-7-sonnet-latest`, `claude-3-7-sonnet-20250219` | 64000 |
| `claude-sonnet-4-5`, `claude-sonnet-4-5-20250929` | 64000 |
| `claude-haiku-4-5`, `claude-haiku-4-5-20251001` | 64000 |
| `claude-opus-4-7` | 128000 |

These are the standard API output limits from Anthropic's
[model comparison](https://docs.anthropic.com/en/docs/about-claude/models/all-models)
and the [Sonnet 4.5](https://platform.claude.com/docs/en/models/sonnet-4-5/overview),
[Haiku 4.5](https://platform.claude.com/docs/en/models/haiku-4-5/overview) and
[Opus 4.7](https://platform.claude.com/docs/en/models/opus-4-7/overview) specifications.
The comparison URL now redirects to the current model overview; these legacy
entries preserve their documented limits rather than following replacement models.
No beta output-limit opt-in is inferred. Discovery listings and reasoning
capabilities are unchanged. A name such as `claude-3-7-sonnet-unregistered`
therefore still uses 4096, even though the existing capability rules allow thinking.

`request-fidelity-v1` revision `registered-output-limits-2026-10-17` exercises
these exact names through public gateways with an in-process HTTP boundary.
`scripts/verify-request-fidelity-contract` verifies the fixture and executable
manifest, then runs the named default and explicit cases. There is no detached
package-consumer verification claim.
The warning assertions observe the actual swift-log diagnostic, including its
level and model name, alongside omission of `reasoning_effort`.

OpenAI rewrites a caller-set temperature to the model's only allowed value.
If the registry declares no accepted temperatures, it omits the parameter.
Unset temperature stays omitted in both cases. A supplied reasoning effort on
a model without effort support is dropped with a warning. Native reasoning
booleans, named levels, profiles and history retain their documented behavior.

ChatSession passes the explicit output limit to its context manager as a
reservation, or zero when unset. It never replaces an omitted output limit or
context size with a gateway default. Legacy Codable records containing numeric
values preserve them; absent or null request fields decode as unset.

Discovery does not mutate completion configuration. Production HTTP requests
encode object keys in stable order, so an identical completion before and after
discovery has the same complete HTTP body bytes. See <doc:ModelContextWindows>.
