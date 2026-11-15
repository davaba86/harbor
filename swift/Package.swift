// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Harbor",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Harbor", path: "Sources/Harbor"),
        .testTarget(name: "HarborTests", dependencies: ["Harbor"], path: "Tests/HarborTests"),
    ]
)
