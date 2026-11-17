import Foundation
import GRDB

public enum AttachmentKind: String, Codable, Sendable {
    case image
    case document
}

public struct Attachment: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var messageId: String
    public var filename: String
    public var mime: String
    public var kind: AttachmentKind
    public var size: Int
    public var createdAt: Date
    public var data: Data?

    public init(
        id: String = UUID().uuidString.lowercased(),
        messageId: String = "",
        filename: String,
        mime: String,
        kind: AttachmentKind,
        size: Int = 0,
        createdAt: Date = Date(),
        data: Data? = nil
    ) {
        self.id = id
        self.messageId = messageId
        self.filename = filename
        self.mime = mime
        self.kind = kind
        self.size = size == 0 ? (data?.count ?? 0) : size
        self.createdAt = createdAt
        self.data = data
    }
}

// MARK: - GRDB Records
extension Attachment: FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "attachments"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let messageId = Column("message_id")
        public static let filename = Column(CodingKeys.filename)
        public static let mime = Column(CodingKeys.mime)
        public static let kind = Column(CodingKeys.kind)
        public static let size = Column(CodingKeys.size)
        public static let createdAt = Column("created_at")
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.messageId] = messageId
        container[Columns.filename] = filename
        container[Columns.mime] = mime
        container[Columns.kind] = kind.rawValue
        container[Columns.size] = size
        container[Columns.createdAt] = Int64(createdAt.timeIntervalSince1970 * 1000)
    }

    public init(row: Row) throws {
        id = row[Columns.id]
        messageId = row[Columns.messageId]
        filename = row[Columns.filename]
        mime = row[Columns.mime]
        let kindRaw: String = row[Columns.kind]
        kind = AttachmentKind(rawValue: kindRaw) ?? .document
        size = row[Columns.size]
        let createdMillis: Int64 = row[Columns.createdAt]
        createdAt = Date(timeIntervalSince1970: TimeInterval(createdMillis) / 1000.0)
        data = nil
    }
}
