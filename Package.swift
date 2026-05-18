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
    ],
    swiftLanguageModes: [.v6]
)
