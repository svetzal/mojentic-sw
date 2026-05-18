// swift-tools-version: 6.1
// Mojentic — Swift port of the Mojentic LLM integration framework.
// See SWIFT.md in the mojentic-unify monorepo for the full plan and rationale.

import PackageDescription

let package = Package(
    name: "Mojentic",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "Mojentic", targets: ["Mojentic"]),
        .executable(name: "SimpleLLM", targets: ["SimpleLLM"]),
        .executable(name: "ListModels", targets: ["ListModels"]),
        .executable(name: "SimpleStructured", targets: ["SimpleStructured"]),
        .executable(name: "SimpleTool", targets: ["SimpleTool"]),
        .executable(name: "Streaming", targets: ["Streaming"]),
        .executable(name: "BrokerExamples", targets: ["BrokerExamples"]),
        .executable(name: "ChatSessionExample", targets: ["ChatSessionExample"]),
        .executable(name: "ChatSessionWithTool", targets: ["ChatSessionWithTool"]),
        .executable(name: "ImageAnalysis", targets: ["ImageAnalysis"]),
        .executable(name: "Embeddings", targets: ["Embeddings"]),
        .executable(name: "FileTool", targets: ["FileTool"]),
        .executable(name: "CodingFileTool", targets: ["CodingFileTool"]),
        .executable(name: "BrokerAsTool", targets: ["BrokerAsTool"]),
        .executable(
            name: "EphemeralTaskManagerExample",
            targets: ["EphemeralTaskManagerExample"]
        ),
        .executable(name: "TellUser", targets: ["TellUser"]),
        .executable(name: "AskUser", targets: ["AskUser"]),
        .executable(name: "WebSearch", targets: ["WebSearch"]),
        .executable(name: "TracerDemo", targets: ["TracerDemo"]),
        .executable(name: "AsyncLLM", targets: ["AsyncLLM"]),
        .executable(
            name: "AsyncDispatcherExample",
            targets: ["AsyncDispatcherExample"]
        ),
        .executable(name: "IterativeSolver", targets: ["IterativeSolver"]),
        .executable(name: "RecursiveAgent", targets: ["RecursiveAgent"]),
        .executable(name: "SolverChatSession", targets: ["SolverChatSession"]),
        .executable(name: "ReAct", targets: ["ReAct"]),
        .executable(name: "WorkingMemory", targets: ["WorkingMemory"]),
        .executable(name: "RealtimeBasic", targets: ["RealtimeBasic"]),
        .executable(name: "RealtimeManualVAD", targets: ["RealtimeManualVAD"]),
        .executable(name: "RealtimeBargeIn", targets: ["RealtimeBargeIn"]),
        .executable(name: "RealtimeToolCall", targets: ["RealtimeToolCall"]),
    ],
    traits: [
        .default(enabledTraits: ["ollama"]),
        "ollama",
        "openai",
        "anthropic",
        .trait(
            name: "full",
            enabledTraits: ["ollama", "openai", "anthropic"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "Mojentic",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "MojenticTests",
            dependencies: ["Mojentic"]
        ),
        .executableTarget(
            name: "SimpleLLM",
            dependencies: ["Mojentic"],
            path: "Examples/SimpleLLM"
        ),
        .executableTarget(
            name: "ListModels",
            dependencies: ["Mojentic"],
            path: "Examples/ListModels"
        ),
        .executableTarget(
            name: "SimpleStructured",
            dependencies: ["Mojentic"],
            path: "Examples/SimpleStructured"
        ),
        .executableTarget(
            name: "SimpleTool",
            dependencies: ["Mojentic"],
            path: "Examples/SimpleTool"
        ),
        .executableTarget(
            name: "Streaming",
            dependencies: ["Mojentic"],
            path: "Examples/Streaming"
        ),
        .executableTarget(
            name: "BrokerExamples",
            dependencies: ["Mojentic"],
            path: "Examples/BrokerExamples"
        ),
        .executableTarget(
            name: "ChatSessionExample",
            dependencies: ["Mojentic"],
            path: "Examples/ChatSessionExample"
        ),
        .executableTarget(
            name: "ChatSessionWithTool",
            dependencies: ["Mojentic"],
            path: "Examples/ChatSessionWithTool"
        ),
        .executableTarget(
            name: "ImageAnalysis",
            dependencies: ["Mojentic"],
            path: "Examples/ImageAnalysis"
        ),
        .executableTarget(
            name: "Embeddings",
            dependencies: ["Mojentic"],
            path: "Examples/Embeddings"
        ),
        .executableTarget(
            name: "FileTool",
            dependencies: ["Mojentic"],
            path: "Examples/FileTool"
        ),
        .executableTarget(
            name: "CodingFileTool",
            dependencies: ["Mojentic"],
            path: "Examples/CodingFileTool"
        ),
        .executableTarget(
            name: "BrokerAsTool",
            dependencies: ["Mojentic"],
            path: "Examples/BrokerAsTool"
        ),
        .executableTarget(
            name: "EphemeralTaskManagerExample",
            dependencies: ["Mojentic"],
            path: "Examples/EphemeralTaskManagerExample"
        ),
        .executableTarget(
            name: "TellUser",
            dependencies: ["Mojentic"],
            path: "Examples/TellUser"
        ),
        .executableTarget(
            name: "AskUser",
            dependencies: ["Mojentic"],
            path: "Examples/AskUser"
        ),
        .executableTarget(
            name: "WebSearch",
            dependencies: ["Mojentic"],
            path: "Examples/WebSearch"
        ),
        .executableTarget(
            name: "TracerDemo",
            dependencies: ["Mojentic"],
            path: "Examples/TracerDemo"
        ),
        .executableTarget(
            name: "AsyncLLM",
            dependencies: ["Mojentic"],
            path: "Examples/AsyncLLM"
        ),
        .executableTarget(
            name: "AsyncDispatcherExample",
            dependencies: ["Mojentic"],
            path: "Examples/AsyncDispatcher"
        ),
        .executableTarget(
            name: "IterativeSolver",
            dependencies: ["Mojentic"],
            path: "Examples/IterativeSolver"
        ),
        .executableTarget(
            name: "RecursiveAgent",
            dependencies: ["Mojentic"],
            path: "Examples/RecursiveAgent"
        ),
        .executableTarget(
            name: "SolverChatSession",
            dependencies: ["Mojentic"],
            path: "Examples/SolverChatSession"
        ),
        .executableTarget(
            name: "ReAct",
            dependencies: ["Mojentic"],
            path: "Examples/ReAct"
        ),
        .executableTarget(
            name: "WorkingMemory",
            dependencies: ["Mojentic"],
            path: "Examples/WorkingMemory"
        ),
        .executableTarget(
            name: "RealtimeBasic",
            dependencies: ["Mojentic"],
            path: "Examples/RealtimeBasic"
        ),
        .executableTarget(
            name: "RealtimeManualVAD",
            dependencies: ["Mojentic"],
            path: "Examples/RealtimeManualVAD"
        ),
        .executableTarget(
            name: "RealtimeBargeIn",
            dependencies: ["Mojentic"],
            path: "Examples/RealtimeBargeIn"
        ),
        .executableTarget(
            name: "RealtimeToolCall",
            dependencies: ["Mojentic"],
            path: "Examples/RealtimeToolCall"
        ),
    ],
    swiftLanguageModes: [.v6]
)
