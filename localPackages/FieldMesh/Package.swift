// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FieldMesh",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "FieldMesh", targets: ["FieldMesh"])
    ],
    targets: [
        .binaryTarget(
            name: "ReticulumMobileFFI",
            path: "ReticulumMobile.xcframework"
        ),
        .target(
            name: "FieldMesh",
            dependencies: ["ReticulumMobileFFI"],
            path: "Sources/FieldMesh"
        )
    ]
)
