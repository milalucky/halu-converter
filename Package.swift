// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "HaluConverter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "HaluConverter", path: "Sources/HaluConverter")
    ]
)
