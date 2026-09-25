// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ovp",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ovp", targets: ["ovp"])
    ],
    targets: [
        .executableTarget(name: "ovp", path: "Sources/ovp")
    ]
)
