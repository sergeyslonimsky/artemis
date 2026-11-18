import Foundation
import GRDB
import UniformTypeIdentifiers

enum AttachmentKind: String, Codable, Sendable {
    case image
    case document
}

struct Attachment: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var messageId: String
    var filename: String
    var mime: String
    var kind: AttachmentKind
    var size: Int
    var createdAt: Date
    /// Bytes for sending; stored in a file next to the database, not in the row.
    var data: Data? = nil

    enum CodingKeys: String, CodingKey {
        case id, messageId, filename, mime, kind, size, createdAt
    }

    init(
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

    var contentType: UTType {
        UTType(mimeType: mime) ?? .data
    }

    /// Plain text, Markdown, JSON, XML, source code…: inlined into prompts as text, so every
    /// model can read it.
    var isTextDocument: Bool {
        kind == .document && (contentType.conforms(to: .text) || contentType.conforms(to: .json))
    }

    /// The document's text, when it is a text document with its bytes loaded.
    var text: String? {
        guard isTextDocument, let data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// "Image" or "File", for notes that stand in for an attachment.
    var kindLabel: String {
        kind == .image ? "Image" : "File"
    }
}

// MARK: - GRDB Records
extension Attachment: AppRecord {
    static let databaseTableName = "attachments"

    enum Columns {
        static let id = Column("id")
        static let messageId = Column("message_id")
        static let createdAt = Column("created_at")
    }
}
