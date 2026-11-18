import Foundation

/// One step of a streamed reply. Failures are thrown by the stream, never sent as events.
enum LLMEvent: Sendable, Equatable {
    case content(String)
    case reasoning(String)
    case done(tokens: Int, isEstimated: Bool, durationMs: Int)
    /// The on-device model started reading a personal-data source.
    case toolStarted(PersonalDataSource)
    /// The on-device model proposed an action for the user to confirm.
    case actionDraft(ActionDraft)
}

/// Failures reported by an OpenAI-compatible endpoint.
enum LLMError: LocalizedError, Equatable {
    case invalidURL
    /// A non-2xx response, with the provider's message when it sent one.
    case http(status: Int, message: String)
    /// An error sent mid-stream with HTTP 200 (e.g. OpenRouter's upstream failures).
    case provider(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "The provider's base URL isn't valid."
        case .http(_, let message): message
        case .provider(let message): message
        }
    }
}
