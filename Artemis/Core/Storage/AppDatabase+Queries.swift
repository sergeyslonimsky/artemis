import Foundation
import GRDB

extension AppDatabase {
    // MARK: - Chats
    public func fetchChats() throws -> [Chat] {
        try dbWriter.read { db in
            try Chat.order(Chat.Columns.updatedAt.desc).fetchAll(db)
        }
    }

    public func fetchChat(id: String) throws -> Chat? {
        try dbWriter.read { db in
            try Chat.fetchOne(db, id: id)
        }
    }

    @discardableResult
    public func createChat(
        title: String,
        source: TitleSource = .placeholder,
        now: Date = Date()
    ) throws -> Chat {
        let chat = Chat(title: title, titleSource: source, createdAt: now, updatedAt: now)
        try dbWriter.write { db in
            try chat.insert(db)
        }
        return chat
    }

    public func setGeneratedTitle(chatId: String, title: String) throws -> Bool {
        try dbWriter.write { db in
            // Authoritative check: only overwrite placeholder, matching Artemis Go logic!
            try db.execute(
                sql: "UPDATE chats SET title = ?, title_source = 'generated' WHERE id = ? AND title_source = 'placeholder'",
                arguments: [title, chatId]
            )
            return db.changesCount > 0
        }
    }

    public func renameChat(chatId: String, title: String) throws {
        try dbWriter.write { db in
            try db.execute(
                sql: "UPDATE chats SET title = ?, title_source = 'manual' WHERE id = ?",
                arguments: [title, chatId]
            )
        }
    }

    public func deleteChat(id: String) throws {
        try dbWriter.write { db in
            _ = try Chat.deleteOne(db, id: id)
        }
    }

    // MARK: - Messages
    public func fetchMessages(chatId: String) throws -> [Message] {
        try dbWriter.read { db in
            var messages = try Message
                .filter(Message.Columns.chatId == chatId)
                .order(Message.Columns.createdAt.asc)
                .fetchAll(db)

            let attachments = try Attachment
                .filter(messages.map(\.id).contains(Attachment.Columns.messageId))
                .fetchAll(db)

            let byMessage = Dictionary(grouping: attachments, by: \.messageId)
            for i in 0..<messages.count {
                messages[i].attachments = byMessage[messages[i].id] ?? []
            }
            return messages
        }
    }

    public func addMessage(_ message: Message) throws {
        try dbWriter.write { db in
            try message.insert(db)

            // Touch chat updated_at
            let nowMillis = Int64(message.createdAt.timeIntervalSince1970 * 1000)
            try db.execute(
                sql: "UPDATE chats SET updated_at = ? WHERE id = ?",
                arguments: [nowMillis, message.chatId]
            )

            // Store attachments
            for var attachment in message.attachments {
                attachment.messageId = message.id
                if let data = attachment.data {
                    let fileURL = self.attachmentsDirectory.appendingPathComponent(attachment.id)
                    try data.write(to: fileURL)
                }
                try attachment.insert(db)
            }
        }
    }

    public func finishMessage(
        id: String,
        content: String,
        reasoning: String,
        stats: MessageStats?
    ) throws {
        try dbWriter.write { db in
            try db.execute(
                sql: """
                UPDATE messages
                SET content = ?, reasoning = ?, tokens = ?, tokens_estimated = ?, duration_ms = ?
                WHERE id = ?
                """,
                arguments: [
                    content,
                    reasoning,
                    stats?.tokens,
                    stats.map { $0.isEstimated ? 1 : 0 },
                    stats?.durationMs,
                    id
                ]
            )
        }
    }

    public func deleteMessage(id: String) throws {
        try dbWriter.write { db in
            _ = try Message.deleteOne(db, id: id)
        }
    }

    public func deleteMessagesFrom(chatId: String, messageId: String) throws {
        try dbWriter.write { db in
            try db.execute(
                sql: """
                DELETE FROM messages
                WHERE chat_id = ?
                  AND (created_at, id) >= (SELECT created_at, id FROM messages WHERE id = ?)
                """,
                arguments: [chatId, messageId]
            )
        }
    }

