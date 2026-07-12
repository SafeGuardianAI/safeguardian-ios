// swift-tools-version: 5.9
import PackageDescription

// Run `./fetch_whisper.sh` once before building to populate Sources/whisper_cpp/
// with whisper.cpp and ggml source. The script pins to a specific whisper.cpp commit.

let package = Package(
    name: "WhisperInfra",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WhisperInfra", targets: ["WhisperInfra"])
    ],
    dependencies: [
        .package(path: "../AgentInfra")
    ],
    targets: [
        // C/C++ layer: whisper.cpp + ggml. Populated by fetch_whisper.sh.
        .target(
            name: "whisper_cpp",
            path: "Sources/whisper_cpp",
            exclude: ["_partial_backup", "_real_headers_backup"],
            publicHeadersPath: "include",
            cSettings: [
                .define("GGML_USE_METAL"),
                .define("WHISPER_USE_COREML", .when(platforms: [.iOS, .macOS]))
            ],
            cxxSettings: [
                .define("GGML_USE_METAL"),
                .define("WHISPER_USE_COREML", .when(platforms: [.iOS, .macOS])),
                .unsafeFlags(["-O3"])
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalPerformanceShaders"),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreML")
            ]
        ),
        // Swift layer: our AgentInfra-compatible wrapper.
        .target(
            name: "WhisperInfra",
            dependencies: [
                "whisper_cpp",
                .product(name: "AgentInfra", package: "AgentInfra")
            ],
            path: "Sources/WhisperInfra"
        )
    ]
)
