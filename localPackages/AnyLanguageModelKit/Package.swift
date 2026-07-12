// swift-tools-version: 6.1

import PackageDescription

// Shim package: Xcode has no UI for declaring package traits, so this local
// package pins AnyLanguageModel with only the MLX trait enabled (no CoreML,
// no Llama) and re-exports it. See https://github.com/huggingface/AnyLanguageModel#using-traits-in-xcode-projects.
let package = Package(
    name: "AnyLanguageModelKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "AnyLanguageModelKit", targets: ["AnyLanguageModelKit"])
    ],
    dependencies: [
        // AnyLanguageModel's MLX trait pulls these in conditionally, but SwiftPM's
        // trait resolution has a known bug (see the "Package Traits" section of
        // https://github.com/huggingface/AnyLanguageModel#installation) that fails
        // to resolve conditional trait dependencies unless they're also declared
        // directly here, at versions AnyLanguageModel's own manifest accepts.
        .package(
            url: "https://github.com/huggingface/AnyLanguageModel",
            from: "0.9.0",
            traits: ["MLX"]
        ),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.0.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.0.0"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
    ],
    targets: [
        .target(
            name: "AnyLanguageModelKit",
            dependencies: [
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel")
            ],
            path: "Sources/AnyLanguageModelKit"
        )
    ]
)
