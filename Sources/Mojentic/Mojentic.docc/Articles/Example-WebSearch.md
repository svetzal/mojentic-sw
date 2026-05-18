#  Example — Web Search

Reference implementation of a web search tool backed by Serper.dev.

## Overview

> Important: ``WebSearchTool`` is a **reference implementation, not a
> core library feature**. Mojentic does not include a search engine; it
> ships one wrapper against one third-party API as a template. Swap the
> implementation if your application needs a different provider.

``WebSearchTool`` calls Serper.dev's `/search` endpoint, returning the
top N organic results as a JSON array of `{title, link, snippet}`
objects. The API key is injected at init — library code never reads
environment variables.

## Wiring up

```swift
import Mojentic

let search = WebSearchTool(apiKey: serperKey, maxResults: 5)
let broker = LLMBroker(gateway: OpenAIGateway(apiKey: openAIKey))
let response = try await broker.complete(
    model: "gpt-4o-mini",
    messages: [
        .system("Use web_search when the user asks for recent information."),
        .user("What's new in Swift 6.2?"),
    ],
    tools: [search]
)
```

`maxResults` caps the payload size handed back to the model.

## Customising / extending

Drop-in replacement for a different provider — Brave Search, DuckDuckGo,
Bing, your own indexed corpus — is one new ``LLMTool`` implementation:

```swift
struct BraveSearchTool: LLMTool {
    let apiKey: String

    var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: "web_search",
            description: "Search the web.",
            parameters: [
                "type": "object",
                "properties": ["query": ["type": "string"]],
                "required": ["query"],
                "additionalProperties": false,
            ]
        )
    }

    func execute(arguments: JSONValue) async throws -> JSONValue {
        // Issue the Brave Search request and return the trimmed result list.
        // Use Mojentic's ``HTTPClient`` for the request shape — it surfaces
        // typed errors via ``MojenticError``.
        fatalError("implement")
    }
}
```

Keep the tool name as `web_search` if you want existing prompts and
system instructions to keep working without changes.

## See Also

- ``WebSearchTool``
- ``LLMTool``
- ``HTTPClient``
