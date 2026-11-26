// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoxCarrelApp",
    platforms: [.macOS(.v15)],
    // The app is two libraries and a short program that starts them, so that a package
    // that adds features can start the same app with its features installed.
    products: [
        .library(name: "VoxCarrelAppCore", targets: ["VoxCarrelAppCore"]),
        .library(name: "VoxCarrelUI", targets: ["VoxCarrelUI"]),
        .executable(name: "VoxCarrel", targets: ["VoxCarrel"]),
        .executable(name: "voxcarrel-demo", targets: ["voxcarrel-demo"]),
    ],
    dependencies: [
        .package(path: "../VoxCarrelCore"),
    ],
    targets: [
        .target(
            name: "VoxCarrelAppCore",
            dependencies: ["DemoContent", .product(name: "VoxCarrelCore", package: "VoxCarrelCore")]
        ),
        .target(
            name: "VoxCarrelUI",
            dependencies: [
                "VoxCarrelAppCore",
                .product(name: "VoxCarrelCore", package: "VoxCarrelCore"),
            ]
        ),
        .executableTarget(
            name: "VoxCarrel",
            dependencies: ["VoxCarrelUI"]
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
            ],
            // The tests themselves are not optimised in a release build: it is the app's
            // own code that the release run is for, and optimising some sixteen hundred
            // tests as one module took five minutes of every run.
            swiftSettings: [.unsafeFlags(["-Onone", "-no-whole-module-optimization"], .when(configuration: .release))]
        ),
    ],
    swiftLanguageModes: [.v5]
)
