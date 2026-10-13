// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TextLens",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "TextLensKit"),
        .executableTarget(name: "TextLens", dependencies: ["TextLensKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "TextLensKitTests", dependencies: ["TextLensKit"]),
    ]
)
