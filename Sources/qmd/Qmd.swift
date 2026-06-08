import ArgumentParser
import Foundation
import QMDKit

@main
struct Qmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "qmd",
        abstract: "On-device semantic + keyword search over your Markdown.",
        subcommands: [
            Index.self, Search.self, VSearch.self, Query.self, Get.self, Ls.self,
            Status.self, Update.self, CollectionCommand.self, Init.self,
        ],
        defaultSubcommand: Query.self)
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

    func open() throws -> SQLiteVectorStore {
        let directory = (indexPath as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        return try SQLiteVectorStore(storage: .file(indexPath), embeddingProvider: Self.embeddingProvider())
    }

    /// OpenAI when `OPENAI_API_KEY` is set (model overridable via
    /// `QMD_EMBED_MODEL`); otherwise nil, so the store uses the on-device Apple
    /// NaturalLanguage embedder.
    static func embeddingProvider() -> EmbeddingProvider? {
        let environment = ProcessInfo.processInfo.environment
        guard let key = environment["OPENAI_API_KEY"], !key.isEmpty else { return nil }
        let model = environment["QMD_EMBED_MODEL"] ?? "text-embedding-3-small"
        return OpenAIEmbeddingProvider(apiKey: key, model: model)
    }

    func loadConfig() -> Config { Config.load(at: configPath) }
    func saveConfig(_ config: Config) throws { try config.save(to: configPath) }
}

/// Output format — exposed as mutually-exclusive flags (`--json`, `--files`, …).
enum OutputFormat: String, EnumerableFlag {
    case cli, json, files, csv, md, xml
    static func help(for value: OutputFormat) -> ArgumentHelp? {
        switch value {
            case .cli:   return "Colorized listing (default)."
            case .json:  return "JSON array."
            case .files: return "`citation<TAB>score` per line, for piping to agents."
            case .csv:   return "CSV with a header row."
            case .md:    return "Markdown."
            case .xml:   return "XML."
        }
    }
}

/// `-n` plus the result format. Shared by every search subcommand.
struct OutputOptions: ParsableArguments {
    @Option(name: .customShort("n"), help: "Maximum number of results.")
    var count = 5
    @Flag(help: "Output format.")
    var format: OutputFormat = .cli

    func render(_ results: [MemoryMatch]) {
        switch format {
            case .cli:   renderCLI(results)
            case .json:  renderJSON(results)
            case .files: for match in results { print("\(match.citation)\t\(score(match))") }
            case .csv:   renderCSV(results)
            case .md:    renderMarkdown(results)
            case .xml:   renderXML(results)
        }
    }

    private func score(_ match: MemoryMatch) -> String { String(format: "%.4f", match.score) }
    private func percent(_ match: MemoryMatch) -> Int { Int((match.score * 100).rounded()) }
    private func firstLine(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
    }

    private func renderCLI(_ results: [MemoryMatch]) {
        guard !results.isEmpty else { FileHandle.standardError.write(Data("no matches\n".utf8)); return }
        for match in results {
            print("\(match.citation)  \(percent(match))%")
            let snippet = firstLine(match.text)
            if !snippet.isEmpty { print("  \(snippet)") }
        }
    }

    private func renderJSON(_ results: [MemoryMatch]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(results.map(ResultDTO.init)),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }

    private func renderCSV(_ results: [MemoryMatch]) {
        func field(_ value: String) -> String {
            guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return value }
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        print("citation,score,path,source,startLine,endLine,text")
        for match in results {
            print([match.citation, score(match), match.path, match.source,
                   "\(match.startLine)", "\(match.endLine)", match.text].map(field).joined(separator: ","))
        }
    }

    private func renderMarkdown(_ results: [MemoryMatch]) {
        for match in results {
            print("### \(match.citation)\n\n**score:** \(percent(match))%\n\n\(match.text)\n")
        }
    }

    private func renderXML(_ results: [MemoryMatch]) {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        print("<results>")
        for match in results {
            print("  <result citation=\"\(escape(match.citation))\" score=\"\(score(match))\""
                + " path=\"\(escape(match.path))\" source=\"\(escape(match.source))\""
                + " startLine=\"\(match.startLine)\" endLine=\"\(match.endLine)\">")
            print("    <text>\(escape(match.text))</text>")
            print("  </result>")
        }
        print("</results>")
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
            print("index:      \(store.indexPath)")
            let backend = StoreOptions.embeddingProvider()?.embeddingModelIdentifier
                ?? "Apple NaturalLanguage (on-device)"
            print("embeddings: \(backend)")
            print("chunks:     \(try store.open().count())")
            let collections = store.loadConfig().collections
            if !collections.isEmpty {
                print("collections:")
                for collection in collections { print("  \(collection.name)  \(collection.path)") }
            }
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
