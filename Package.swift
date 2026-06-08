// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "QMDKit",
    platforms: [
        // NLContextualEmbedding (the on-device default embedder) requires
        // macOS 14 / iOS 17 / tvOS 17 / watchOS 10 / visionOS 1.
        .macOS(.v14),
        .iOS(.v17),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "QMDKit", targets: ["QMDKit"]),
        // The qmd command, exposed so SwiftBash (or any ShellKit host) can
        // register it as a sandboxed builtin: `shell.register(Qmd.self)`.
        .library(name: "QmdCommand", targets: ["QmdCommand"]),
        .executable(name: "qmd", targets: ["qmd"]),
    ],
    dependencies: [
        // The SQLite engine: vec0 (sqlite-vec) + FTS5. Always needed.
        .package(url: "https://github.com/Cocoanetics/SQLiteKit",
                 branch: "main",
                 traits: ["FTS5", "SQLiteVec"]),
        // The qmd CLI's argument parser (command targets only).
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        // The virtualized shell host — Command protocol, Shell.current IO,
        // sandbox authorization — for the qmd builtin. Pinned to main.
        .package(url: "https://github.com/Cocoanetics/ShellKit", branch: "main"),
    ],
    targets: [
        // The engine — no ShellKit / ArgumentParser, so library consumers (the
        // wiki app, SwiftAgents) take it with a minimal closure.
        .target(
            name: "QMDKit",
            dependencies: [
                .product(name: "SQLiteKit", package: "SQLiteKit"),
            ]
        ),
        .testTarget(name: "QMDKitTests", dependencies: ["QMDKit"]),

        // The qmd command logic — routes IO through ShellKit's `Shell.current`
        // and gates every path via `Shell.authorize`, so it runs both
        // standalone and as a sandboxed SwiftBash builtin.
        .target(
            name: "QmdCommand",
            dependencies: [
                "QMDKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "ShellKit", package: "ShellKit"),
            ]
        ),
        .testTarget(
            name: "QmdCommandTests",
            dependencies: [
                "QmdCommand",
                .product(name: "ShellKit", package: "ShellKit"),
            ]
        ),

        // Thin @main wrapper; standalone `Shell.current` defaults to process
        // stdio with no sandbox, so the same command code runs unsandboxed here.
        .executableTarget(name: "qmd", dependencies: ["QmdCommand"]),
    ]
)
