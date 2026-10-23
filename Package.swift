// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClipForge",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "ClipForge", path: "Sources/ClipForge"),
        .testTarget(name: "ClipForgeTests", dependencies: ["ClipForge"], path: "Tests/ClipForgeTests"),
    ],
    swiftLanguageModes: [.v5]
)
