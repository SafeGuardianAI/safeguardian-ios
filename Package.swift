// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SafeGuardian",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "SafeGuardian",
            targets: ["SafeGuardian"]
        ),
    ],
    dependencies: [
        .package(path: "localPackages/Arti"),
        .package(path: "localPackages/BitFoundation"),
        .package(path: "localPackages/BitLogger"),
        .package(path: "localPackages/AgentInfra"),
        .package(path: "localPackages/WhisperInfra"),
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1",       exact: "0.21.1"),
        .package(url: "https://github.com/ml-explore/mlx-swift",             exact: "0.31.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm",          exact: "3.31.3"),
        .package(url: "https://github.com/huggingface/swift-transformers",   exact: "0.1.24"),
        .package(url: "https://github.com/huggingface/swift-huggingface",    exact: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "SafeGuardian",
            dependencies: [
                .product(name: "P256K",         package: "swift-secp256k1"),
                .product(name: "BitFoundation", package: "BitFoundation"),
                .product(name: "BitLogger",     package: "BitLogger"),
                .product(name: "Tor",           package: "Arti"),
                .product(name: "AgentInfra",    package: "AgentInfra"),
                .product(name: "WhisperInfra",  package: "WhisperInfra"),
                .product(name: "MLX",           package: "mlx-swift"),
                .product(name: "MLXLMCommon",   package: "mlx-swift-lm"),
                .product(name: "MLXLLM",        package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace",package: "mlx-swift-lm"),
                .product(name: "HuggingFace",   package: "swift-huggingface"),
                .product(name: "Transformers",  package: "swift-transformers"),
            ],
            path: "SafeGuardian",
            exclude: [
                "Info.plist",
                "Assets.xcassets",
                "_PreviewHelpers/PreviewAssets.xcassets",
                "SafeGuardian.entitlements",
                "SafeGuardian-macOS.entitlements",
                "LaunchScreen.storyboard",
                "ViewModels/Extensions/README.md"
            ],
            resources: [
                .process("Localizable.xcstrings")
            ]
        ),
        .testTarget(
            name: "SafeGuardianTests",
            dependencies: [
                "SafeGuardian",
                .product(name: "BitFoundation", package: "BitFoundation"),
                .product(name: "AgentInfra",    package: "AgentInfra"),
            ],
            path: "SafeGuardianTests",
            exclude: [
                "Info.plist",
                "README.md"
            ],
            resources: [
                .process("Localization"),
                .process("Noise")
            ]
        )
    ]
)
