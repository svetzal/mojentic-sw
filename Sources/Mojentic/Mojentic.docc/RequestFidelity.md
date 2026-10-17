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
capability pattern matching does not infer limits. The documented Sonnet 4.5
and Haiku 4.5 limits are 64000, and Opus 4.7 is 128000. Extended thinking keeps
its existing budget calculation, `max(1024, resolvedOutputLimit / 4)`.

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
