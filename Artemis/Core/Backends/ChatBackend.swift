import Foundation

/// A provider-agnostic request for one assistant turn.
public struct ChatTurn: Sendable {
    /// Conversation history in order, ending with the message to answer.
    public var messages: [Message]
    public var systemPrompt: String?
    public var preset: Preset?
    /// `false` for utility requests (titles, classification): the backend uses `systemPrompt`
    /// alone instead of wrapping it in the assistant persona.
    public var usesAssistantPersona: Bool
    /// Utility requests never need the internet; skipping search keeps them fast and cheap.
    public var allowsWebSearch: Bool
    /// Chat and reply ids for a conversational turn, letting a backend keep state between turns
    /// (the on-device model reuses its session). `nil` for one-off utility requests.
    public var conversationId: String?
    public var replyId: String?
    /// On-device tools the model may use for this turn.
    public var toolGroups: Set<ToolGroup> = []

    public init(
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
public struct BackendDescriptor: Equatable, Sendable {
    public var kind: BackendKind
    public var providerId: String?
    public var model: String?

    public init(kind: BackendKind, providerId: String? = nil, model: String? = nil) {
        self.kind = kind
        self.providerId = providerId
        self.model = model
    }
}

/// Something that can stream an assistant reply: a cloud provider or the on-device model.
public protocol ChatBackend: Sendable {
    var descriptor: BackendDescriptor { get }
    func stream(_ turn: ChatTurn) -> AsyncThrowingStream<LLMEvent, Error>
}
