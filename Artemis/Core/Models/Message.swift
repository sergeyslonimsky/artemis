import Foundation
import GRDB

public enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

public struct MessageStats: Codable, Equatable, Sendable {
    public var tokens: Int
    public var isEstimated: Bool
    public var durationMs: Int

    public var tokensPerSecond: Double? {
        guard durationMs > 0 else { return nil }
        return Double(tokens) / (Double(durationMs) / 1000.0)
    }

    public init(tokens: Int, isEstimated: Bool, durationMs: Int) {
        self.tokens = tokens
        self.isEstimated = isEstimated
        self.durationMs = durationMs
    }
}

public struct Message: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var chatId: String
    public var role: MessageRole
    public var content: String
    public var reasoning: String
    public var createdAt: Date
    public var stats: MessageStats?
    public var attachments: [Attachment]

    public init(
        id: String = UUID().uuidString.lowercased(),
        chatId: String,
        role: MessageRole,
        content: String,
        reasoning: String = "",
        createdAt: Date = Date(),
        stats: MessageStats? = nil,
        attachments: [Attachment] = []
    ) {
        self.id = id
        self.chatId = chatId
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.createdAt = createdAt
        self.stats = stats
        self.attachments = attachments
    }
}

// MARK: - GRDB Records
extension Message: FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "messages"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let chatId = Column("chat_id")
        public static let role = Column(CodingKeys.role)
        public static let content = Column(CodingKeys.content)
        public static let reasoning = Column(CodingKeys.reasoning)
        public static let createdAt = Column("created_at")
        public static let tokens = Column("tokens")
        public static let tokensEstimated = Column("tokens_estimated")
        public static let durationMs = Column("duration_ms")
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.chatId] = chatId
        container[Columns.role] = role.rawValue
        container[Columns.content] = content
        container[Columns.reasoning] = reasoning
        container[Columns.createdAt] = Int64(createdAt.timeIntervalSince1970 * 1000)
        
        if let stats = stats {
            container[Columns.tokens] = stats.tokens
            container[Columns.tokensEstimated] = stats.isEstimated ? 1 : 0
            container[Columns.durationMs] = stats.durationMs
        } else {
            container[Columns.tokens] = nil
            container[Columns.tokensEstimated] = nil
            container[Columns.durationMs] = nil
        }
    }

    public init(row: Row) throws {
        id = row[Columns.id]
        chatId = row[Columns.chatId]
        let roleRaw: String = row[Columns.role]
        role = MessageRole(rawValue: roleRaw) ?? .user
        content = row[Columns.content]
        reasoning = row[Columns.reasoning]
        let createdMillis: Int64 = row[Columns.createdAt]
        createdAt = Date(timeIntervalSince1970: TimeInterval(createdMillis) / 1000.0)

        if let tokens: Int = row[Columns.tokens] {
            let estimated: Int? = row[Columns.tokensEstimated]
            let duration: Int? = row[Columns.durationMs]
            stats = MessageStats(
                tokens: tokens,
                isEstimated: (estimated ?? 0) != 0,
                durationMs: duration ?? 0
            )
        } else {
            stats = nil
        }
        attachments = []
    }
}
