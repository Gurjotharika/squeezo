// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CompressCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CompressCore", targets: ["CompressCore"]),
    ],
    targets: [
        .target(name: "CompressCore"),
        .testTarget(name: "CompressCoreTests", dependencies: ["CompressCore"]),
    ]
)
