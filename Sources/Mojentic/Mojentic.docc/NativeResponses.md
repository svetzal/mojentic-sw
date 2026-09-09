# Native responses

## Caller-owned context and native responses

Use `try await broker.generateResponse(model: model, messages: messages, tools: tools)` to receive one native gateway response without
executing tools, extending history or making a follow-up request. Assemble the
complete message array before each call. The broker traces the supplied request
and returned response; it does not read repository guidance or apply a context policy.

The existing convenience completion method still executes tools and follows up.
Choose a serial or parallel runner according to the tools' effects. Parallel
execution does not make dependent edits safe.

Set `CompletionConfig(maxToolIterations: nil)` to disable the tool-round limit.
Existing finite defaults remain unchanged. Concurrency controls simultaneous
work; it is not a task budget or a loop detector.

Unknown tools produce error exchanges in both ordinary and streaming broker calls.

Native responses preserve the fields supplied by the gateway. Missing provider
usage or termination evidence must remain unknown; configured model names and
text length are not substitutes for reported metadata.
