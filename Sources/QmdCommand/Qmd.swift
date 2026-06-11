import ArgumentParser
import Foundation
import ShellKit
import VectorStore

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

/// Output format — `--format <kind>` is the preferred spelling; the
/// mutually-exclusive flags (`--json`, `--files`, …) remain as aliases.
enum OutputFormat: String, EnumerableFlag, ExpressibleByArgument {
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

/// One displayable hit: the engine match plus its display score. Cosine and
/// normalized bm25 pass through as-is; RRF-fused results carry the positional
/// `1/rank` (or the reranker's blend), the way the original qmd reports them.
struct ResultRow {
    let match: MemoryMatch
    let score: Double
}

/// Result-shaping options shared by every search subcommand.
struct OutputOptions: ParsableArguments {
    @Option(name: .customShort("n"), help: "Maximum number of results (default: 5; 20 for files/json).")
    var count: Int?
    @Option(name: .customLong("format"), help: "Output format: cli, json, files, csv, md or xml.")
    var formatChoice: OutputFormat?
    @Flag(help: "Output format.")
    var formatFlag: OutputFormat = .cli
    @Flag(help: "Show the full document instead of a snippet.")
    var full = false
    @Flag(name: .customLong("line-numbers"), help: "Prefix content lines with their line numbers.")
    var lineNumbers = false
    @Option(name: .customLong("min-score"), help: "Minimum score required to show a result.")
    var minScore: Double?
    @Flag(help: "Return all matches (pair with --min-score).")
    var all = false
    @Option(name: [.customShort("c"), .long], help: "Restrict to the given collection(s); repeatable.")
    var collection: [String] = []
    @Option(help: "Domain hint for disambiguation — steers expansion and snippet selection.")
    var intent: String?

    var format: OutputFormat { formatChoice ?? formatFlag }
    var limit: Int { all ? 100_000 : (count ?? (format == .files || format == .json ? 20 : 5)) }
    var sources: [String]? { collection.isEmpty ? nil : collection }

    // MARK: Rendering

    /// Filters by score, cuts to the limit, and renders in the chosen format.
    /// `defaultMinScore` is the per-command floor used when `--min-score` is
    /// not given (0.3 for vector search, like the original).
    func render(_ rows: [ResultRow], query: String, config: Config, defaultMinScore: Double = 0) async {
        let threshold = minScore ?? defaultMinScore
        let kept = Array(rows.filter { $0.score >= threshold }.prefix(limit))
        guard !kept.isEmpty else {
            printEmpty(rows.isEmpty ? .noResults : .minScore)
            return
        }
        let loader = DocumentLoader(config: config)
        switch format {
            case .cli:   await renderCLI(kept, query: query, loader: loader)
            case .json:  await renderJSON(kept, query: query, loader: loader)
            case .files: for row in kept { out("\(row.match.citation)\t\(String(format: "%.4f", row.score))") }
            case .csv:   await renderCSV(kept, query: query, loader: loader)
            case .md:    await renderMarkdown(kept, query: query, loader: loader)
            case .xml:   await renderXML(kept, query: query, loader: loader)
        }
    }

    private enum EmptyReason { case noResults, minScore }

    /// Format-safe empty output, mirroring the original's per-format shapes.
    private func printEmpty(_ reason: EmptyReason) {
        switch format {
            case .json: out("[]")
            case .csv:  out("score,file,title,context,line,snippet")
            case .xml:  out("<results></results>")
            case .md, .files: break
            case .cli:
                out(reason == .minScore
                    ? "No results found above minimum score threshold."
                    : "No results found.")
        }
    }

    /// One hit resolved for display: snippet/title come from the source
    /// document when it is readable, degrading to the stored chunk text.
    private struct DisplayRow {
        let match: MemoryMatch
        let score: Double
        let file: String              // "source/path" — pipeable into `qmd get`
        let absolutePath: String?     // on-disk location, when the document resolved
        let title: String
        let snippet: SnippetResult
        let fullText: String          // document body, or the cleaned chunk
        let fullStart: Int            // first line number of `fullText`
    }

    private func displayRow(
        _ row: ResultRow, query: String, loader: DocumentLoader, maxLen: Int
    ) async -> DisplayRow {
        let match = row.match
        let document = await loader.document(for: match)
        let body = document?.body
        let snippet = body.map {
            Snippet.extract(body: $0, query: query, maxLen: maxLen,
                            region: match.startLine ... match.endLine, intent: intent)
        } ?? Snippet.extractFromChunk(text: match.text, startLine: match.startLine,
                                      query: query, maxLen: maxLen, intent: intent)
        let fullText: String
        let fullStart: Int
        if let body {
            fullText = body
            fullStart = 1
        } else {
            let cleaned = Snippet.cleanedChunkLines(match.text, startLine: match.startLine)
            fullText = cleaned.lines.joined(separator: "\n")
            fullStart = cleaned.firstLineNumber
        }
        return DisplayRow(
            match: match, score: row.score,
            file: "\(match.source)/\(match.path)",
            absolutePath: document?.path,
            title: Snippet.extractTitle(body, filename: match.path),
            snippet: snippet, fullText: fullText, fullStart: fullStart)
    }

