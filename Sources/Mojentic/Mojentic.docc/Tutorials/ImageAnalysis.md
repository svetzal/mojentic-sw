#  Image Analysis

Send images alongside text to vision-capable models from either Ollama
(llava) or OpenAI (gpt-4o family).

## Overview

### Why

Multimodal models can describe scenes, extract text, identify objects,
and reason about visual layout. Wiring them up means turning local image
files into the bytes the API expects — Mojentic handles the encoding
and message shape.

### When

Use ``LLMMessage/user(text:images:)`` whenever the prompt should
include image content. The same message shape works against every
vision-capable provider.

### How

#### 1. Load an image

```swift
import Mojentic

let url = URL(fileURLWithPath: "/path/to/photo.jpg")
let image = try ImageContent.loadingFromDisk(at: url)
```

`loadingFromDisk(at:mimeType:)` reads the file, base64-encodes it, and
infers the MIME type from the extension (override via the
`mimeType:` parameter).

For images already served from the web you can pass a URL directly:

```swift
let remote = ImageContent(
    url: URL(string: "https://example.com/photo.jpg")!,
    detail: "high"
)
```

OpenAI fetches the URL itself; Ollama only accepts inline base64
content and skips remote URLs.

#### 2. Send a multimodal turn

```swift
let broker = LLMBroker(gateway: OpenAIGateway(apiKey: key))
let response = try await broker.complete(
    model: "gpt-4o-mini",
    messages: [
        .user(text: "Describe this image in one sentence.", images: [image])
    ]
)
print(response.content)
```

The OpenAI message adapter encodes the image as an `image_url` content
part; the Anthropic adapter encodes it as an `image` content block with
a base64 `source`. The same `ImageContent` flows through both.

#### 3. Run against Ollama

```swift
let broker = LLMBroker(gateway: OllamaGateway())
let response = try await broker.complete(
    model: "llava",
    messages: [
        .user(text: "What do you see?", images: [image])
    ]
)
```

Ollama's adapter forwards inline base64 images via the `images` array
on the user message.

## Known Limitations

- Ollama's chat endpoint accepts only inline base64 image data; remote
  URL images supplied to ``ImageContent`` are silently skipped against
  Ollama. Pre-fetch and encode in your app code if you need URL support
  against Ollama.

## See Also

- ``ImageContent``
- ``LLMMessage``
- ``OllamaGateway``
- ``OpenAIGateway``
