import Foundation
import GRDB

enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

enum MessageStatus: String, Codable, Sendable {
    /// Assistant reply is being generated; live text lives in `ChatService`.
    case streaming
    case done
    case failed
    case cancelled
    /// Placeholder asking the user to approve sending this turn to the cloud.
    case awaitingConsent = "awaiting_consent"
}

struct MessageStats: Codable, Equatable, Sendable {
    var tokens: Int
    var isEstimated: Bool
    var durationMs: Int

    var tokensPerSecond: Double? {
        guard durationMs > 0 else { return nil }
        return Double(tokens) / (Double(durationMs) / 1000.0)
    }
}

struct Message: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var chatId: String
    /// Monotonic position inside the chat, assigned on insert.
    var seq: Int64
    var role: MessageRole
    var content: String
    var reasoning: String
    var createdAt: Date
    var status: MessageStatus
    var error: String?
    var stats: MessageStats?
    var attachments: [Attachment]
    /// Who generated an assistant reply; `nil` for user messages and legacy replies.
    var backend: BackendKind?
    var providerId: String?
    var model: String?
    /// Why the router picked `backend` (or why consent is asked).
    var routeReason: RouteReason?
    /// Personal data the reply used and the actions it proposed.
    var extras: MessageExtras

    init(
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
    static let databaseTableName = "messages"

    enum Columns {
        static let id = Column("id")
        static let chatId = Column("chat_id")
        static let seq = Column("seq")
        static let role = Column("role")
        static let content = Column("content")
        static let reasoning = Column("reasoning")
        static let createdAt = Column("created_at")
        static let status = Column("status")
        static let error = Column("error")
        static let tokens = Column("tokens")
        static let tokensEstimated = Column("tokens_estimated")
        static let durationMs = Column("duration_ms")
        static let backend = Column("backend")
        static let providerId = Column("provider_id")
        static let model = Column("model")
        static let routeReason = Column("route_reason")
        static let extras = Column("extras")
    }

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.chatId] = chatId
        container[Columns.seq] = seq
        container[Columns.role] = role.rawValue
        container[Columns.content] = content
        container[Columns.reasoning] = reasoning
        container[Columns.createdAt] = createdAt.databaseMilliseconds
        container[Columns.status] = status.rawValue
        container[Columns.error] = error
        container[Columns.backend] = backend?.rawValue
        container[Columns.providerId] = providerId
        container[Columns.model] = model
        container[Columns.routeReason] = routeReason?.rawValue
        container[Columns.tokens] = stats?.tokens
        container[Columns.tokensEstimated] = stats?.isEstimated
        container[Columns.durationMs] = stats?.durationMs
        container[Columns.extras] = try Self.databaseJSON(extras)
    }

    init(row: Row) throws {
        id = row[Columns.id]
        chatId = row[Columns.chatId]
        seq = row[Columns.seq]
        let roleRaw: String = row[Columns.role]
        role = MessageRole(rawValue: roleRaw) ?? .user
        content = row[Columns.content]
        reasoning = row[Columns.reasoning]
        createdAt = Date(timeIntervalSince1970: TimeInterval(row[Columns.createdAt] as Int64) / 1000)
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

        stats = (row[Columns.tokens] as Int?).map { tokens in
            MessageStats(
                tokens: tokens,
                isEstimated: row[Columns.tokensEstimated] ?? false,
                durationMs: row[Columns.durationMs] ?? 0
            )
        }
        attachments = []
    }

    /// `extras` as stored: JSON, or `NULL` when there is nothing to store.
    static func databaseJSON(_ extras: MessageExtras) throws -> String? {
        extras.isEmpty ? nil : String(decoding: try JSONEncoder().encode(extras), as: UTF8.self)
    }
}
