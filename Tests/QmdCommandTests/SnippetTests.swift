import Foundation
import Testing
@testable import QmdCommand

/// Unit tests for the snippet extraction + rendering helpers ported from the
/// original qmd (src/store.ts extractSnippet and the CLI formatters).
@Suite struct SnippetTests {

    /// Ten lines, one containing the query term on line 5.
    private let body = "one\ntwo\nthree\nfour\nfive cat\nsix\nseven\neight\nnine\nten"

    @Test func bestLineSelectionAndHeaderMath() {
        let result = Snippet.extract(body: body, query: "cat", region: 1 ... 10)
        #expect(result.line == 5)
        #expect(result.start == 4)
        #expect(result.header == "@@ -4,4 @@ (3 before, 3 after)")
        #expect(result.text == "four\nfive cat\nsix\nseven")
    }

    @Test func searchIsRestrictedToThePaddedRegion() {
        // The term sits on line 5; a region ending at line 2 only pads to
        // line 3, so the match is invisible and the chunk anchors instead…
        let early = Snippet.extract(body: body, query: "cat", region: 2 ... 3)
        #expect(early.line == 2)
        // …while a region whose padding reaches line 5 finds it.
        let touching = Snippet.extract(body: body, query: "cat", region: 2 ... 4)
        #expect(touching.line == 5)
    }

    @Test func documentOpeningChunkFallsBackToWholeDocument() {
        // No literal match in a chunk that opens the document → re-scan the
        // whole document; still no match → snippet anchors on line 1.
        let result = Snippet.extract(body: body, query: "zzz", region: 1 ... 4)
        #expect(result.line == 1)
        #expect(result.header == "@@ -1,3 @@ (0 before, 7 after)")
        #expect(result.text == "one\ntwo\nthree")
    }

    @Test func midDocumentChunkAnchorsOnChunkStart() {
        // Semantic hits often have no literal term; the chunk was actively
        // picked, so anchor the snippet on its first line.
        let result = Snippet.extract(body: body, query: "zzz", region: 6 ... 9)
        #expect(result.line == 6)
        #expect(result.header == "@@ -5,4 @@ (4 before, 2 after)")
        #expect(result.text == "five cat\nsix\nseven\neight")
    }

    @Test func intentTermsBreakTies() {
        let body = "alpha topic\nbeta topic billing\ngamma"
        let plain = Snippet.extract(body: body, query: "topic")
        #expect(plain.line == 1)   // tie → first match wins
        let steered = Snippet.extract(body: body, query: "topic", intent: "the billing area")
        #expect(steered.line == 2) // intent term tips the tie
    }

    @Test func longSnippetsAreTruncated() {
        let line = String(repeating: "x", count: 400)
        let result = Snippet.extract(body: "\(line)\n\(line) cat\n\(line)", query: "cat", maxLen: 500)
        #expect(result.text.count == 500)
        #expect(result.text.hasSuffix("..."))
    }

    @Test func chunkFallbackDropsThePartialOverlapLine() {
        // Chunks that don't open the document start mid-line inside the
        // chunker's overlap; the partial first line never reaches the snippet.
        let chunk = "rtial tail\nalpha cat\nbeta\ngamma"
        let result = Snippet.extractFromChunk(text: chunk, startLine: 87, query: "cat")
        #expect(!result.snippet.contains("rtial"))
        #expect(result.line == 88)
        #expect(result.header == "@@ -88,3 @@")
        #expect(result.text == "alpha cat\nbeta\ngamma")
    }

    @Test func chunkFallbackKeepsDocumentOpeningFirstLine() {
        let result = Snippet.extractFromChunk(text: "alpha\nbeta", startLine: 1, query: "beta")
        #expect(result.line == 2)
        #expect(result.text == "alpha\nbeta")
        #expect(result.header == "@@ -1,2 @@")
    }

    @Test func chunkFallbackAnchorsWithoutMatch() {
        let result = Snippet.extractFromChunk(text: "alpha\nbeta\ngamma\ndelta", startLine: 1, query: "zzz")
        #expect(result.line == 1)
        #expect(result.text == "alpha\nbeta\ngamma")
    }

    @Test func lineNumbering() {
        #expect(Snippet.addLineNumbers("a\nb") == "1: a\n2: b")
        #expect(Snippet.addLineNumbers("a\nb", startLine: 87) == "87: a\n88: b")
    }

    @Test func titleExtraction() {
        #expect(Snippet.extractTitle("# Hello World\n\nbody", filename: "a.md") == "Hello World")
        #expect(Snippet.extractTitle("intro\n\n## Section Two\n", filename: "a.md") == "Section Two")
        // A bare "Notes" heading defers to the first `##` heading.
        #expect(Snippet.extractTitle("# Notes\n\n## Real Topic\n", filename: "a.md") == "Real Topic")
        // No heading (or no readable document) → base name without extension.
        #expect(Snippet.extractTitle("just text", filename: "docs/my-file.md") == "my-file")
        #expect(Snippet.extractTitle(nil, filename: "docs/my-file.md") == "my-file")
    }

    @Test func paletteFormatsScores() {
        let plain = Palette(enabled: false)
        #expect(plain.score(1.0) == "100%")
        #expect(plain.score(0.964) == " 96%")
        #expect(plain.score(0.05) == "  5%")
        let colored = Palette(enabled: true)
        #expect(colored.score(0.9).contains("\u{1B}[32m"))   // green
        #expect(colored.score(0.5).contains("\u{1B}[33m"))   // yellow
        #expect(colored.score(0.1).contains("\u{1B}[2m"))    // dim
    }

    @Test func highlightingIsCaseInsensitiveAndSkipsShortTerms() {
        let colored = Palette(enabled: true)
        let highlighted = colored.highlightTerms("The Cat sat. An ox too.", query: "cat ox")
        #expect(highlighted.contains("\u{1B}[33m\u{1B}[1mCat\u{1B}[0m"))   // 3+ chars, case kept
        #expect(!highlighted.contains("\u{1B}[33m\u{1B}[1mox"))            // < 3 chars untouched
        let plain = Palette(enabled: false)
        #expect(plain.highlightTerms("The Cat sat.", query: "cat") == "The Cat sat.")
    }

    @Test func osc8LinkWrapping() {
        let linked = Palette(enabled: true, links: true).link("files/a.md:5", to: "file:///tmp/a.md")
        #expect(linked == "\u{1B}]8;;file:///tmp/a.md\u{7}files/a.md:5\u{1B}]8;;\u{7}")
        // Links off (the default) → plain text.
        #expect(Palette(enabled: true).link("files/a.md:5", to: "file:///tmp/a.md") == "files/a.md:5")
    }

    @Test func getLineSuffixParsing() {
        let range = Qmd.Get.lineSuffix(of: "files/a.md:100:40")
        #expect(range?.path == "files/a.md")
        #expect(range?.from == 100)
        #expect(range?.count == 40)
        let single = Qmd.Get.lineSuffix(of: "a.md:7")
        #expect(single?.path == "a.md")
        #expect(single?.from == 7)
        #expect(single?.count == nil)
        #expect(Qmd.Get.lineSuffix(of: "plain.md") == nil)
    }
}
