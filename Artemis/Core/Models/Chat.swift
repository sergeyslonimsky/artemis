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

    public init(
        id: String = UUID().uuidString.lowercased(),
        title: String,
        titleSource: TitleSource = .placeholder,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.titleSource = titleSource
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - GRDB Records
extension Chat: FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "chats"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let title = Column(CodingKeys.title)
        public static let titleSource = Column(CodingKeys.titleSource)
        public static let createdAt = Column(CodingKeys.createdAt)
        public static let updatedAt = Column(CodingKeys.updatedAt)
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.title] = title
        container[Columns.titleSource] = titleSource.rawValue
        container[Columns.createdAt] = Int64(createdAt.timeIntervalSince1970 * 1000)
        container[Columns.updatedAt] = Int64(updatedAt.timeIntervalSince1970 * 1000)
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
    }
}
