// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "OperaSubs",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SubtitleKit", targets: ["SubtitleKit"]),
        .executable(name: "OperaSubs", targets: ["OperaSubs"]),
    ],
    targets: [
        .target(name: "SubtitleKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .binaryTarget(name: "VLCKit", path: "Vendor/VLCKit.xcframework"),
        .executableTarget(
            name: "OperaSubs",
            dependencies: ["SubtitleKit", "VLCKit"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "SubtitleKitTests", dependencies: ["SubtitleKit"], resources: [.copy("Fixtures")]),
    ]
)
