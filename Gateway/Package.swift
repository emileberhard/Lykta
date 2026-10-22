// swift-tools-version: 6.4
import PackageDescription

let linux = TargetDependencyCondition.when(platforms: [.linux])
let examples = [
    "agent-question",
    "app-review",
    "homelab",
    "jira-release",
    "movie-night",
    "orion-return",
    "pr-inbox",
    "printer",
    "puppy-potty",
    "recipe-steps",
    "shopping-list",
    "solar-eclipse",
]

let package = Package(
    name: "LyktaGateway",
    platforms: [.macOS(.v27)],
    dependencies: [
        .package(path: "../Core"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.104.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.0.3"),
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
                .target(name: "CSQLite", condition: linux),
            ],
            resources: [.embedInCode("Skill/SKILL.md"), .embedInCode("Skill/references/layout.md")]
                + examples.map { .embedInCode("Skill/examples/\($0).json") }
        ),
        .testTarget(name: "LyktaGatewayTests", dependencies: ["LyktaGateway"]),
    ]
)
