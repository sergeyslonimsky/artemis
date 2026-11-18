import Foundation

/// A model as listed by `/models`.
struct ModelInfo: Equatable, Sendable {
    var id: String
    var capabilities: [String]
}

/// Talks to an OpenAI-compatible endpoint: lists models and streams chat completions.
final class LLMClient: Sendable {
    let apiKey: String
    private let completionsURL: URL?
    private let modelsURL: URL?
    private let session: URLSession

    /// - Parameter baseUrl: the API root (`…/v1`); a full `…/chat/completions` URL is accepted too.
    init(baseUrl: String, apiKey: String, session: URLSession = .shared) {
        var root = baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespacesAndNewlines))
        if root.hasSuffix("/chat/completions") {
            root.removeLast("/chat/completions".count)
        }
        let rootURL = URL(string: root).flatMap { $0.scheme == nil ? nil : $0 }
        self.completionsURL = rootURL?.appending(path: "chat/completions")
        self.modelsURL = rootURL?.appending(path: "models")
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    // MARK: - Models

    func fetchModels() async throws -> [ModelInfo] {
        guard let modelsURL else { throw LLMError.invalidURL }
        let (data, response) = try await session.data(for: request(url: modelsURL))
        try Self.validate(response, body: { String(decoding: data, as: UTF8.self) })

        struct ModelsResponse: Decodable {
            struct Item: Decodable {
                let id: String
                /// Gateway extension, e.g. `["tools", "image_input"]`; absent on most providers.
                let capabilities: [String]?
            }
            let data: [Item]
        }

        return try JSONDecoder().decode(ModelsResponse.self, from: data).data
            .map { ModelInfo(id: $0.id, capabilities: $0.capabilities ?? []) }
            .sorted { $0.id < $1.id }
    }

    // MARK: - Streaming

    /// Server-sent events of `/chat/completions`, ending with `.done`. Failures are thrown as `LLMError`.
    func stream(request llmRequest: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        .task { [self] continuation in
            guard let completionsURL else { throw LLMError.invalidURL }
            var urlRequest = request(url: completionsURL)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try llmRequest.encodeToJSONData()

            let (bytes, response) = try await session.bytes(for: urlRequest)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                var body = ""
                for try await line in bytes.lines { body += line }
                try Self.validate(response, body: { body })
            }

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            var firstTokenTime: Date?
            var completionTokens: Int?
            var characters = 0

            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard let payload = Self.ssePayload(line) else { continue }
                if payload == "[DONE]" { break }
                guard let chunk = try? decoder.decode(WireChunk.self, from: Data(payload.utf8)) else { continue }

                if let error = chunk.error {
                    throw LLMError.provider(error.message ?? "The provider reported an error.")
                }
                if let usage = chunk.usage {
                    completionTokens = usage.completionTokens
                }
                guard let delta = chunk.choices?.first?.delta else { continue }
                firstTokenTime = firstTokenTime ?? Date()

                // Reasoning: OpenRouter sends `reasoning`, DeepSeek `reasoning_content`.
                if let reasoning = delta.reasoning ?? delta.reasoningContent, !reasoning.isEmpty {
                    continuation.yield(.reasoning(reasoning))
                }
                if let content = delta.content, !content.isEmpty {
                    characters += content.count
                    continuation.yield(.content(content))
                }
            }
            try Task.checkCancellation()

            let durationMs = max(1, Int(Date().timeIntervalSince(firstTokenTime ?? Date()) * 1000))
            continuation.yield(.done(
                tokens: completionTokens ?? TokenEstimate.tokens(forCharacters: characters),
                isEstimated: completionTokens == nil,
                durationMs: durationMs
            ))
        }
    }

    // MARK: - Helpers

    private func request(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Throws `LLMError.http` for a non-2xx response; the body is only read when needed.
    private static func validate(_ response: URLResponse, body: () -> String) throws {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200...299).contains(http.statusCode) else {
            throw LLMError.http(status: http.statusCode, message: errorMessage(from: body(), status: http.statusCode))
        }
    }

    /// The payload of an SSE `data:` line; `nil` for comments, keep-alives and other fields.
    private static func ssePayload(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return nil }
        return trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
    }

    /// The `error.message` of an OpenAI-style error body, or the raw body / status as a fallback.
    static func errorMessage(from body: String, status: Int) -> String {
        struct ErrorBody: Decodable {
            struct Detail: Decodable { let message: String? }
            let error: Detail?
        }
        if let message = (try? JSONDecoder().decode(ErrorBody.self, from: Data(body.utf8)))?.error?.message,
           !message.isEmpty {
            return "\(message) (HTTP \(status))"
        }
        return body.isEmpty ? "Server returned HTTP \(status)" : body
    }
}

/// Rough token counts for when a backend doesn't report usage.
enum TokenEstimate {
    /// About four characters per token for typical English text.
    static func tokens(forCharacters count: Int) -> Int {
        max(1, count / 4)
    }
}

// MARK: - Wire types

private struct WireChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
            let reasoning: String?
            let reasoningContent: String?
        }
        let delta: Delta
    }

    struct Usage: Decodable {
        let completionTokens: Int
    }

    struct WireError: Decodable {
        let message: String?
    }

    let choices: [Choice]?
    let usage: Usage?
    let error: WireError?
}
