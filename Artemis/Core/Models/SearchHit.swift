import Foundation

public struct SearchHit: Identifiable, Equatable, Sendable {
    public var id: String { chat.id }
    public var chat: Chat
    public var snippet: String

    public init(chat: Chat, snippet: String = "") {
        self.chat = chat
        self.snippet = snippet
    }
}
