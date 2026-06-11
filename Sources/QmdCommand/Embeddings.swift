import Foundation
import Providers
import ShellKit
import SemanticStore

// The store-opening + embedding-backend selection are isolated here, away from
// the command-parsing files: SwiftAgents' `Providers` exports a `struct
// Argument` that would otherwise shadow ArgumentParser's `@Argument` property
// wrapper wherever both are imported.

extension StoreOptions {
    /// Opens the store, gating the index path through the host's sandbox first.
    func open() async throws -> SQLiteVectorStore {
        let index = Shell.resolve(indexPath)
        try await Shell.authorize(index)
        let directory = (index.path as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        return try SQLiteVectorStore(storage: .file(index.path), embeddingProvider: Self.embeddingProvider())
    }

    /// The embedding backend, in precedence order:
    /// 1. **Ollama** when `QMD_EMBED_BACKEND=ollama` — a local instruction-tuned
    ///    model (`QMD_EMBED_MODEL`, default `embeddinggemma`) served at
    ///    `OLLAMA_URL` (default `http://localhost:11434`). Wrapped in
    ///    `InstructionPrefixEmbeddingProvider` for known families so the
    ///    query/document prompt asymmetry is honored — with `embeddinggemma`
    ///    the vectors are compatible with a real qmd index.
    /// 2. **OpenAI** when `OPENAI_API_KEY` is set (`QMD_EMBED_MODEL` overrides
    ///    the model). Symmetric — no role prefixes.
    /// 3. Otherwise nil → the store's on-device Apple NaturalLanguage embedder.
    static func embeddingProvider() -> EmbeddingProvider? {
        let environment = Shell.current.environment

        if environment["QMD_EMBED_BACKEND"]?.lowercased() == "ollama" {
            let model = environment["QMD_EMBED_MODEL"] ?? "embeddinggemma"
            let host = environment["OLLAMA_URL"] ?? "http://localhost:11434"
            guard let url = URL(string: host) else { return nil }
            let ollama = OllamaAPI(endpointURL: url, versionPath: "v1")
            ollama.embeddingModelIdentifier = model
            guard let template = InstructionPrefixEmbeddingProvider.Template
                .matching(modelIdentifier: model) else { return ollama }
            return InstructionPrefixEmbeddingProvider(wrapping: ollama, template: template)
        }

        guard let key = environment["OPENAI_API_KEY"], !key.isEmpty else { return nil }
        let model = environment["QMD_EMBED_MODEL"] ?? "text-embedding-3-small"
        let openAI = OpenAI(apiKey: key)
        openAI.embeddingModelIdentifier = model
        return openAI
    }

    /// The query expander: an LLM-backed `lex`/`vec`/`hyde` generator when
    /// `OPENAI_API_KEY` is set (chat model via `QMD_CHAT_MODEL`, default
    /// `gpt-4o-mini`); otherwise the dependency-free template expander. Mirrors
    /// how `embeddingProvider()` selects its backend.
    static func queryExpander() -> QueryExpander {
        let environment = Shell.current.environment
        guard let key = environment["OPENAI_API_KEY"], !key.isEmpty else {
            return TemplateQueryExpander()
        }
        let model = environment["QMD_CHAT_MODEL"] ?? "gpt-4o-mini"
        return LLMQueryExpander { prompt in
            let openAI = OpenAI(apiKey: key)
            let response = try await openAI.createChatCompletion(
                model: model, messages: [ChatMessage(role: .user, content: .text(prompt))])
            return response.choices.first?.message.textContent ?? ""
        }
    }

    /// Human-readable embedding backend label for `qmd status`.
    static func embeddingBackendDescription() -> String {
        embeddingProvider()?.embeddingModelIdentifier ?? "Apple NaturalLanguage (on-device)"
    }
}
