// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LittleECore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "LittleECore", targets: ["LittleECore"]),
    ],
    targets: [
        .target(
            name: "LittleECore",
            path: "Sources/LittleECore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "LittleECoreTests",
            dependencies: ["LittleECore"],
            path: "Tests/LittleECoreTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
