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
    ],
    dependencies: [
        // The SQLite engine: vec0 (sqlite-vec) + FTS5. QMDKit is the vector
        // store, so it always needs both — the traits are unconditional.
        // Pinned to main until SQLiteKit tags a release.
        .package(url: "https://github.com/Cocoanetics/SQLiteKit",
                 branch: "main",
                 traits: ["FTS5", "SQLiteVec"]),
    ],
    targets: [
        // The engine: a vec0 + FTS5 hybrid store with an on-device Apple
        // NaturalLanguage embedder, ported from SwiftAgents' VectorStore.
        .target(
            name: "QMDKit",
            dependencies: [
                .product(name: "SQLiteKit", package: "SQLiteKit"),
            ]
        ),
        .testTarget(
            name: "QMDKitTests",
            dependencies: ["QMDKit"]
        ),
    ]
)
