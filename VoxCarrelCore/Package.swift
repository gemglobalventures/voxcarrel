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
        // Objective-C++ shim: the only target that sees TagLib's C++ headers. It also asks
        // AVFoundation how long a file plays, through the calls that wait for the answer.
        .target(
            name: "CTagBridge",
            dependencies: [.product(name: "taglib", package: "CXXTagLib")],
            linkerSettings: [.linkedFramework("AVFoundation"), .linkedFramework("CoreMedia")]
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
            resources: [.copy("Fixtures")],
            // The tests themselves are not optimised in a release build: it is the
            // engine that is being tried optimised, and the tests take minutes less to build.
            swiftSettings: [.unsafeFlags(["-Onone", "-no-whole-module-optimization"], .when(configuration: .release))]
        ),
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx17
)
