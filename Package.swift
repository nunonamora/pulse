// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Atalaia",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "atalaia", targets: ["Atalaia"]),
        .executable(name: "AtalaiaApp", targets: ["AtalaiaApp"]),
        .executable(name: "atalaia-tests", targets: ["AtalaiaTests"]),
    ],
    targets: [
        .target(
            name: "AtalaiaCore",
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "Atalaia",
            dependencies: ["AtalaiaCore"]
        ),
        .executableTarget(
            name: "AtalaiaApp",
            dependencies: ["AtalaiaCore"],
            // swift build does not compile Metal sources, so the shader ships
            // as a prebuilt default.metallib; regenerate it from Ripple.metal
            // with scripts/compile-shaders.sh after editing the source.
            exclude: ["Ripple.metal"],
            resources: [.copy("Resources/default.metallib")]
        ),
        .executableTarget(
            name: "AtalaiaTests",
            dependencies: ["AtalaiaCore"],
            path: "Tests/AtalaiaCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
