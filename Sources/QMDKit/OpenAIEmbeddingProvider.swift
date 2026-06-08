//
//  OpenAIEmbeddingProvider.swift
//  QMDKit
//
//  A minimal `EmbeddingProvider` over OpenAI's `/v1/embeddings` endpoint —
//  self-contained (URLSession + Codable), so QMDKit gains OpenAI embeddings
//  without depending on the whole SwiftAgents/Providers closure. The qmd CLI
//  selects it automatically when `OPENAI_API_KEY` is set; the on-device Apple
//  `ContextualEmbeddingProvider` remains the default otherwise.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Errors surfaced by ``OpenAIEmbeddingProvider``.
public enum OpenAIEmbeddingError: Error, CustomStringConvertible {
    case http(status: Int, body: String)
    case malformedResponse

    public var description: String {
        switch self {
            case let .http(status, body): return "OpenAI embeddings HTTP \(status): \(body)"
            case .malformedResponse:      return "OpenAI embeddings: malformed response"
        }
    }
}

/// Embeds text via OpenAI's embeddings API (default model
/// `text-embedding-3-small`, 1536 dimensions).
public final class OpenAIEmbeddingProvider: EmbeddingProvider {
    public var embeddingModelIdentifier: String

    private let apiKey: String
    private let endpoint: URL
    private let session: URLSession

    public init(apiKey: String,
                model: String = "text-embedding-3-small",
                baseURL: URL = URL(string: "https://api.openai.com/v1")!,
                session: URLSession = .shared) {
        self.apiKey = apiKey
        self.embeddingModelIdentifier = model
        self.endpoint = baseURL.appendingPathComponent("embeddings")
        self.session = session
    }

    private struct EmbeddingRequest: Encodable { let model: String; let input: String }
    private struct EmbeddingResponse: Decodable {
        struct Item: Decodable { let embedding: [Double] }
        let data: [Item]
    }

    public func embedding(for text: String) async throws -> Vector? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            EmbeddingRequest(model: embeddingModelIdentifier, input: text))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenAIEmbeddingError.malformedResponse }
        guard http.statusCode == 200 else {
            throw OpenAIEmbeddingError.http(status: http.statusCode,
                                            body: String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(EmbeddingResponse.self, from: data).data.first?.embedding
    }
}
