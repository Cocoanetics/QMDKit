import Testing
@testable import QMDKit

@Suite struct QMDKitSmokeTests {

    /// Index two clearly distinct snippets, then prove the three query modes:
    /// FTS5 keyword, vec0 + on-device Apple NL semantic, and hybrid fusion.
    @Test func keywordAndSemanticSearch() async throws {
        let store = try SQLiteVectorStore(storage: .memory)   // default = Apple NL embedder

        try await store.indexText(
            "The cat dozed on the warm windowsill, basking in the afternoon sun.",
            path: "pets.md", source: "notes")
        try await store.indexText(
            "Quarterly revenue rose sharply on strong enterprise software sales.",
            path: "finance.md", source: "notes")

        // Keyword (FTS5 bm25) — deterministic, no model needed.
        let kw = try store.keywordSearch("revenue", topN: 5)
        #expect(kw.first?.path == "finance.md")

        // Semantic (vec0 cosine KNN over on-device Apple NL embeddings).
        let sem = try await store.search(text: "a feline relaxing in the sunshine", topN: 2)
        #expect(sem.first?.path == "pets.md")

        // Provenance / citation rendering.
        #expect(sem.first?.citation.hasPrefix("notes:pets.md:") == true)
    }
}
