import ArgumentParser
import Foundation
import QMDKit

@main
struct Qmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "qmd",
        abstract: "On-device semantic + keyword search over your Markdown.",
        subcommands: [Index.self, Search.self, VSearch.self, Query.self, Status.self],
        defaultSubcommand: Query.self)
}

/// qmd's default index location — `$XDG_CACHE_HOME/qmd/index.sqlite`, falling
/// back to `~/.cache/qmd/index.sqlite`, matching the upstream CLI.
let defaultIndexPath: String = {
    let cache = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"]
        ?? (NSHomeDirectory() + "/.cache")
    return cache + "/qmd/index.sqlite"
}()

/// `--db` — the on-disk index. Shared by every subcommand.
struct StoreOptions: ParsableArguments {
    @Option(name: [.customShort("d"), .long],
            help: "Path to the index database (default: $XDG_CACHE_HOME/qmd/index.sqlite).")
    var db = defaultIndexPath

    func open() throws -> SQLiteVectorStore {
        let directory = (db as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        return try SQLiteVectorStore(storage: .file(db))
    }
}

/// `-n` / `--json` — shared result formatting.
struct OutputOptions: ParsableArguments {
    @Option(name: .customShort("n"), help: "Maximum number of results.")
    var count = 5
    @Flag(name: .long, help: "Emit JSON instead of the default listing.")
    var json = false

    func render(_ results: [MemoryMatch]) {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(results.map(ResultDTO.init)),
               let text = String(data: data, encoding: .utf8) {
                print(text)
            }
            return
        }
        guard !results.isEmpty else {
            FileHandle.standardError.write(Data("no matches\n".utf8))
            return
        }
        for match in results {
            let percent = Int((match.score * 100).rounded())
            let snippet = match.text.split(separator: "\n", omittingEmptySubsequences: true)
                .first.map(String.init) ?? ""
            print("\(match.citation)  \(percent)%")
            if !snippet.isEmpty { print("  \(snippet)") }
        }
    }
}

private struct ResultDTO: Encodable {
    let path, source, citation, text: String
    let startLine, endLine: Int
    let score: Double
    init(_ match: MemoryMatch) {
        path = match.path; source = match.source; citation = match.citation; text = match.text
        startLine = match.startLine; endLine = match.endLine; score = match.score
    }
}

extension Qmd {
    struct Index: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Index a directory of Markdown files.")
        @OptionGroup var store: StoreOptions
        @Option(help: "Source label recorded with each chunk.") var source = "files"
        @Argument(help: "Directory to index.") var directory: String

        func run() async throws {
            let vectorStore = try store.open()
            // Canonicalize so workspace-relative stripping matches the paths the
            // directory enumerator yields (e.g. /var vs /private/var on macOS).
            let root = URL(fileURLWithPath: directory).resolvingSymlinksInPath()
            let files = markdownFiles(in: root)
            FileHandle.standardError.write(Data("indexing \(files.count) file(s)…\n".utf8))
            let summary = try await vectorStore.sync(files: files, source: source, workspaceDir: root.path)
            print("indexed \(summary.indexed), unchanged \(summary.unchanged), "
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
            let results = try store.open().keywordSearch(ftsQuery(query), topN: output.count)
            output.render(results)
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
            let results = try await store.open().search(text: query.joined(separator: " "), topN: output.count)
            output.render(results)
        }
    }

    struct Query: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Hybrid search (keyword + semantic).")
        @OptionGroup var store: StoreOptions
        @OptionGroup var output: OutputOptions
        @Argument(parsing: .remaining, help: "Query.") var query: [String]

        func run() async throws {
            let results = try await store.open().hybridSearch(text: query.joined(separator: " "), topN: output.count)
            output.render(results)
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show index information.")
        @OptionGroup var store: StoreOptions
        func run() async throws {
            print("db:     \(store.db)")
            print("chunks: \(try store.open().count())")
        }
    }
}

/// All `*.md` files under `dir`, as absolute paths.
func markdownFiles(in dir: URL) -> [String] {
    guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
        return []
    }
    var paths: [String] = []
    // Resolve symlinks so paths canonicalize the same way as the (also
    // symlink-resolved) workspace root — otherwise macOS's /var vs /private/var
    // defeats the workspace-relative stripping.
    for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
        paths.append(url.resolvingSymlinksInPath().path)
    }
    return paths.sorted()
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
