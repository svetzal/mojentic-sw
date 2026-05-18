#  Example — File Tools

Reference implementation of sandbox-rooted filesystem access for LLM
tool calls.

## Overview

> Important: The file tools shipped with Mojentic are **reference
> implementations, not a core library feature**. Use them directly when
> they fit your sandboxing model, or read them as a template for building
> your own tools.

The `FileTools` cluster pairs a single ``FilesystemGateway`` (a
sandbox-rooted wrapper around `FileManager`) with eight ``LLMTool``
implementations: list, recursive list, read, write, delete, move,
create-directory, and exists. Every path supplied by the LLM resolves
relative to the sandbox root, and any path that escapes the root
(through `..` traversal or an absolute path) is rejected with
``MojenticError/invalidArgument(message:)``.

## Wiring up

```swift
import Mojentic

let root = URL(fileURLWithPath: "/tmp/agent-workspace")
let fs = FilesystemGateway(rootURL: root)
let tools = FileTools.bundle(for: fs)
let broker = LLMBroker(gateway: OpenAIGateway(apiKey: key))
let response = try await broker.complete(
    model: "gpt-4o-mini",
    messages: [
        .system("Use the file tools to inspect the project."),
        .user("Read the README.md and summarise it."),
    ],
    tools: tools
)
```

`FileTools.bundle(for:)` returns the full eight-tool set bound to one
gateway instance. Pick a smaller subset if the model only needs read
access:

```swift
let tools: [any LLMTool] = [
    ListFilesTool(fs: fs),
    ReadFileTool(fs: fs),
]
```

## Customising / extending

To author your own filesystem tool, conform to ``LLMTool`` and reuse the
``FilesystemGateway`` for path resolution:

```swift
struct CopyFileTool: LLMTool {
    let fs: FilesystemGateway

    var descriptor: ToolDescriptor {
        ToolDescriptor(
            name: "copy_file",
            description: "Copy a file from one sandbox path to another.",
            parameters: [
                "type": "object",
                "properties": [
                    "from": ["type": "string"],
                    "to": ["type": "string"],
                ],
                "required": ["from", "to"],
                "additionalProperties": false,
            ]
        )
    }

    func execute(arguments: JSONValue) async throws -> JSONValue {
        let from = try fs.resolve(arguments.objectValue?["from"]?.stringValue ?? "")
        let to = try fs.resolve(arguments.objectValue?["to"]?.stringValue ?? "")
        try FileManager.default.copyItem(at: from, to: to)
        return ["copied": .bool(true)]
    }
}
```

The gateway's `resolve(_:)` enforces the sandbox before you ever touch
the underlying filesystem.

## See Also

- ``FilesystemGateway``
- ``ListFilesTool``
- ``ReadFileTool``
- ``WriteFileTool``
- ``FileTools``
