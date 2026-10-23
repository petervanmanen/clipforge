// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FitMovie",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "FitMovie", path: "Sources/FitMovie"),
        .testTarget(name: "FitMovieTests", dependencies: ["FitMovie"], path: "Tests/FitMovieTests"),
    ],
    swiftLanguageModes: [.v5]
)
