// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CarrelCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CarrelCore", targets: ["CarrelCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "CarrelCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(name: "CarrelCoreTests", dependencies: ["CarrelCore"]),
    ],
    swiftLanguageModes: [.v5]
)
