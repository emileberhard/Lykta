// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Core",
    platforms: [.macOS(.v27), .iOS(.v27)],
    products: [.library(name: "LyktaCore", targets: ["LyktaCore"])],
    targets: [
        .systemLibrary(name: "CZlib", pkgConfig: "zlib", providers: [.apt(["zlib1g-dev"])]),
        .target(name: "LyktaCore", dependencies: [.target(name: "CZlib", condition: .when(platforms: [.linux]))]),
        .testTarget(name: "LyktaCoreTests", dependencies: ["LyktaCore"]),
    ]
)
