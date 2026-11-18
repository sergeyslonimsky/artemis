import Foundation

struct SearchHit: Identifiable, Equatable, Sendable {
    var id: String { chat.id }
    var chat: Chat
    var snippet: String

    init(chat: Chat, snippet: String = "") {
        self.chat = chat
        self.snippet = snippet
    }
}
