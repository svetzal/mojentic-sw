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
    targets: [
        .target(
            name: "Mojentic",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "MojenticTests",
            dependencies: ["Mojentic"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
