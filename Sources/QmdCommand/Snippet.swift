import Foundation
import ShellKit

// Query-aware snippet extraction and terminal rendering helpers, ported from
// the original qmd (github.com/tobi/qmd, src/store.ts extractSnippet and
// src/cli/qmd.ts). The original operates on the full document body with a
// char-offset chunk region; qmd-kit's store is chunk-level with line spans,
// so `extract` takes the chunk's line region and `extractFromChunk` covers
// the degraded case where the source document can't be re-read.

/// Result of snippet extraction — the best-match line and a display snippet
/// prefixed with a diff-style `@@ -start,count @@` header.
struct SnippetResult: Equatable {
    /// 1-based line number of the best-matching line in the source document.
    let line: Int
    /// 1-based document line number of the first line of `text`.
    let start: Int
    /// Diff-style position header, e.g. `@@ -87,4 @@ (86 before, 16 after)`.
    let header: String
    /// Up to four context lines around the match, truncated to `maxLen`.
    let text: String

    var snippet: String { header + "\n" + text }
}

enum Snippet {
    /// Intent terms contribute below query terms when scoring lines.
    static let intentWeight = 0.3

    /// Function words and search-context noise excluded from intent matching.
    static let intentStopWords: Set<String> = [
        // 2-char function words
        "am", "an", "as", "at", "be", "by", "do", "he", "if",
        "in", "is", "it", "me", "my", "no", "of", "on", "or", "so",
        "to", "up", "us", "we",
        // 3-char function words
        "all", "and", "any", "are", "but", "can", "did", "for", "get",
        "has", "her", "him", "his", "how", "its", "let", "may", "not",
        "our", "out", "the", "too", "was", "who", "why", "you",
        // 4+ char common words
        "also", "does", "find", "from", "have", "into", "more", "need",
        "show", "some", "tell", "them", "that", "this", "want", "what",
        "when", "will", "with", "your",
        // Search-context noise
        "about", "looking", "notes", "search", "where", "which",
    ]

    /// Meaningful terms from an intent string: lowercased, stripped of edge
    /// punctuation, longer than one character, and not a stop word.
    static func intentTerms(_ intent: String) -> [String] {
        intent.lowercased().split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
            .filter { $0.count > 1 && !intentStopWords.contains($0) }
    }

    /// Lowercased whitespace-split query terms (no length filter — mirrors the
    /// original's snippet scoring and `:line` gating).
    static func queryTerms(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Extracts a query-centered snippet from a full document `body`.
    /// `region` is the matched chunk's 1-based line span; scoring searches it
    /// (padded by one line each side, approximating the original's ±100-char
    /// padding) for the line with the most query-term hits, then returns that
    /// line with one line before and two after. Falls back to a whole-document
    /// scan when a document-opening chunk has no literal match.
    static func extract(
        body: String,
        query: String,
        maxLen: Int = 500,
        region: ClosedRange<Int>? = nil,
        intent: String? = nil
    ) -> SnippetResult {
        let lines = body.components(separatedBy: "\n")

        // 0-based inclusive search window.
        let searchLo = region.map { max(0, $0.lowerBound - 2) } ?? 0
        let searchHi = region.map { min(lines.count - 1, $0.upperBound) } ?? (lines.count - 1)

        var bestLine = searchLo
        var bestScore = -1.0
        if searchLo <= searchHi {
            let query = queryTerms(query)
            let intent = intent.map(intentTerms) ?? []
            for index in searchLo ... searchHi {
                let line = lines[index].lowercased()
                var score = 0.0
                for term in query where line.contains(term) { score += 1.0 }
                for term in intent where line.contains(term) { score += intentWeight }
                if score > bestScore {
                    bestScore = score
                    bestLine = index
                }
            }
        }

        if let region, bestScore <= 0 {
            if region.lowerBound == 1 {
                // A document-opening chunk with no literal match may just mean
                // the tokens got filtered — retry over the whole document.
                return extract(body: body, query: query, maxLen: maxLen, intent: intent)
            }
            // Mid-document chunks were actively picked by retrieval; semantic
            // hits often have no literal term, so anchor on the chunk start.
            bestLine = region.lowerBound - 1
        }

        let start = max(0, bestLine - 1)
        let end = min(lines.count, bestLine + 3)
        var text = lines[start ..< end].joined(separator: "\n")

        if let region, region.lowerBound > 1,
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A blank chunk window is useless — fall back to the whole document.
            return extract(body: body, query: query, maxLen: maxLen, intent: intent)
        }

        if text.count > maxLen { text = String(text.prefix(maxLen - 3)) + "..." }

        let absoluteStart = start + 1
        let count = end - start
        let linesBefore = absoluteStart - 1
        let linesAfter = lines.count - (absoluteStart + count - 1)
        let header = "@@ -\(absoluteStart),\(count) @@ (\(linesBefore) before, \(linesAfter) after)"
        return SnippetResult(line: bestLine + 1, start: absoluteStart, header: header, text: text)
    }

    /// Degraded extraction over the stored chunk text alone, for when the
    /// source document can't be re-read. Line numbers stay absolute via the
    /// chunk's `startLine`; the header omits the before/after counts because
    /// the document's total length is unknown.
    static func extractFromChunk(
        text chunkText: String,
        startLine: Int,
        query: String,
        maxLen: Int = 500,
        intent: String? = nil
    ) -> SnippetResult {
        let (lines, firstLineNumber) = cleanedChunkLines(chunkText, startLine: startLine)

        var bestLine = 0
        var bestScore = -1.0
        let query = queryTerms(query)
        let intent = intent.map(intentTerms) ?? []
        for index in lines.indices {
            let line = lines[index].lowercased()
            var score = 0.0
            for term in query where line.contains(term) { score += 1.0 }
            for term in intent where line.contains(term) { score += intentWeight }
            if score > bestScore {
                bestScore = score
                bestLine = index
            }
        }
        if bestScore <= 0 { bestLine = 0 }   // no literal match — anchor on the chunk start

        let start = max(0, bestLine - 1)
        let end = min(lines.count, bestLine + 3)
        var text = lines[start ..< end].joined(separator: "\n")
        if text.count > maxLen { text = String(text.prefix(maxLen - 3)) + "..." }

        let absoluteStart = firstLineNumber + start
        let header = "@@ -\(absoluteStart),\(end - start) @@"
        return SnippetResult(line: firstLineNumber + bestLine, start: absoluteStart, header: header, text: text)
    }

