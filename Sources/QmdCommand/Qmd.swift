import ArgumentParser
import Foundation
import SemanticStore
import ShellKit

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
            case .files: for match in results { out("\(match.citation)\t\(score(match))") }
            case .csv:   renderCSV(results)
            case .md:    renderMarkdown(results)
            case .xml:   renderXML(results)
        }
    }

    private func score(_ match: MemoryMatch) -> String { String(format: "%.4f", match.score) }
    // RRF / blended scores aren't absolute confidences, so the percentage is
    // shown relative to the top result (the best match is 100%).
    private func percent(_ match: MemoryMatch, relativeTo top: Double) -> Int {
        top > 0 ? Int((match.score / top * 100).rounded()) : 0
    }
    private func firstLine(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
    }

    private func renderCLI(_ results: [MemoryMatch]) {
        guard !results.isEmpty else { warn("no matches"); return }
        let top = results.map(\.score).max() ?? 0
        for match in results {
            out("\(match.citation)  \(percent(match, relativeTo: top))%")
            let snippet = firstLine(match.text)
            if !snippet.isEmpty { out("  \(snippet)") }
        }
    }

    private func renderJSON(_ results: [MemoryMatch]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(results.map(ResultDTO.init)),
           let text = String(data: data, encoding: .utf8) {
            out(text)
        }
    }

    private func renderCSV(_ results: [MemoryMatch]) {
        func field(_ value: String) -> String {
            guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return value }
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        out("citation,score,path,source,startLine,endLine,text")
        for match in results {
            out([match.citation, score(match), match.path, match.source,
                 "\(match.startLine)", "\(match.endLine)", match.text].map(field).joined(separator: ","))
        }
    }

    private func renderMarkdown(_ results: [MemoryMatch]) {
        let top = results.map(\.score).max() ?? 0
        for match in results {
            out("### \(match.citation)\n\n**score:** \(percent(match, relativeTo: top))%\n\n\(match.text)\n")
        }
    }

    private func renderXML(_ results: [MemoryMatch]) {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        out("<results>")
        for match in results {
            out("  <result citation=\"\(escape(match.citation))\" score=\"\(score(match))\""
                + " path=\"\(escape(match.path))\" source=\"\(escape(match.source))\""
                + " startLine=\"\(match.startLine)\" endLine=\"\(match.endLine)\">")
            out("    <text>\(escape(match.text))</text>")
            out("  </result>")
        }
        out("</results>")
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
            let results = try await store.open().keywordSearch(ftsQuery(query), topN: output.count)
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
        static let configuration = CommandConfiguration(
            abstract: "Hybrid search with query expansion (keyword + semantic).")
        @OptionGroup var store: StoreOptions
        @OptionGroup var output: OutputOptions
        @Option(help: "Domain hint to steer expansion (e.g. \"billing\").") var intent: String?
        @Option(name: .long, help: "Pre-typed keyword query; repeatable. Skips expansion.") var lex: [String] = []
        @Option(name: .long, help: "Pre-typed semantic query; repeatable.") var vec: [String] = []
        @Option(name: .long, help: "Pre-typed hypothetical-answer query; repeatable.") var hyde: [String] = []
        @Flag(help: "Rerank the fused shortlist with an LLM (needs OPENAI_API_KEY).") var rerank = false
        @Argument(parsing: .remaining, help: "Query.") var query: [String] = []

        func run() async throws {
            let text = query.joined(separator: " ")
            let vectorStore = try await store.open()
            let reranker = rerank ? StoreOptions.reranker() : nil
            // Rerank over a wider shortlist, then cut to the requested count.
            let pool = reranker != nil ? max(output.count * 4, 20) : output.count

            let candidates: [MemoryMatch]
            if lex.isEmpty, vec.isEmpty, hyde.isEmpty {
                candidates = try await vectorStore.expandedSearch(
                    text: text, using: StoreOptions.queryExpander(), intent: intent, topN: pool)
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
                    vector: vectorQueries, keyword: keywordQueries, topN: pool)
            }

            var results = candidates
            if let reranker {
                results = try await vectorStore.rerank(
                    query: text, candidates: candidates, using: reranker, intent: intent)
            }
            output.render(Array(results.prefix(output.count)))
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
