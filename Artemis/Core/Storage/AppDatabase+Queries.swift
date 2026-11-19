import Foundation
import GRDB

extension AppDatabase {
    // MARK: - Chats

    func fetchChats() throws -> [Chat] {
        try dbWriter.read { db in try Self.chatsNewestFirst.fetchAll(db) }
    }

    func fetchChat(id: String) throws -> Chat? {
        try dbWriter.read { db in try Chat.fetchOne(db, id: id) }
    }

    /// Emits the chat list, newest first, every time it changes.
    func observeChats() -> AsyncValueObservation<[Chat]> {
        observe { db in try Self.chatsNewestFirst.fetchAll(db) }
    }

    /// Emits the chat (or `nil` once deleted) every time it changes.
    func observeChat(id: String) -> AsyncValueObservation<Chat?> {
        observe { db in try Chat.fetchOne(db, id: id) }
    }

    private static var chatsNewestFirst: QueryInterfaceRequest<Chat> {
        Chat.order(Chat.Columns.updatedAt.desc)
    }

    /// - Parameter id: lets a draft chat keep the id the UI already uses for it.
    @discardableResult
    func createChat(
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
        try dbWriter.write { db in try chat.insert(db) }
        return chat
    }

    /// Sets a generated title unless the chat was titled since (by the user or another generation).
    /// Returns whether the title was set.
    @discardableResult
    func setGeneratedTitle(chatId: String, title: String) throws -> Bool {
        try dbWriter.write { db in
            try Chat
                .filter(id: chatId)
                .filter(Chat.Columns.titleSource == TitleSource.placeholder.rawValue)
                .updateAll(db, Chat.Columns.title.set(to: title), Chat.Columns.titleSource.set(to: TitleSource.generated.rawValue)) > 0
        }
    }

    func renameChat(chatId: String, title: String) throws {
        try updateChat(chatId, Chat.Columns.title.set(to: title), Chat.Columns.titleSource.set(to: TitleSource.manual.rawValue))
    }

    func setChatModel(chatId: String, providerId: String?, model: String?) throws {
        try updateChat(chatId, Chat.Columns.providerId.set(to: providerId), Chat.Columns.model.set(to: model))
    }

    func setChatCloudAllowed(chatId: String, allowed: Bool) throws {
        try updateChat(chatId, Chat.Columns.cloudAllowed.set(to: allowed))
    }

    func setChatRoutingMode(chatId: String, mode: RoutingMode?) throws {
        try updateChat(chatId, Chat.Columns.routingMode.set(to: mode?.rawValue))
    }

    private func updateChat(_ chatId: String, _ assignments: ColumnAssignment...) throws {
        try dbWriter.write { db in
            _ = try Chat.filter(id: chatId).updateAll(db, assignments)
        }
    }

    func deleteChat(id: String) throws {
        let attachmentIds = try dbWriter.write { db in
            let ids = try Self.attachmentIds(db, of: Message.filter(Message.Columns.chatId == id))
            _ = try Chat.deleteOne(db, id: id)
            return ids
        }
        removeAttachmentFiles(ids: attachmentIds)
    }

    // MARK: - Messages

