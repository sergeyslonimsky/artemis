import Foundation
import GRDB

public enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

public enum MessageStatus: String, Codable, Sendable {
    /// Assistant reply is being generated; live text lives in `ChatService`.
    case streaming
    case done
    case failed
    case cancelled
    /// Placeholder asking the user to approve sending this turn to the cloud.
    case awaitingConsent = "awaiting_consent"
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
    /// Monotonic position inside the chat, assigned on insert.
    public var seq: Int64
    public var role: MessageRole
    public var content: String
    public var reasoning: String
    public var createdAt: Date
    public var status: MessageStatus
    public var error: String?
    public var stats: MessageStats?
    public var attachments: [Attachment]
    /// Who generated an assistant reply; `nil` for user messages and legacy replies.
    public var backend: BackendKind?
    public var providerId: String?
    public var model: String?
    /// Why the router picked `backend` (or why consent is asked).
    public var routeReason: RouteReason?
    /// Personal data the reply used and the actions it proposed.
    public var extras: MessageExtras

    public init(
        id: String = UUID().uuidString.lowercased(),
        chatId: String,
        seq: Int64 = 0,
        role: MessageRole,
        content: String,
        reasoning: String = "",
        createdAt: Date = Date(),
        status: MessageStatus = .done,
        error: String? = nil,
        stats: MessageStats? = nil,
        attachments: [Attachment] = [],
        backend: BackendKind? = nil,
        providerId: String? = nil,
        model: String? = nil,
        routeReason: RouteReason? = nil,
        extras: MessageExtras = MessageExtras()
    ) {
        self.id = id
        self.chatId = chatId
        self.seq = seq
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.createdAt = createdAt
        self.status = status
        self.error = error
        self.stats = stats
        self.attachments = attachments
        self.backend = backend
        self.providerId = providerId
        self.model = model
        self.routeReason = routeReason
        self.extras = extras
    }
}

// MARK: - GRDB Records
extension Message: FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "messages"

    public enum Columns {
        public static let id = Column("id")
        public static let chatId = Column("chat_id")
        public static let seq = Column("seq")
        public static let role = Column("role")
        public static let content = Column("content")
        public static let reasoning = Column("reasoning")
        public static let createdAt = Column("created_at")
        public static let status = Column("status")
        public static let error = Column("error")
        public static let tokens = Column("tokens")
        public static let tokensEstimated = Column("tokens_estimated")
        public static let durationMs = Column("duration_ms")
        public static let backend = Column("backend")
        public static let providerId = Column("provider_id")
        public static let model = Column("model")
        public static let routeReason = Column("route_reason")
        public static let extras = Column("extras")
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.chatId] = chatId
        container[Columns.seq] = seq
        container[Columns.role] = role.rawValue
        container[Columns.content] = content
        container[Columns.reasoning] = reasoning
        container[Columns.createdAt] = Int64(createdAt.timeIntervalSince1970 * 1000)
        container[Columns.status] = status.rawValue
        container[Columns.error] = error
        container[Columns.backend] = backend?.rawValue
        container[Columns.providerId] = providerId
        container[Columns.model] = model
        container[Columns.routeReason] = routeReason?.rawValue
        container[Columns.extras] = extras.isEmpty ? nil : String(data: try JSONEncoder().encode(extras), encoding: .utf8)

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
        seq = row[Columns.seq]
        let roleRaw: String = row[Columns.role]
        role = MessageRole(rawValue: roleRaw) ?? .user
        content = row[Columns.content]
        reasoning = row[Columns.reasoning]
        let createdMillis: Int64 = row[Columns.createdAt]
        createdAt = Date(timeIntervalSince1970: TimeInterval(createdMillis) / 1000.0)
        let statusRaw: String = row[Columns.status]
        status = MessageStatus(rawValue: statusRaw) ?? .done
        error = row[Columns.error]
        let backendRaw: String? = row[Columns.backend]
        backend = backendRaw.flatMap(BackendKind.init(rawValue:))
        providerId = row[Columns.providerId]
        model = row[Columns.model]
        let reasonRaw: String? = row[Columns.routeReason]
        routeReason = reasonRaw.flatMap(RouteReason.init(rawValue:))
        let extrasJSON: String? = row[Columns.extras]
        extras = extrasJSON.flatMap { try? JSONDecoder().decode(MessageExtras.self, from: Data($0.utf8)) } ?? MessageExtras()

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
