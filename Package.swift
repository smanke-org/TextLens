// swift-tools-version: 6.2
import PackageDescription

// The shared logic lives in TextLensKit, a plain Swift package so `swift test` runs it
// without Xcode. The app is built by project.yml (XcodeGen), which links this package:
// CloudKit needs a provisioning profile, which only an Xcode build signs in.
let package = Package(
    name: "TextLensKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "TextLensKit", targets: ["TextLensKit"]),
    ],
    targets: [
        .target(name: "TextLensKit"),
        .testTarget(name: "TextLensKitTests", dependencies: ["TextLensKit"]),
    ]
)
