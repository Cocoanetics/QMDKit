import ArgumentParser
import Foundation
import ShellKit
import SemanticStore

/// `qmd` — on-device semantic + keyword search over Markdown. Public so a
/// ShellKit host (SwiftBash) can register it as a sandboxed builtin via
/// `shell.register(Qmd.self)`; also runnable standalone (`await Qmd.main()`).
public struct Qmd: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "qmd",
        abstract: "On-device semantic + keyword search over your Markdown.",
        subcommands: [
            Index.self, Search.self, VSearch.self, Query.self, Get.self, Ls.self,
            Status.self, Update.self, CollectionCommand.self, Init.self
        ],
        defaultSubcommand: Query.self)

    public init() {}
}

/// `--db` plus the resolved qmd home — a local `./.qmd` when present (see
/// `qmd init`), otherwise `$XDG_CACHE_HOME/qmd`. Shared by every subcommand.
struct StoreOptions: ParsableArguments {
    @Option(name: [.customShort("d"), .long],
            help: "Index database path (default: <qmd home>/index.sqlite).")
    var db: String?

    var home: String { db.map { ($0 as NSString).deletingLastPathComponent } ?? qmdHome() }
    var indexPath: String { db ?? (qmdHome() + "/index.sqlite") }
    var configPath: String { home + "/collections.json" }

    // `open()` and the embedding-backend selection live in Embeddings.swift —
    // they need SwiftAgents' `Providers`, which exports a `struct Argument` that
    // would collide with ArgumentParser's `@Argument` in this file.

    func loadConfig() -> Config { Config.load(at: configPath) }
    func saveConfig(_ config: Config) throws { try config.save(to: configPath) }
}

extension Qmd {
    struct Index: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Index a directory of Markdown files.")
        @OptionGroup var store: StoreOptions
        @Option(help: "Source label recorded with each chunk.") var source = "files"
        @Argument(help: "Directory to index.") var directory: String

