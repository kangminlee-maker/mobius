// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Mobius",
    defaultLocalization: "ko",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MobiusCore", targets: ["MobiusCore"]),
        .executable(name: "mobius", targets: ["mobius"]),
        .executable(name: "MobiusApp", targets: ["MobiusApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(name: "MobiusCore"),
        .executableTarget(name: "mobius", dependencies: [
            "MobiusCore",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .executableTarget(name: "MobiusApp", dependencies: ["MobiusCore"]),
        .testTarget(name: "MobiusCoreTests", dependencies: ["MobiusCore"]),
    ]
)
