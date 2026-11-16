// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GaussCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "GaussCore", targets: ["GaussCore"]),
        .executable(name: "gauss-cli", targets: ["gauss-cli"]),
    ],
    targets: [
        .target(name: "GaussCore"),
        .executableTarget(name: "gauss-cli", dependencies: ["GaussCore"]),
        .testTarget(name: "GaussCoreTests", dependencies: ["GaussCore"]),
    ]
)
