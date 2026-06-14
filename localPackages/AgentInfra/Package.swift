// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AgentInfra",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "AgentInfra", targets: ["AgentInfra"])
    ],
    targets: [
        .target(name: "AgentInfra", path: "Sources/AgentInfra")
    ]
)
