import Foundation
import Providers
import ShellKit
import VectorStore

/// A batch reranker: one chat call scores every candidate, so reranking a
/// shortlist costs a single request (OpenAI has no cross-encoder endpoint). It's
/// LLM-scored rather than a true cross-encoder — best-effort precision over the
/// already-fused shortlist. A passage whose score fails to parse keeps its fusion
/// rank via the engine's position-aware blend, so a flaky reply degrades cleanly.
struct OpenAIBatchReranker: Reranker {
    let key: String
    let model: String

    func scores(query: String, candidates: [String], intent: String?) async throws -> [Double] {
        guard !candidates.isEmpty else { return [] }

        let rerankQuery: String
        if let intent, !intent.isEmpty {
            rerankQuery = "\(intent)\n\n\(query)"
        } else {
            rerankQuery = query
        }

        let passages = candidates.enumerated()
            .map { "[\($0.offset + 1)] \($0.element.prefix(800))" }
            .joined(separator: "\n\n")
        let prompt = """
        Score how well each passage answers the query, from 0 to 100. Reply with \
        exactly one line per passage as "N: SCORE" (N is the passage number) and \
        nothing else.
        Query: \(rerankQuery)

        Passages:
        \(passages)
        """

        let openAI = OpenAI(apiKey: key)
        let response = try await openAI.createChatCompletion(
            model: model, messages: [ChatMessage(role: .user, content: .text(prompt))])
        return Self.parse(response.choices.first?.message.textContent ?? "", count: candidates.count)
    }

    /// Parses `N: SCORE` lines into a 0…1 score per candidate (missing → 0).
    static func parse(_ text: String, count: Int) -> [Double] {
        var scores = [Double](repeating: 0, count: count)
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  let index = Int(String(parts[0].filter(\.isNumber))), index >= 1, index <= count,
                  let value = Double(parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
            scores[index - 1] = max(0, min(1, value / 100))
        }
        return scores
    }
}

extension StoreOptions {
    /// A batch LLM reranker when `OPENAI_API_KEY` is set (chat model via
    /// `QMD_CHAT_MODEL`, default `gpt-4o-mini`); otherwise nil — reranking is
    /// skipped on-device, same gate as the expander.
    static func reranker() -> Reranker? {
        let environment = Shell.current.environment
        guard let key = environment["OPENAI_API_KEY"], !key.isEmpty else { return nil }
        let model = environment["QMD_CHAT_MODEL"] ?? "gpt-4o-mini"
        return OpenAIBatchReranker(key: key, model: model)
    }
}
