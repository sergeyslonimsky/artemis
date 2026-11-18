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

    /// Emits the chat list, newest first, every time it changes.
    public func observeChats() -> AsyncValueObservation<[Chat]> {
        ValueObservation
            .tracking { db in try Chat.order(Chat.Columns.updatedAt.desc).fetchAll(db) }
            .removeDuplicates()
            .values(in: dbWriter)
    }

    /// Emits the chat (or `nil` once deleted) every time it changes.
    public func observeChat(id: String) -> AsyncValueObservation<Chat?> {
        ValueObservation
            .tracking { db in try Chat.fetchOne(db, id: id) }
            .removeDuplicates()
            .values(in: dbWriter)
    }

    /// - Parameter id: lets a draft chat keep the id the UI already uses for it.
    @discardableResult
    public func createChat(
        id: String = UUID().uuidString.lowercased(),
        title: String,
        source: TitleSource = .placeholder,
        routingMode: RoutingMode? = nil,
        providerId: String? = nil,
        model: String? = nil,
        now: Date = Date()
    ) throws -> Chat {
        let chat = Chat(
            id: id,
            title: title,
            titleSource: source,
            createdAt: now,
            updatedAt: now,
            providerId: providerId,
            model: model,
            routingMode: routingMode
        )
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

    public func setChatModel(chatId: String, providerId: String?, model: String?) throws {
        try dbWriter.write { db in
            try db.execute(
                sql: "UPDATE chats SET provider_id = ?, model = ? WHERE id = ?",
                arguments: [providerId, model, chatId]
            )
        }
    }

    public func setChatCloudAllowed(chatId: String, allowed: Bool) throws {
        try dbWriter.write { db in
            try db.execute(
                sql: "UPDATE chats SET cloud_allowed = ? WHERE id = ?",
                arguments: [allowed ? 1 : 0, chatId]
            )
        }
    }

    /// Unanswered cloud-consent prompts are dropped once the conversation moves on.
    public func deletePendingConsents(chatId: String) throws {
        try dbWriter.write { db in
            try db.execute(
                sql: "DELETE FROM messages WHERE chat_id = ? AND status = ?",
                arguments: [chatId, MessageStatus.awaitingConsent.rawValue]
            )
        }
    }

    public func setChatRoutingMode(chatId: String, mode: RoutingMode?) throws {
        try dbWriter.write { db in
            try db.execute(
                sql: "UPDATE chats SET routing_mode = ? WHERE id = ?",
                arguments: [mode?.rawValue, chatId]
            )
        }
    }

    public func deleteChat(id: String) throws {
        let attachmentIds = try dbWriter.write { db in
            let ids = try String.fetchAll(db, sql: """
                SELECT a.id FROM attachments a
                  JOIN messages m ON m.id = a.message_id
                 WHERE m.chat_id = ?
                """, arguments: [id])
            _ = try Chat.deleteOne(db, id: id)
            return ids
        }
        removeAttachmentFiles(ids: attachmentIds)
    }

    // MARK: - Messages
    /// Messages of a chat in conversation order.
    /// - Parameter includeAttachmentData: load attachment bytes from disk (needed to build LLM requests).
    public func fetchMessages(chatId: String, includeAttachmentData: Bool = false) throws -> [Message] {
        var messages = try dbWriter.read { db in
            try Self.fetchMessages(db, chatId: chatId)
        }
        if includeAttachmentData {
            for i in messages.indices {
                for j in messages[i].attachments.indices {
                    messages[i].attachments[j].data = loadAttachmentData(id: messages[i].attachments[j].id)
                }
            }
        }
        return messages
    }

    /// Emits the chat's messages (without attachment bytes) every time they change.
    public func observeMessages(chatId: String) -> AsyncValueObservation<[Message]> {
        ValueObservation
            .tracking { db in try Self.fetchMessages(db, chatId: chatId) }
            .removeDuplicates()
            .values(in: dbWriter)
    }

    private static func fetchMessages(_ db: Database, chatId: String) throws -> [Message] {
        var messages = try Message
            .filter(Message.Columns.chatId == chatId)
            .order(Message.Columns.seq.asc)
            .fetchAll(db)

        let attachments = try Attachment
            .filter(messages.map(\.id).contains(Attachment.Columns.messageId))
            .order(Attachment.Columns.createdAt.asc)
            .fetchAll(db)

        let byMessage = Dictionary(grouping: attachments, by: \.messageId)
        for i in messages.indices {
            messages[i].attachments = byMessage[messages[i].id] ?? []
        }
        return messages
    }

    /// Inserts the message at the end of its chat and returns it with the assigned `seq`.
    @discardableResult
    public func addMessage(_ message: Message) throws -> Message {
        // Files go to disk first so a committed row never points to a missing file.
        var written: [String] = []
        do {
            for attachment in message.attachments {
                if let data = attachment.data {
                    try data.write(to: attachmentURL(id: attachment.id), options: .atomic)
                    written.append(attachment.id)
                }
            }

            return try dbWriter.write { db in
                var message = message
                message.seq = try Int64.fetchOne(
                    db,
                    sql: "SELECT COALESCE(MAX(seq), 0) + 1 FROM messages WHERE chat_id = ?",
                    arguments: [message.chatId]
                ) ?? 1
                try message.insert(db)

                // Touch chat updated_at
                let nowMillis = Int64(message.createdAt.timeIntervalSince1970 * 1000)
                try db.execute(
                    sql: "UPDATE chats SET updated_at = ? WHERE id = ?",
                    arguments: [nowMillis, message.chatId]
                )

                for i in message.attachments.indices {
                    message.attachments[i].messageId = message.id
                    try message.attachments[i].insert(db)
                }
                return message
            }
        } catch {
            removeAttachmentFiles(ids: written)
            throw error
        }
    }

    public func finishMessage(
        id: String,
        content: String,
        reasoning: String,
        status: MessageStatus,
        error: String? = nil,
        stats: MessageStats?,
        extras: MessageExtras = MessageExtras()
    ) throws {
        let extrasJSON = extras.isEmpty ? nil : String(data: try JSONEncoder().encode(extras), encoding: .utf8)
        try dbWriter.write { db in
            try db.execute(
                sql: """
                UPDATE messages
                SET content = ?, reasoning = ?, status = ?, error = ?, extras = ?,
                    tokens = ?, tokens_estimated = ?, duration_ms = ?
                WHERE id = ?
                """,
                arguments: [
                    content,
                    reasoning,
                    status.rawValue,
                    error,
                    extrasJSON,
                    stats?.tokens,
                    stats.map { $0.isEstimated ? 1 : 0 },
                    stats?.durationMs,
                    id
                ]
            )
        }
    }

    public func setRouteReason(messageId: String, reason: RouteReason) throws {
        try dbWriter.write { db in
            try db.execute(
                sql: "UPDATE messages SET route_reason = ? WHERE id = ?",
                arguments: [reason.rawValue, messageId]
            )
        }
    }

    /// Marks a drafted event/reminder as added or dismissed.
    public func setDraftStatus(messageId: String, draftId: String, status: ActionDraft.Status) throws {
        try dbWriter.write { db in
            guard var message = try Message.fetchOne(db, id: messageId) else { return }
            guard let index = message.extras.drafts.firstIndex(where: { $0.id == draftId }) else { return }
            message.extras.drafts[index].status = status
            let json = String(data: try JSONEncoder().encode(message.extras), encoding: .utf8)
            try db.execute(sql: "UPDATE messages SET extras = ? WHERE id = ?", arguments: [json, messageId])
        }
    }

    /// Deletes the message and everything after it in the same chat.
    public func deleteMessagesFrom(chatId: String, messageId: String) throws {
        let attachmentIds = try dbWriter.write { db in
            let fromSeq = """
                (SELECT seq FROM messages WHERE id = ? AND chat_id = ?)
                """
            let ids = try String.fetchAll(db, sql: """
                SELECT a.id FROM attachments a
                  JOIN messages m ON m.id = a.message_id
                 WHERE m.chat_id = ? AND m.seq >= \(fromSeq)
                """, arguments: [chatId, messageId, chatId])
            try db.execute(
                sql: "DELETE FROM messages WHERE chat_id = ? AND seq >= \(fromSeq)",
                arguments: [chatId, messageId, chatId]
            )
            return ids
        }
        removeAttachmentFiles(ids: attachmentIds)
    }

    // MARK: - Attachment files
    public func attachmentURL(id: String) -> URL {
        attachmentsDirectory.appendingPathComponent(id)
    }

    public func loadAttachmentData(id: String) -> Data? {
        try? Data(contentsOf: attachmentURL(id: id))
    }

    private func removeAttachmentFiles(ids: [String]) {
        for id in ids {
            try? FileManager.default.removeItem(at: attachmentURL(id: id))
        }
    }

    // MARK: - Providers
    public func fetchProviders() throws -> [Provider] {
        try dbWriter.read { db in
            try Provider.order(Provider.Columns.createdAt.asc).fetchAll(db)
        }
    }

    public func observeSettings() -> AsyncValueObservation<AppSettings?> {
        ValueObservation
            .tracking { db in try AppSettings.fetchOne(db) }
            .removeDuplicates()
            .values(in: dbWriter)
    }

    public func observeProviders() -> AsyncValueObservation<[Provider]> {
        ValueObservation
            .tracking { db in try Provider.order(Provider.Columns.createdAt.asc).fetchAll(db) }
            .removeDuplicates()
            .values(in: dbWriter)
    }

    public func saveProvider(_ provider: Provider, apiKey: String) throws {
        try apiKeys.setAPIKey(apiKey, for: provider.id)
        try dbWriter.write { db in
            try provider.save(db)
        }
    }

    public func deleteProvider(id: String) throws {
        try dbWriter.write { db in
            _ = try Provider.deleteOne(db, id: id)
        }
        try apiKeys.deleteAPIKey(for: id)
    }

    public func apiKey(providerId: String) -> String {
        apiKeys.apiKey(for: providerId) ?? ""
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
