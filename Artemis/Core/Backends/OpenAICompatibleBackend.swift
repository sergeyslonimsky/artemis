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
        client.stream(request: LLMRequest(
            model: model,
            messages: turn.messages,
            systemPrompt: turn.systemPrompt,
            preset: turn.preset,
            capabilities: provider.capabilities,
            webSearch: turn.allowsWebSearch && provider.supportsWebSearch(model: model)
        ))
    }
}
