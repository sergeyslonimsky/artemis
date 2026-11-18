import Foundation
import GRDB

enum TitleSource: String, Codable, Sendable {
    case placeholder
    case generated
    case manual
}

struct Chat: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var title: String
    var titleSource: TitleSource
    var createdAt: Date
    var updatedAt: Date
    /// Provider/model last selected in this chat. `nil` falls back to the app defaults.
    var providerId: String?
    var model: String?
    /// `nil` follows `AppSettings.routingMode`.
    var routingMode: RoutingMode?
    /// The user approved automatic cloud use for this chat ("Don't ask again in this chat").
    var cloudAllowed: Bool

    init(
        id: String = UUID().uuidString.lowercased(),
        title: String,
        titleSource: TitleSource = .placeholder,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        providerId: String? = nil,
        model: String? = nil,
        routingMode: RoutingMode? = nil,
        cloudAllowed: Bool = false
    ) {
        self.id = id
        self.title = title
        self.titleSource = titleSource
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.providerId = providerId
        self.model = model
        self.routingMode = routingMode
        self.cloudAllowed = cloudAllowed
    }
}

// MARK: - GRDB Records
extension Chat: AppRecord {
    static let databaseTableName = "chats"

    enum Columns {
        static let title = Column("title")
        static let titleSource = Column("title_source")
        static let updatedAt = Column("updated_at")
        static let providerId = Column("provider_id")
        static let model = Column("model")
        static let routingMode = Column("routing_mode")
        static let cloudAllowed = Column("cloud_allowed")
    }
}
