// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HaluConverter",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "HaluConverter", path: "Sources/HaluConverter")
    ],
    swiftLanguageModes: [.v5]
)
