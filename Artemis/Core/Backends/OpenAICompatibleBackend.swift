import Foundation

/// Any `/chat/completions` endpoint (OpenRouter, OpenAI, Mistral, …). The request shape
/// follows the provider's `ProviderCapabilities`.
struct OpenAICompatibleBackend: ChatBackend {
    let provider: Provider
    let model: String
    private let client: LLMClient

    init(provider: Provider, apiKey: String, model: String, session: URLSession = .shared) {
        self.provider = provider
        self.model = model
        self.client = LLMClient(baseUrl: provider.baseUrl, apiKey: apiKey, session: session)
    }

    var descriptor: BackendDescriptor {
        BackendDescriptor(kind: .cloud, providerId: provider.id, model: model)
    }

    func stream(_ turn: ChatTurn) -> AsyncThrowingStream<LLMEvent, Error> {
        let first = request(for: turn, includesPastAttachments: true)
        guard Self.hasPastAttachments(turn) else {
            return client.stream(request: first)
        }

        // Some models advertise image/file input but their upstream rejects it. If the provider
        // fails before any output, retry once with earlier attachments replaced by text notes.
        let retry = request(for: turn, includesPastAttachments: false)
        let client = client
        return .task { continuation in
            var producedOutput = false
            do {
                for try await event in client.stream(request: first) {
                    switch event {
                    case .content, .reasoning: producedOutput = true
                    default: break
                    }
                    continuation.yield(event)
                }
            } catch is LLMError where !producedOutput {
                for try await event in client.stream(request: retry) {
                    continuation.yield(event)
                }
            }
        }
    }

    private func request(for turn: ChatTurn, includesPastAttachments: Bool) -> LLMRequest {
        LLMRequest(
            model: model,
            messages: turn.messages,
            systemPrompt: turn.systemPrompt,
            preset: turn.preset,
            capabilities: provider.capabilities(for: model),
            webSearch: turn.allowsWebSearch && provider.supportsWebSearch(model: model),
            includesPastAttachments: includesPastAttachments
        )
    }

    /// Attachments on any user message before the one being answered.
    private static func hasPastAttachments(_ turn: ChatTurn) -> Bool {
        guard let latest = turn.messages.lastIndex(where: { $0.role == .user }) else { return false }
        return turn.messages[..<latest].contains { !$0.attachments.isEmpty }
    }
}
