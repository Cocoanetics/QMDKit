import Testing
@testable import QMDKit

@Suite struct ChunkerTests {

    @Test func smallDocumentIsOneChunk() {
        let chunks = LineChunker.chunk("# Title\n\nHello world.\n", maxChars: 2000)
        #expect(chunks.count == 1)
        #expect(chunks.first?.startLine == 1)
    }

    @Test func emptyIsNoChunks() {
        #expect(LineChunker.chunk("").isEmpty)
    }

    @Test func breaksAtHeadingBoundaries() {
        func section(_ title: String) -> String { "## \(title)\n\n" + String(repeating: "word ", count: 25) + "\n" }
        let doc = "# Doc\n\n" + section("Alpha") + "\n" + section("Beta") + "\n" + section("Gamma")

        let chunks = LineChunker.chunk(doc, maxChars: 150, overlapChars: 0, windowChars: 130)
        #expect(chunks.count >= 2)
        // A chunk that follows a break begins exactly at a heading's newline —
        // the scored break-point logic chose the heading over weaker breaks.
        #expect(chunks.dropFirst().contains { $0.text.hasPrefix("## ") })
    }

    @Test func neverSplitsInsideACodeFence() {
        let doc = "Alpha paragraph that is reasonably wordy to take up space here.\n\n"
            + "```\nx = 1\n\ny = 2\n```\n\n"
            + "Omega paragraph that is also reasonably wordy down here.\n"

        // The blank line *inside* the fence scores like a paragraph break (20),
        // but fence protection must keep the code body together.
        let chunks = LineChunker.chunk(doc, maxChars: 70, overlapChars: 0, windowChars: 70)
        let body = chunks.first { $0.text.contains("x = 1") }
        #expect(body != nil)
        #expect(body?.text.contains("y = 2") == true)
    }

    @Test func lineSpansCoverTheDocument() {
        let doc = "L1\nL2\nL3\nL4\nL5\n"
        let chunks = LineChunker.chunk(doc, maxChars: 6, overlapChars: 0)
        #expect(chunks.first?.startLine == 1)
        #expect(chunks.last?.endLine == 5)
        for index in chunks.indices.dropFirst() {
            #expect(chunks[index].startLine >= chunks[index - 1].startLine)
        }
    }

    @Test func chunksOverlapAcrossLines() {
        let doc = (1 ... 40).map { "Sentence number \($0) with a handful of words." }
            .joined(separator: "\n") + "\n"
        let chunks = LineChunker.chunk(doc, maxChars: 200, overlapChars: 60)
        #expect(chunks.count >= 2)
        #expect(chunks.first?.startLine == 1)
        #expect((chunks.last?.endLine ?? 0) >= 40)
        // Consecutive chunks overlap: each begins at or before the previous one's last line.
        for index in chunks.indices.dropFirst() {
            #expect(chunks[index].startLine <= chunks[index - 1].endLine)
        }
    }
}
