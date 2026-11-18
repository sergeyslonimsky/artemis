import Foundation

/// Any `/chat/completions` endpoint (OpenRouter, OpenAI, Mistral, …). The request shape
/// follows the provider's `ProviderCapabilities`.
public struct OpenAICompatibleBackend: ChatBackend {
    public let provider: Provider
    public let model: String
    private let client: LLMClient

    public init(provider: Provider, apiKey: String, model: String, session: URLSession = .shared) {
        self.provider = provider
        self.model = model
        self.client = LLMClient(baseUrl: provider.baseUrl, apiKey: apiKey, session: session)
    }

    public var descriptor: BackendDescriptor {
        BackendDescriptor(kind: .cloud, providerId: provider.id, model: model)
    }

    public func stream(_ turn: ChatTurn) -> AsyncThrowingStream<LLMEvent, Error> {
        let first = request(for: turn, includesPastAttachments: true)
        guard Self.hasPastAttachments(turn) else {
            return client.stream(request: first)
        }

        // Some models advertise image/file input but their upstream rejects it. If the request fails
        // before any output, retry once with earlier attachments replaced by text notes.
        let retry = request(for: turn, includesPastAttachments: false)
        let client = client
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var producedOutput = false
                    for try await event in client.stream(request: first) {
                        if case .error = event, !producedOutput {
                            for try await retried in client.stream(request: retry) {
                                continuation.yield(retried)
                            }
                            continuation.finish()
                            return
                        }
                        if case .content = event { producedOutput = true }
                        if case .reasoning = event { producedOutput = true }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func request(for turn: ChatTurn, includesPastAttachments: Bool) -> LLMRequest {
        var request = LLMRequest(
            model: model,
            messages: turn.messages,
            systemPrompt: turn.systemPrompt,
            preset: turn.preset,
            capabilities: provider.capabilities(for: model),
            webSearch: turn.allowsWebSearch && provider.supportsWebSearch(model: model)
        )
        request.includesPastAttachments = includesPastAttachments
        return request
    }

    /// Attachments on any user message before the one being answered.
    private static func hasPastAttachments(_ turn: ChatTurn) -> Bool {
        guard let latest = turn.messages.lastIndex(where: { $0.role == .user }) else { return false }
        return turn.messages[..<latest].contains { !$0.attachments.isEmpty }
    }
}
