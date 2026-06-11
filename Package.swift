// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "QMDKit",
    platforms: [
        // Matches SwiftAgents (the engine upstream): NLContextualEmbedding (the
        // on-device default embedder) requires macOS 14 / iOS 17 / watchOS 10.
        .macOS(.v14),
        .iOS(.v17),
        .watchOS(.v10),
    ],
    products: [
        // The qmd command, exposed so SwiftBash (or any ShellKit host) can
        // register it as a sandboxed builtin: `shell.register(Qmd.self)`.
        .library(name: "QmdCommand", targets: ["QmdCommand"]),
        .executable(name: "qmd", targets: ["qmd"]),
    ],
    dependencies: [
        // The search engine lives upstream in SwiftAgents' `SemanticStore`:
        // `SQLiteVectorStore` (sqlite-vec `vec0` + FTS5 hybrid), the
        // markdown-aware chunker, and the embedding providers (Apple
        // NaturalLanguage / OpenAI / Ollama). qmd is a pure consumer — the
        // `SQLiteVectorStore` trait pulls in SQLiteKit (FTS5 + SQLiteVec)
        // transitively, so there's no direct SQLiteKit dep.
        .package(url: "https://github.com/Cocoanetics/SwiftAgents",
                 branch: "main",
                 traits: ["SQLiteVectorStore"]),
        // The qmd CLI's argument parser (command target only).
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        // The virtualized shell host — Command protocol, Shell.current IO,
        // sandbox authorization — for the qmd builtin. Pinned to main.
        .package(url: "https://github.com/Cocoanetics/ShellKit", branch: "main"),
    ],
    targets: [
        // The qmd command logic — routes IO through ShellKit's `Shell.current`
        // and gates every path via `Shell.authorize`, so it runs both standalone
        // and as a sandboxed SwiftBash builtin. The engine is SwiftAgents'
        // `SemanticStore` (the store + chunker) and `Providers` (embeddings).
        .target(
            name: "QmdCommand",
            dependencies: [
                .product(name: "SemanticStore", package: "SwiftAgents"),
                .product(name: "Providers", package: "SwiftAgents"),
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