    // MARK: - Providers
    public func fetchProviders() throws -> [Provider] {
        try dbWriter.read { db in
            try Provider.order(Provider.Columns.createdAt.asc).fetchAll(db)
        }
    }

    public func saveProvider(_ provider: Provider) throws {
        try dbWriter.write { db in
            try provider.save(db)
        }
    }

    public func deleteProvider(id: String) throws {
        try dbWriter.write { db in
            _ = try Provider.deleteOne(db, id: id)
        }
    }

    // MARK: - Presets
    public func fetchPresets() throws -> [Preset] {
        try dbWriter.read { db in
            try Preset.order(Preset.Columns.createdAt.asc).fetchAll(db)
        }
    }

    public func savePreset(_ preset: Preset) throws {
        try dbWriter.write { db in
            try preset.save(db)
        }
    }

    public func deletePreset(id: String) throws {
        try dbWriter.write { db in
            _ = try Preset.deleteOne(db, id: id)
        }
    }

    // MARK: - Settings
    public func fetchSettings() throws -> AppSettings {
        try dbWriter.read { db in
            try AppSettings.fetchOne(db, id: 1) ?? AppSettings()
        }
    }

    public func saveSettings(_ settings: AppSettings) throws {
        try dbWriter.write { db in
            try settings.save(db)
        }
    }

    // MARK: - Search
    public func search(query: String, limit: Int = 50) throws -> [SearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }

        let matchQuery = buildFTSQuery(needle)

        return try dbWriter.read { db in
            let sql = """
            WITH best AS (
                SELECT m.chat_id         AS chat_id,
                       m.content         AS content,
                       max(m.created_at) AS at
                  FROM messages_fts
                  JOIN messages m ON m.rowid = messages_fts.rowid
                 WHERE ?1 <> '' AND messages_fts MATCH ?1
                 GROUP BY m.chat_id
            )
            SELECT c.id, c.title, c.title_source, c.created_at, c.updated_at, best.content
              FROM chats c
              LEFT JOIN best ON best.chat_id = c.id
             WHERE best.chat_id IS NOT NULL OR instr(lower(c.title), lower(?2)) > 0
             ORDER BY c.updated_at DESC
             LIMIT ?3
            """

            let rows = try Row.fetchAll(db, sql: sql, arguments: [matchQuery, needle, limit])
            return rows.map { row in
                let id: String = row["id"]
                let title: String = row["title"]
                let sourceRaw: String = row["title_source"]
                let createdMillis: Int64 = row["created_at"]
                let updatedMillis: Int64 = row["updated_at"]
                let content: String? = row["content"]

                let chat = Chat(
                    id: id,
                    title: title,
                    titleSource: TitleSource(rawValue: sourceRaw) ?? .placeholder,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(createdMillis) / 1000.0),
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(updatedMillis) / 1000.0)
                )

                let snippet = extractSnippet(from: content ?? "", query: needle)
                return SearchHit(chat: chat, snippet: snippet)
            }
        }
    }

    private func buildFTSQuery(_ raw: String) -> String {
        let tokens = raw.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return "" }
        // Each word as prefix token: "term"*
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    private func extractSnippet(from text: String, query: String, maxLength: Int = 140) -> String {
        guard !text.isEmpty else { return "" }
        let singleLine = text.replacingOccurrences(of: "\n", with: " ")
        if let range = singleLine.range(of: query, options: .caseInsensitive) {
            let startDistance = singleLine.distance(from: singleLine.startIndex, to: range.lowerBound)
            let prefixLength = max(0, startDistance - 30)
            let prefixIndex = singleLine.index(singleLine.startIndex, offsetBy: prefixLength)
            let snippetSubstring = singleLine[prefixIndex...]
            if snippetSubstring.count > maxLength {
                let endIdx = singleLine.index(prefixIndex, offsetBy: maxLength)
                return (prefixLength > 0 ? "…" : "") + String(singleLine[prefixIndex..<endIdx]) + "…"
            }
            return (prefixLength > 0 ? "…" : "") + String(snippetSubstring)
        }
        return String(singleLine.prefix(maxLength))
    }
}
