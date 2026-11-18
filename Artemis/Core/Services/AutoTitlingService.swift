import Foundation

public actor AutoTitlingService {
    private let database: AppDatabase

    public init(database: AppDatabase = .shared) {
        self.database = database
    }

    public func generateTitleIfNeeded(
        chatId: String,
        userPrompt: String,
        assistantReply: String,
        backend: any ChatBackend
    ) async {
        // First check if chat is still a placeholder
        guard let chat = try? database.fetchChat(id: chatId),
              chat.titleSource == .placeholder else {
            return
        }

        let truncatedPrompt = String(userPrompt.prefix(600))
        let truncatedReply = String(assistantReply.prefix(600))

        let titlePrompt = """
        Summarize this conversation into a concise title of 2 to 4 words. Return ONLY the title. No quotes, no markdown, no punctuation at the end.

        User: \(truncatedPrompt)
        Assistant: \(truncatedReply)
        """

        let turn = ChatTurn(
            messages: [Message(chatId: chatId, role: .user, content: titlePrompt)],
            systemPrompt: "You write short, descriptive titles for chat conversations.",
            usesAssistantPersona: false,
            allowsWebSearch: false
        )

        var accumulated = ""
        do {
            for try await event in backend.stream(turn) {
                if case .content(let text) = event {
                    accumulated += text
                }
            }
            let cleaned = cleanTitle(accumulated)
            if !cleaned.isEmpty {
                _ = try database.setGeneratedTitle(chatId: chatId, title: cleaned)
            }
        } catch {
            // Title generation failure is non-fatal: placeholder remains
        }
    }

    private func cleanTitle(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("Title:") {
            text = String(text.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`«»."))
        // Reject whole sentences or paragraphs (matching Artemis cleanTitle rule)
        if text.count > 60 || text.contains("\n") {
            return ""
        }
        return text
    }
}