        func run() async throws {
            let vectorStore = try await store.open()
            // Resolve against the shell CWD; canonicalize so workspace-relative
            // stripping matches the enumerator (/var vs /private/var on macOS).
            let root = Shell.resolve(directory).resolvingSymlinksInPath()
            let files = await authorizedFiles(markdownFiles(in: root))
            warn("indexing \(files.count) file(s)…")
            let summary = try await vectorStore.sync(files: files, source: source, workspaceDir: root.path)
            out("indexed \(summary.indexed), unchanged \(summary.unchanged), "
                + "removed \(summary.removed), missing \(summary.missing) — "
                + "\(try vectorStore.count()) chunks total")
        }
    }

    struct Search: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Keyword search (FTS5 bm25).")
        @OptionGroup var store: StoreOptions
        @OptionGroup var output: OutputOptions
        @Argument(parsing: .remaining, help: "Query terms.") var query: [String]

        func run() async throws {
            let text = query.joined(separator: " ")
            // Over-fetch so --min-score / -c filtering can't starve the limit.
            let fetch = output.all ? 100_000 : max(50, output.limit * 2)
            let matches = try await store.open()
                .keywordSearch(ftsQuery(query), topN: fetch, sources: output.sources)
            let rows = matches.map { ResultRow(match: $0, score: $0.score) }
            await output.render(rows, query: text, config: store.loadConfig())
        }
    }

    struct VSearch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "vsearch",
            abstract: "Semantic search (vec0 cosine KNN over on-device Apple NL embeddings).")
        @OptionGroup var store: StoreOptions
        @OptionGroup var output: OutputOptions
        @Argument(parsing: .remaining, help: "Query.") var query: [String]

        func run() async throws {
            let text = query.joined(separator: " ")
            let fetch = output.all ? 500 : max(20, output.limit * 2)
            let matches = try await store.open()
                .search(text: text, topN: fetch, sources: output.sources)
            let rows = matches.map { ResultRow(match: $0, score: $0.score) }
            // Vector similarity defaults to a 0.3 floor, like the original.
            await output.render(rows, query: text, config: store.loadConfig(), defaultMinScore: 0.3)
        }
    }

    struct Query: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Hybrid search with query expansion (keyword + semantic).")
        @OptionGroup var store: StoreOptions
        @OptionGroup var output: OutputOptions
        @Option(name: .long, help: "Pre-typed keyword query; repeatable. Skips expansion.") var lex: [String] = []
        @Option(name: .long, help: "Pre-typed semantic query; repeatable.") var vec: [String] = []
        @Option(name: .long, help: "Pre-typed hypothetical-answer query; repeatable.") var hyde: [String] = []
        @Flag(help: "Rerank the fused shortlist with an LLM (needs OPENAI_API_KEY).") var rerank = false
        @Argument(parsing: .remaining, help: "Query.") var query: [String] = []

        func run() async throws {
            let text = query.joined(separator: " ")
            let vectorStore = try await store.open()
            let reranker = rerank ? StoreOptions.reranker() : nil
            let limit = output.all ? 1000 : output.limit
            // Rerank over a wider shortlist, then cut to the requested count.
            let pool = reranker != nil ? max(limit * 4, 20) : limit

            let candidates: [MemoryMatch]
            if lex.isEmpty, vec.isEmpty, hyde.isEmpty {
                candidates = try await vectorStore.expandedSearch(
                    text: text, using: StoreOptions.queryExpander(), intent: output.intent,
                    topN: pool, sources: output.sources)
            } else {
                // Caller-supplied typed queries route straight into RRF, skipping
                // the internal expander; the positional text (if any) is original.
                var vectorQueries = vec + hyde
                var keywordQueries = lex
                if !text.isEmpty {
                    vectorQueries.insert(text, at: 0)
                    keywordQueries.insert(text, at: 0)
                }
                candidates = try await vectorStore.fusedSearch(
                    vector: vectorQueries, keyword: keywordQueries, topN: pool, sources: output.sources)
            }

            let rows: [ResultRow]
            if let reranker {
                // The blend is position-aware and 0–1; report it directly.
                let reranked = try await vectorStore.rerank(
                    query: text, candidates: candidates, using: reranker, intent: output.intent)
                rows = reranked.map { ResultRow(match: $0, score: $0.score) }
            } else {
                // Raw RRF scores aren't confidences — report the positional
                // 1/rank the way the original does.
                rows = candidates.enumerated().map {
                    ResultRow(match: $0.element, score: 1.0 / Double($0.offset + 1))
                }
            }
            await output.render(rows, query: text, config: store.loadConfig())
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show index information.")
        @OptionGroup var store: StoreOptions
        func run() async throws {
            out("index:      \(store.indexPath)")
            out("embeddings: \(StoreOptions.embeddingBackendDescription())")
            out("chunks:     \(try await store.open().count())")
            let collections = store.loadConfig().collections
            if !collections.isEmpty {
                out("collections:")
                for collection in collections { out("  \(collection.name)  \(collection.path)") }
            }
        }
    }
}

/// All `*.md` files under `dir`, as absolute, symlink-resolved paths.
func markdownFiles(in dir: URL) -> [String] {
    guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
        return []
    }
    var paths: [String] = []
    for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
        paths.append(url.resolvingSymlinksInPath().path)
    }
    return paths.sorted()
}

/// Keep only the paths the host's sandbox authorizes (a no-op when unsandboxed).
func authorizedFiles(_ paths: [String]) async -> [String] {
    var result: [String] = []
    for path in paths {
        do {
            try await Shell.authorize(URL(fileURLWithPath: path))
            result.append(path)
        } catch {
            warn("denied: \(path)")
        }
    }
    return result
}

/// Turn free text into a safe FTS5 query: bare terms can trip on punctuation,
/// so keep alphanumeric tokens and OR them for recall.
func ftsQuery(_ terms: [String]) -> String {
    let tokens = terms.joined(separator: " ")
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
    guard !tokens.isEmpty else { return "\"\"" }
    return tokens.map { "\"\($0)\"" }.joined(separator: " OR ")
}
