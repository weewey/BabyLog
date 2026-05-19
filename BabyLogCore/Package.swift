// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BabyLogCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "BabyLogCore", targets: ["BabyLogCore"]),
    ],
    targets: [
        .target(
            name: "BabyLogCore",
            path: "Sources/BabyLogCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "BabyLogCoreTests",
            dependencies: ["BabyLogCore"],
            path: "Tests/BabyLogCoreTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
