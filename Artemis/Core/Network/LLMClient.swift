import Foundation

public final class LLMClient: Sendable {
    public let baseUrl: String
    public let apiKey: String
    private let session: URLSession

    public init(baseUrl: String, apiKey: String, session: URLSession = .shared) {
        self.baseUrl = baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    private var completionsURL: URL? {
        if baseUrl.hasSuffix("/chat/completions") {
            return URL(string: baseUrl)
        }
        return URL(string: "\(baseUrl)/chat/completions")
    }

    private var modelsURL: URL? {
        var root = baseUrl
        if root.hasSuffix("/chat/completions") {
            root = String(root.dropLast("/chat/completions".count))
        }
        return URL(string: "\(root)/models")
    }

    // MARK: - Fetch Models
    public func fetchModels() async throws -> [String] {
        guard let url = modelsURL else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Failed to fetch models"
            throw NSError(domain: "LLMClient", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: message])
        }

        struct ModelsResponse: Decodable {
            struct ModelItem: Decodable {
                let id: String
            }
            let data: [ModelItem]
        }

        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return decoded.data.map(\.id).sorted()
    }

    // MARK: - Streaming
    public func stream(request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = self.completionsURL else {
                        throw URLError(.badURL)
                    }

                    var urlRequest = URLRequest(url: url)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if !self.apiKey.isEmpty {
                        urlRequest.setValue("Bearer \(self.apiKey)", forHTTPHeaderField: "Authorization")
                    }
                    urlRequest.httpBody = try request.encodeToJSONData()

                    let (bytes, response) = try await self.session.bytes(for: urlRequest)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw URLError(.badServerResponse)
                    }

                    if !(200...299).contains(httpResponse.statusCode) {
                        var errorBody = ""
                        for try await line in bytes.lines {
                            errorBody += line
                        }
                        continuation.yield(.error(errorBody.isEmpty ? "Server returned HTTP \(httpResponse.statusCode)" : errorBody))
                        continuation.finish()
                        return
                    }

                    var firstTokenTime: Date?
                    var totalTokens = 0
                    var tokenEstimated = true
                    var accumulatedText = ""

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }

                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("data:") else { continue }

                        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" {
                            break
                        }

                        guard let data = payload.data(using: .utf8) else { continue }
                        guard let chunk = try? JSONDecoder().decode(WireChunk.self, from: data) else { continue }

                        // Extract usage if available
                        if let usage = chunk.usage {
                            totalTokens = usage.completionTokens
                            tokenEstimated = false
                        }

                        guard let choice = chunk.choices?.first else { continue }

                        // Timing starts from the first fragment (content or reasoning)
                        if firstTokenTime == nil {
                            firstTokenTime = Date()
                        }

                        // Reasoning delta (DeepSeek / OpenRouter)
                        let reasoning = choice.delta.reasoning ?? choice.delta.reasoningContent
                        if let reasoning = reasoning, !reasoning.isEmpty {
                            continuation.yield(.reasoning(reasoning))
                        }

                        // Content delta
                        if let content = choice.delta.content, !content.isEmpty {
                            accumulatedText += content
                            continuation.yield(.content(content))
                        }
                    }

                    let startTime = firstTokenTime ?? Date()
                    let durationMs = max(1, Int(Date().timeIntervalSince(startTime) * 1000))

                    if tokenEstimated {
                        // Character-based fallback: ~4 chars per token
                        totalTokens = max(1, accumulatedText.count / 4)
                    }

                    continuation.yield(.done(
                        tokens: totalTokens,
                        isEstimated: tokenEstimated,
                        durationMs: durationMs
                    ))
                    continuation.finish()
                } catch {
                    if !Task.isCancelled {
                        continuation.finish(throwing: error)
                    } else {
                        continuation.finish()
                    }
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}

// MARK: - Chunk Decodables
private struct WireChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
            let reasoning: String?
            let reasoningContent: String?

            enum CodingKeys: String, CodingKey {
                case content, reasoning
                case reasoningContent = "reasoning_content"
            }
        }
        let delta: Delta
    }

    struct Usage: Decodable {
        let promptTokens: Int
        let completionTokens: Int

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }

    let choices: [Choice]?
    let usage: Usage?
}
