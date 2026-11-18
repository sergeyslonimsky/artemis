import Foundation

/// A provider-agnostic request for one assistant turn.
struct ChatTurn: Sendable {
    /// Conversation history in order, ending with the message to answer.
    var messages: [Message]
    var systemPrompt: String?
    var preset: Preset?
    /// `false` for utility requests (titles, classification): the backend uses `systemPrompt`
    /// alone instead of wrapping it in the assistant persona.
    var usesAssistantPersona: Bool
    /// Utility requests never need the internet; skipping search keeps them fast and cheap.
    var allowsWebSearch: Bool
    /// Chat and reply ids for a conversational turn, letting a backend keep state between turns
    /// (the on-device model reuses its session). `nil` for one-off utility requests.
    var conversationId: String?
    var replyId: String?
    /// On-device tools the model may use for this turn.
    var toolGroups: Set<ToolGroup> = []

    init(
        messages: [Message],
        systemPrompt: String? = nil,
        preset: Preset? = nil,
        usesAssistantPersona: Bool = true,
        allowsWebSearch: Bool = true
    ) {
        self.messages = messages
        self.systemPrompt = systemPrompt
        self.preset = preset
        self.usesAssistantPersona = usesAssistantPersona
        self.allowsWebSearch = allowsWebSearch
    }
}

/// Identifies who generates a reply; persisted on the assistant message.
struct BackendDescriptor: Equatable, Sendable {
    var kind: BackendKind
    var providerId: String?
    var model: String?
}

/// Something that can stream an assistant reply: a cloud provider or the on-device model.
protocol ChatBackend: Sendable {
    var descriptor: BackendDescriptor { get }
    func stream(_ turn: ChatTurn) -> AsyncThrowingStream<LLMEvent, Error>
}
