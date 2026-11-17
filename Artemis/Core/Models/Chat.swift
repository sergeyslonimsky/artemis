import Foundation
import GRDB

public enum TitleSource: String, Codable, Sendable {
    case placeholder
    case generated
    case manual
}

public struct Chat: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var titleSource: TitleSource
    public var createdAt: Date
    public var updatedAt: Date
    /// Provider/model last selected in this chat. `nil` falls back to the app defaults.
    public var providerId: String?
    public var model: String?
    /// `nil` follows `AppSettings.routingMode`.
    public var routingMode: RoutingMode?

    public init(
        id: String = UUID().uuidString.lowercased(),
        title: String,
        titleSource: TitleSource = .placeholder,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        providerId: String? = nil,
        model: String? = nil,
        routingMode: RoutingMode? = nil
    ) {
        self.id = id
        self.title = title
        self.titleSource = titleSource
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.providerId = providerId
        self.model = model
        self.routingMode = routingMode
    }
}

// MARK: - GRDB Records
extension Chat: FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "chats"

    public enum Columns {
        public static let id = Column("id")
        public static let title = Column("title")
        public static let titleSource = Column("title_source")
        public static let createdAt = Column("created_at")
        public static let updatedAt = Column("updated_at")
        public static let providerId = Column("provider_id")
        public static let model = Column("model")
        public static let routingMode = Column("routing_mode")
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.title] = title
        container[Columns.titleSource] = titleSource.rawValue
        container[Columns.createdAt] = Int64(createdAt.timeIntervalSince1970 * 1000)
        container[Columns.updatedAt] = Int64(updatedAt.timeIntervalSince1970 * 1000)
        container[Columns.providerId] = providerId
        container[Columns.model] = model
        container[Columns.routingMode] = routingMode?.rawValue
    }

    public init(row: Row) throws {
        id = row[Columns.id]
        title = row[Columns.title]
        let sourceRaw: String = row[Columns.titleSource]
        titleSource = TitleSource(rawValue: sourceRaw) ?? .placeholder
        let createdMillis: Int64 = row[Columns.createdAt]
        let updatedMillis: Int64 = row[Columns.updatedAt]
        createdAt = Date(timeIntervalSince1970: TimeInterval(createdMillis) / 1000.0)
        updatedAt = Date(timeIntervalSince1970: TimeInterval(updatedMillis) / 1000.0)
        providerId = row[Columns.providerId]
        model = row[Columns.model]
        let modeRaw: String? = row[Columns.routingMode]
        routingMode = modeRaw.flatMap(RoutingMode.init(rawValue:))
    }
}
