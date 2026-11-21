// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoxCarrelApp",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../VoxCarrelCore"),
    ],
    targets: [
        .target(
            name: "VoxCarrelAppCore",
            dependencies: [.product(name: "VoxCarrelCore", package: "VoxCarrelCore")]
        ),
        .executableTarget(
            name: "VoxCarrel",
            dependencies: ["VoxCarrelAppCore"]
        ),
        .target(
            name: "DemoContent",
            dependencies: [
                .product(name: "VoxCarrelCore", package: "VoxCarrelCore"),
                .product(name: "VoxCarrelFixtures", package: "VoxCarrelCore"),
            ]
        ),
        .executableTarget(name: "voxcarrel-demo", dependencies: ["DemoContent"]),
        .testTarget(
            name: "VoxCarrelAppCoreTests",
            dependencies: [
                "VoxCarrelAppCore", "DemoContent",
                .product(name: "VoxCarrelFixtures", package: "VoxCarrelCore"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
