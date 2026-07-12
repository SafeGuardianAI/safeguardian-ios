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
        .package(path: "../../shared/SafeGuardianMesh"),
        .package(path: "localPackages/Arti"),
        .package(path: "../../shared/BitFoundation"),
        .package(path: "../../shared/BitLogger"),
        .package(path: "localPackages/AgentInfra"),
        .package(path: "localPackages/WhisperInfra"),
        .package(path: "localPackages/AnyLanguageModelKit"),
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1",       exact: "0.21.1"),
        .package(url: "https://github.com/huggingface/swift-huggingface",    exact: "0.9.0"),
        // Direct declarations for AnyLanguageModel's MLX-trait conditional deps:
        // SwiftPM's trait resolution fails at the root manifest without them
        // (same workaround AnyLanguageModelKit's own manifest documents).
        .package(url: "https://github.com/ml-explore/mlx-swift-lm",          from: "3.0.0"),
        .package(url: "https://github.com/huggingface/swift-transformers",   from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "SafeGuardian",
            dependencies: [
                .product(name: "SafeGuardianMesh", package: "SafeGuardianMesh"),
                .product(name: "P256K",         package: "swift-secp256k1"),
                .product(name: "BitFoundation", package: "BitFoundation"),
                .product(name: "BitLogger",     package: "BitLogger"),
                .product(name: "Tor",           package: "Arti"),
                .product(name: "AgentInfra",    package: "AgentInfra"),
                .product(name: "WhisperInfra",  package: "WhisperInfra"),
                .product(name: "AnyLanguageModelKit", package: "AnyLanguageModelKit"),
                .product(name: "HuggingFace",   package: "swift-huggingface"),
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
            ],
            swiftSettings: [
                .unsafeFlags(["-Xfrontend", "-disable-access-control"])
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