    /// A chunk's lines with the overlap artifact removed: chunks that don't
    /// open the document start mid-line inside the chunker's overlap region,
    /// so drop the partial first line. Returns the lines plus the 1-based
    /// document line number of the first returned line.
    static func cleanedChunkLines(_ text: String, startLine: Int) -> (lines: [String], firstLineNumber: Int) {
        var lines = text.components(separatedBy: "\n")
        var firstLineNumber = startLine
        if startLine > 1, lines.count > 1 {
            lines.removeFirst()
            firstLineNumber += 1
        }
        return (lines, firstLineNumber)
    }

    /// Prefixes every line with `"{number}: "`, starting at `startLine`.
    static func addLineNumbers(_ text: String, startLine: Int = 1) -> String {
        text.components(separatedBy: "\n").enumerated()
            .map { "\(startLine + $0.offset): \($0.element)" }
            .joined(separator: "\n")
    }

    /// Document title: the first `#`/`##` heading (skipping a bare "Notes"
    /// heading in favor of the first `##`), else the file's base name.
    static func extractTitle(_ content: String?, filename: String) -> String {
        if let content, let heading = firstMatch("^##?\\s+(.+)$", in: content) {
            let title = heading.trimmingCharacters(in: .whitespaces)
            if title == "📝 Notes" || title == "Notes",
               let next = firstMatch("^##\\s+(.+)$", in: content) {
                return next.trimmingCharacters(in: .whitespaces)
            }
            return title
        }
        let base = filename.split(separator: "/").last.map(String.init) ?? filename
        if let dot = base.lastIndex(of: "."), dot != base.startIndex {
            return String(base[..<dot])
        }
        return base
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

// MARK: - Terminal rendering

/// ANSI styling for the default CLI format. ShellKit sinks have no TTY
/// notion, so where the original gates on `isatty` this gates on the shell
/// environment: a terminal is assumed when `TERM` is set to something other
/// than "dumb". Colors additionally require `NO_COLOR` to be unset; OSC-8
/// hyperlinks (`links`) only need the terminal, mirroring the original where
/// `NO_COLOR` strips colors but leaves links alone.
struct Palette {
    let reset, dim, bold, cyan, yellow, green: String
    let enabled: Bool
    let links: Bool

    init(enabled: Bool, links: Bool = false) {
        self.enabled = enabled
        self.links = links
        reset = enabled ? "\u{1B}[0m" : ""
        dim = enabled ? "\u{1B}[2m" : ""
        bold = enabled ? "\u{1B}[1m" : ""
        cyan = enabled ? "\u{1B}[36m" : ""
        yellow = enabled ? "\u{1B}[33m" : ""
        green = enabled ? "\u{1B}[32m" : ""
    }

    static var shell: Palette {
        let environment = Shell.current.environment
        let isTerminal = environment["TERM"].map { $0 != "dumb" } ?? false
        return Palette(enabled: isTerminal && environment["NO_COLOR"] == nil, links: isTerminal)
    }

    /// Wraps `text` in an OSC-8 terminal hyperlink pointing at `url`.
    func link(_ text: String, to url: String) -> String {
        guard links else { return text }
        return "\u{1B}]8;;\(url)\u{7}\(text)\u{1B}]8;;\u{7}"
    }

    /// Score as a right-aligned percentage, colored by confidence:
    /// green ≥ 0.7, yellow ≥ 0.4, dim below.
    func score(_ value: Double) -> String {
        let pct = String(format: "%3.0f%%", value * 100)
        guard enabled else { return pct }
        if value >= 0.7 { return green + pct + reset }
        if value >= 0.4 { return yellow + pct + reset }
        return dim + pct + reset
    }

    /// Highlights query terms (3+ chars, case-insensitive) in yellow bold.
    func highlightTerms(_ text: String, query: String) -> String {
        guard enabled else { return text }
        var result = text
        for term in Snippet.queryTerms(query) where term.count >= 3 {
            let pattern = NSRegularExpression.escapedPattern(for: term)
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "\(yellow)\(bold)$0\(reset)")
        }
        return result
    }
}

/// Hyperlink target for a search hit: the `QMD_EDITOR_URI` template (with
/// `{path}`, `{line}` and `{col}` placeholders, like the original qmd's
/// `vscode://file/{path}:{line}:{col}`) when set, otherwise a plain local
/// file URL — which a host like iBash opens in its own file editor.
func editorURI(for absolutePath: String, line: Int) -> String {
    let fileURL = URL(fileURLWithPath: absolutePath)
    let template = Shell.current.environment["QMD_EDITOR_URI"]?
        .trimmingCharacters(in: .whitespaces) ?? ""
    guard !template.isEmpty else { return fileURL.absoluteString }
    let encoded = absolutePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? absolutePath
    let safeLine = String(max(1, line))
    return template
        .replacingOccurrences(of: "{path}", with: encoded)
        .replacingOccurrences(of: "{line}", with: safeLine)
        .replacingOccurrences(of: "{col}", with: "1")
        .replacingOccurrences(of: "{column}", with: "1")
}
