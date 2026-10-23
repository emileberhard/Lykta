// swift-tools-version: 6.4
import PackageDescription

let linux = TargetDependencyCondition.when(platforms: [.linux])

let package = Package(
    name: "LyktaGateway",
    platforms: [.macOS(.v27)],
    dependencies: [
        .package(path: "../Core"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.104.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.0.3"),
        .package(url: "https://github.com/apple/swift-asn1.git", exact: "1.7.3"),
        .package(url: "https://github.com/apple/swift-certificates.git", exact: "1.21.0"),
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])]),
        .executableTarget(
            name: "LyktaGateway",
            dependencies: [
                .product(name: "LyktaCore", package: "Core"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto", condition: linux),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "X509", package: "swift-certificates"),
                .target(name: "CSQLite", condition: linux),
            ],
            resources: [.embedInCode("Skill")]
        ),
        .testTarget(name: "LyktaGatewayTests", dependencies: ["LyktaGateway"]),
    ]
)