    /// Messages of a chat in conversation order.
    /// - Parameter includeAttachmentData: load attachment bytes from disk (needed to build LLM requests).
    func fetchMessages(chatId: String, includeAttachmentData: Bool = false) throws -> [Message] {
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
    func observeMessages(chatId: String) -> AsyncValueObservation<[Message]> {
        observe { db in try Self.fetchMessages(db, chatId: chatId) }
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
    func addMessage(_ message: Message) throws -> Message {
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
                let lastSeq = try Message
                    .filter(Message.Columns.chatId == message.chatId)
                    .select(max(Message.Columns.seq), as: Int64.self)
                    .fetchOne(db)
                message.seq = (lastSeq ?? 0) + 1
                try message.insert(db)

                try Chat.filter(id: message.chatId)
                    .updateAll(db, Chat.Columns.updatedAt.set(to: message.createdAt.databaseMilliseconds))

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

    func finishMessage(
        id: String,
        content: String,
        reasoning: String,
        status: MessageStatus,
        error: String? = nil,
        stats: MessageStats?,
        extras: MessageExtras = MessageExtras()
    ) throws {
        let extrasJSON = try Message.databaseJSON(extras)
        try dbWriter.write { db in
            _ = try Message.filter(id: id).updateAll(db, [
                Message.Columns.content.set(to: content),
                Message.Columns.reasoning.set(to: reasoning),
                Message.Columns.status.set(to: status.rawValue),
                Message.Columns.error.set(to: error),
                Message.Columns.extras.set(to: extrasJSON),
                Message.Columns.tokens.set(to: stats?.tokens),
                Message.Columns.tokensEstimated.set(to: stats?.isEstimated),
                Message.Columns.durationMs.set(to: stats?.durationMs),
            ])
        }
    }

    func setRouteReason(messageId: String, reason: RouteReason) throws {
        try dbWriter.write { db in
            _ = try Message.filter(id: messageId).updateAll(db, Message.Columns.routeReason.set(to: reason.rawValue))
        }
    }

    /// Records whether the user confirmed or dismissed a drafted action.
    func setDraftStatus(messageId: String, draftId: String, status: ActionDraft.Status) throws {
        try dbWriter.write { db in
            guard var message = try Message.fetchOne(db, id: messageId),
                  let index = message.extras.drafts.firstIndex(where: { $0.id == draftId }) else { return }
            message.extras.drafts[index].status = status
            _ = try Message.filter(id: messageId)
                .updateAll(db, Message.Columns.extras.set(to: try Message.databaseJSON(message.extras)))
        }
    }

    /// Unanswered cloud-consent prompts are dropped once the conversation moves on.
    func deletePendingConsents(chatId: String) throws {
        try dbWriter.write { db in
            _ = try Message
                .filter(Message.Columns.chatId == chatId)
                .filter(Message.Columns.status == MessageStatus.awaitingConsent.rawValue)
                .deleteAll(db)
        }
    }

    /// Deletes the message and everything after it in the same chat.
    func deleteMessagesFrom(chatId: String, messageId: String) throws {
        let attachmentIds = try dbWriter.write { db -> [String] in
            guard let from = try Message.fetchOne(db, id: messageId), from.chatId == chatId else { return [] }
            let doomed = Message
                .filter(Message.Columns.chatId == chatId)
                .filter(Message.Columns.seq >= from.seq)
            let ids = try Self.attachmentIds(db, of: doomed)
            _ = try doomed.deleteAll(db)
            return ids
        }
        removeAttachmentFiles(ids: attachmentIds)
    }

    private static func attachmentIds(_ db: Database, of messages: QueryInterfaceRequest<Message>) throws -> [String] {
        let messageIds = try messages.select(Message.Columns.id, as: String.self).fetchAll(db)
        return try Attachment
            .filter(messageIds.contains(Attachment.Columns.messageId))
            .select(Attachment.Columns.id, as: String.self)
            .fetchAll(db)
    }

    /// Stores what OCR found in an image attachment (empty when nothing).
    func setRecognizedText(_ text: String, attachmentId: String) throws {
        try dbWriter.write { db in
            _ = try Attachment.filter(id: attachmentId)
                .updateAll(db, Attachment.Columns.recognizedText.set(to: text))
        }
    }

    // MARK: - Attachment files

    func attachmentURL(id: String) -> URL {
        attachmentsDirectory.appending(path: id)
    }

    func loadAttachmentData(id: String) -> Data? {
        try? Data(contentsOf: attachmentURL(id: id))
    }

    private func removeAttachmentFiles(ids: [String]) {
        for id in ids {
            try? FileManager.default.removeItem(at: attachmentURL(id: id))
        }
    }

    // MARK: - Providers

    func fetchProviders() throws -> [Provider] {
        try dbWriter.read { db in try Self.providersOldestFirst.fetchAll(db) }
    }

    func observeProviders() -> AsyncValueObservation<[Provider]> {
        observe { db in try Self.providersOldestFirst.fetchAll(db) }
    }

    private static var providersOldestFirst: QueryInterfaceRequest<Provider> {
        Provider.order(Provider.Columns.createdAt.asc)
    }

    /// Cloud models of the most recently active chats, newest first.
    func recentModels(limit: Int = 5) throws -> [ModelRef] {
        try dbWriter.read { db in
            try Chat
                .filter(Chat.Columns.providerId != nil && Chat.Columns.model != nil && Chat.Columns.model != "")
                .select(Chat.Columns.providerId, Chat.Columns.model)
                .group(Chat.Columns.providerId, Chat.Columns.model)
                .order(max(Chat.Columns.updatedAt).desc)
                .limit(limit)
                .asRequest(of: Row.self)
                .fetchAll(db)
                .map { ModelRef(providerId: $0[Chat.Columns.providerId], model: $0[Chat.Columns.model]) }
        }
    }

    func saveProvider(_ provider: Provider, apiKey: String) throws {
        try apiKeys.setAPIKey(apiKey, for: provider.id)
        try dbWriter.write { db in try provider.save(db) }
    }

    func deleteProvider(id: String) throws {
        try dbWriter.write { db in _ = try Provider.deleteOne(db, id: id) }
        try apiKeys.deleteAPIKey(for: id)
    }

    func apiKey(providerId: String) -> String {
        apiKeys.apiKey(for: providerId) ?? ""
    }

    // MARK: - Presets

    func fetchPresets() throws -> [Preset] {
        try dbWriter.read { db in try Self.presetsOldestFirst.fetchAll(db) }
    }

    func observePresets() -> AsyncValueObservation<[Preset]> {
        observe { db in try Self.presetsOldestFirst.fetchAll(db) }
    }

    private static var presetsOldestFirst: QueryInterfaceRequest<Preset> {
        Preset.order(Preset.Columns.createdAt.asc)
    }

    func savePreset(_ preset: Preset) throws {
        try dbWriter.write { db in try preset.save(db) }
    }

    func deletePreset(id: String) throws {
        try dbWriter.write { db in _ = try Preset.deleteOne(db, id: id) }
    }

    // MARK: - Settings

    func fetchSettings() throws -> AppSettings {
        try dbWriter.read { db in try AppSettings.fetchOne(db, id: 1) ?? AppSettings() }
    }

    /// Emits the settings every time they change.
    func observeSettings() -> AsyncValueObservation<AppSettings> {
        observe { db in try AppSettings.fetchOne(db, id: 1) ?? AppSettings() }
    }

    func saveSettings(_ settings: AppSettings) throws {
        try dbWriter.write { db in try settings.save(db) }
    }

    // MARK: - Search

    func search(query: String, limit: Int = 50) throws -> [SearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }

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
            SELECT c.*, best.content AS matched_content
              FROM chats c
              LEFT JOIN best ON best.chat_id = c.id
             WHERE best.chat_id IS NOT NULL OR instr(lower(c.title), lower(?2)) > 0
             ORDER BY c.updated_at DESC
             LIMIT ?3
            """
            return try Row.fetchAll(db, sql: sql, arguments: [Self.ftsQuery(needle), needle, limit]).map { row in
                let content: String? = row["matched_content"]
                return SearchHit(chat: try Chat(row: row), snippet: Self.snippet(from: content ?? "", query: needle))
            }
        }
    }

    /// Each word as a quoted prefix token: `"term"*`.
    private static func ftsQuery(_ raw: String) -> String {
        raw.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map { "\"\($0)\"*" }
            .joined(separator: " ")
    }

    /// A single-line excerpt around the first match, or the start of the text.
    private static func snippet(from text: String, query: String, maxLength: Int = 140) -> String {
        let line = text.replacing("\n", with: " ")
        guard let match = line.range(of: query, options: .caseInsensitive) else {
            return String(line.prefix(maxLength))
        }
        let start = line.index(match.lowerBound, offsetBy: -30, limitedBy: line.startIndex) ?? line.startIndex
        let excerpt = line[start...]
        let prefix = start > line.startIndex ? "…" : ""
        return excerpt.count > maxLength
            ? prefix + excerpt.prefix(maxLength) + "…"
            : prefix + excerpt
    }

    // MARK: - Observation

    private func observe<Value: Equatable & Sendable>(
        _ fetch: @escaping @Sendable (Database) throws -> Value
    ) -> AsyncValueObservation<Value> {
        ValueObservation
            .tracking(fetch)
            .removeDuplicates()
            .values(in: dbWriter)
    }
}

extension Date {
    /// Unix milliseconds, the way dates are stored in the database.
    var databaseMilliseconds: Int64 {
        Int64(floor(timeIntervalSince1970 * 1000))
    }
}
