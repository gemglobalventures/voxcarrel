// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoxCarrelCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VoxCarrelCore", targets: ["VoxCarrelCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "VoxCarrelCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(name: "VoxCarrelCoreTests", dependencies: ["VoxCarrelCore"]),
    ],
    swiftLanguageModes: [.v5]
)