    /// The content block for a display row: full document or snippet body,
    /// line-numbered on request, with the `@@` header re-attached for snippets.
    private func contentBlock(_ row: DisplayRow) -> String {
        let text = full ? row.fullText : row.snippet.text
        let start = full ? row.fullStart : row.snippet.start
        let numbered = lineNumbers ? Snippet.addLineNumbers(text, startLine: start) : text
        return full ? numbered : row.snippet.header + "\n" + numbered
    }

    private func renderCLI(_ rows: [ResultRow], query: String, loader: DocumentLoader) async {
        let palette = Palette.shell
        let terms = Snippet.queryTerms(query)
        for (index, row) in rows.enumerated() {
            let display = await displayRow(row, query: query, loader: loader, maxLen: 500)

            // Show `:line` only when a query term literally occurs in the
            // snippet body — semantic-only hits get the bare path.
            let snippetBody = display.snippet.text.lowercased()
            let hasMatch = terms.contains { snippetBody.contains($0) }
            let lineInfo = hasMatch ? ":\(display.snippet.line)" : ""

            // On a terminal, hyperlink the header to the document on disk
            // (OSC-8); the host decides what opens it — iBash its file editor,
            // or whatever a `QMD_EDITOR_URI` template points at.
            if palette.links, let absolutePath = display.absolutePath {
                let target = editorURI(for: absolutePath, line: hasMatch ? display.snippet.line : 1)
                out(palette.cyan + palette.link(display.file + lineInfo, to: target) + palette.reset)
            } else {
                out("\(palette.cyan)\(display.file)\(palette.dim)\(lineInfo)\(palette.reset)")
            }
            out("\(palette.bold)Title: \(display.title)\(palette.reset)")
            out("Score: \(palette.bold)\(palette.score(row.score))\(palette.reset)")
            out()
            out(palette.highlightTerms(contentBlock(display), query: query))
            if index < rows.count - 1 { out("\n") }   // double blank line between results
        }
    }

    private struct ResultDTO: Encodable {
        let citation, file, title: String
        let line: Int
        let score: Double
        let snippet: String?
        let body: String?
    }

    private func renderJSON(_ rows: [ResultRow], query: String, loader: DocumentLoader) async {
        var dtos: [ResultDTO] = []
        for row in rows {
            let display = await displayRow(row, query: query, loader: loader, maxLen: 300)
            dtos.append(ResultDTO(
                citation: display.match.citation,
                file: display.file,
                title: display.title,
                line: display.snippet.line,
                score: (row.score * 100).rounded() / 100,
                snippet: full ? nil : contentBlock(display),
                body: full ? contentBlock(display) : nil))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(dtos), let text = String(data: data, encoding: .utf8) {
            out(text)
        }
    }

    private func renderCSV(_ rows: [ResultRow], query: String, loader: DocumentLoader) async {
        func field(_ value: String) -> String {
            guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return value }
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        out("score,file,title,context,line,snippet")
        for row in rows {
            let display = await displayRow(row, query: query, loader: loader, maxLen: 500)
            out([String(format: "%.4f", row.score), field(display.file), field(display.title),
                 "", "\(display.snippet.line)", field(contentBlock(display))].joined(separator: ","))
        }
    }

    private func renderMarkdown(_ rows: [ResultRow], query: String, loader: DocumentLoader) async {
        for row in rows {
            let display = await displayRow(row, query: query, loader: loader, maxLen: 500)
            out("---\n# \(display.title)\n**file:** `\(display.file)`\n\n\(contentBlock(display))\n")
        }
    }

    private func renderXML(_ rows: [ResultRow], query: String, loader: DocumentLoader) async {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        for row in rows {
            let display = await displayRow(row, query: query, loader: loader, maxLen: 500)
            out("<file name=\"\(escape(display.file))\" title=\"\(escape(display.title))\">\n"
                + escape(contentBlock(display)) + "\n</file>\n")
        }
    }
}

/// Re-reads source documents for snippet and title rendering, caching hits
/// and misses per `source:path`. Resolution tries the source's collection
/// root, the generic resolver, then the shell CWD (which covers ad-hoc
/// `qmd index .` sources); every read is gated by `Shell.authorize`, and any
/// failure degrades the caller to chunk-text rendering.
final class DocumentLoader {
    /// A successfully re-read document: its absolute path and content.
    struct Document {
        let path: String
        let body: String
    }

    private let config: Config
    private var cache: [String: Document?] = [:]

    init(config: Config) { self.config = config }

    func document(for match: MemoryMatch) async -> Document? {
        let key = "\(match.source):\(match.path)"
        if let cached = cache[key] { return cached }
        let document = await load(match)
        cache[key] = document
        return document
    }

    private func load(_ match: MemoryMatch) async -> Document? {
        var candidates: [String] = []
        if let collection = config.collection(named: match.source) {
            candidates.append(collection.path + "/" + match.path)
        }
        if let resolved = resolveDocument(match.path, config: config) {
            candidates.append(resolved)
        }
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            guard (try? await Shell.authorize(URL(fileURLWithPath: path))) != nil else { continue }
            if let body = try? String(contentsOfFile: path, encoding: .utf8) {
                return Document(path: URL(fileURLWithPath: path).standardizedFileURL.path, body: body)
            }
        }
        return nil
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
