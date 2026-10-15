// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BatteryCycle",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "BatteryCycle", path: "Sources/BatteryCycle"),
    ]
)
