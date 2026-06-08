import Foundation
import Testing
@testable import QMDKit

@Suite struct OpenAIProviderTests {

    @Test func identifierReflectsModel() {
        let provider = OpenAIEmbeddingProvider(apiKey: "sk-test", model: "text-embedding-3-large")
        #expect(provider.embeddingModelIdentifier == "text-embedding-3-large")
    }

    /// Real call — only runs when `OPENAI_API_KEY` is present (CI/dev opt-in).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil))
    func realEmbeddingReturnsAVector() async throws {
        let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]!
        let provider = OpenAIEmbeddingProvider(apiKey: key)
        let vector = try await provider.embedding(for: "a feline resting in the sunshine")
        #expect((vector?.count ?? 0) >= 256)
    }
}
