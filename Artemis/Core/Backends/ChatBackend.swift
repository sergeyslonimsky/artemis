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

    public init(
        messages: [Message],
        systemPrompt: String? = nil,
        preset: Preset? = nil,
        usesAssistantPersona: Bool = true
    ) {
        self.messages = messages
        self.systemPrompt = systemPrompt
        self.preset = preset
        self.usesAssistantPersona = usesAssistantPersona
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
