// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FootBrakeCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "FootBrakeCore", targets: ["FootBrakeCore"]),
        .executable(name: "footbrake-cli", targets: ["footbrake-cli"]),
    ],
    targets: [
        .target(name: "FootBrakeCore"),
        .executableTarget(name: "footbrake-cli", dependencies: ["FootBrakeCore"]),
        .testTarget(name: "FootBrakeCoreTests", dependencies: ["FootBrakeCore"]),
    ]
)
