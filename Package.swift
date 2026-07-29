// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Pulse",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "pulse", targets: ["Pulse"]),
        .executable(name: "PulseApp", targets: ["PulseApp"]),
        .executable(name: "pulse-tests", targets: ["PulseTests"]),
    ],
    targets: [
        .target(
            name: "PulseCore",
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "Pulse",
            dependencies: ["PulseCore"]
        ),
        .executableTarget(
            name: "PulseApp",
            dependencies: ["PulseCore"],
            // swift build does not compile Metal sources, so the shader ships
            // as a prebuilt default.metallib; regenerate it from Ripple.metal
            // with scripts/compile-shaders.sh after editing the source.
            exclude: ["Ripple.metal"],
            resources: [.copy("Resources/default.metallib"), .copy("Resources/Fonts")]
        ),
        .executableTarget(
            name: "PulseTests",
            dependencies: ["PulseCore"],
            path: "Tests/PulseCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
