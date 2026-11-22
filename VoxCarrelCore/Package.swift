// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoxCarrelCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VoxCarrelCore", targets: ["VoxCarrelCore"]),
        .library(name: "VoxCarrelFixtures", targets: ["VoxCarrelFixtures"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/sbooth/CXXTagLib", from: "2.3.2"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.20"),
    ],
    targets: [
        // Objective-C++ shim: the only target that sees TagLib's C++ headers.
        .target(
            name: "CTagBridge",
            dependencies: [.product(name: "taglib", package: "CXXTagLib")]
        ),
        .target(
            name: "VoxCarrelCore",
            dependencies: [
                "CTagBridge",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        // Sample media files generated in code, shared by this package's tests and the app's.
        // Independent of VoxCarrelCore in both directions.
        .target(
            name: "VoxCarrelFixtures",
            dependencies: ["CTagBridge", .product(name: "ZIPFoundation", package: "ZIPFoundation")]
        ),
        .testTarget(
            name: "VoxCarrelCoreTests",
            dependencies: [
                "VoxCarrelCore",
                "VoxCarrelFixtures",
                "CTagBridge",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            // Recorded lookup responses; no test touches the network.
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx17
)
