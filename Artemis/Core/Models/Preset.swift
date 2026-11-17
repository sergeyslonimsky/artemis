import Foundation
import GRDB

public struct Preset: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var systemPrompt: String
    public var temperature: Double?
    public var topP: Double?
    public var frequencyPenalty: Double?
    public var presencePenalty: Double?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString.lowercased(),
        title: String,
        systemPrompt: String = "",
        temperature: Double? = nil,
        topP: Double? = nil,
        frequencyPenalty: Double? = nil,
        presencePenalty: Double? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.topP = topP
        self.frequencyPenalty = frequencyPenalty
        self.presencePenalty = presencePenalty
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - GRDB Records
extension Preset: FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "presets"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let title = Column(CodingKeys.title)
        public static let systemPrompt = Column("system_prompt")
        public static let temperature = Column(CodingKeys.temperature)
        public static let topP = Column("top_p")
        public static let frequencyPenalty = Column("frequency_penalty")
        public static let presencePenalty = Column("presence_penalty")
        public static let createdAt = Column("created_at")
        public static let updatedAt = Column("updated_at")
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.title] = title
        container[Columns.systemPrompt] = systemPrompt
        container[Columns.temperature] = temperature
        container[Columns.topP] = topP
        container[Columns.frequencyPenalty] = frequencyPenalty
        container[Columns.presencePenalty] = presencePenalty
        container[Columns.createdAt] = Int64(createdAt.timeIntervalSince1970 * 1000)
        container[Columns.updatedAt] = Int64(updatedAt.timeIntervalSince1970 * 1000)
    }

    public init(row: Row) throws {
        id = row[Columns.id]
        title = row[Columns.title]
        systemPrompt = row[Columns.systemPrompt]
        temperature = row[Columns.temperature]
        topP = row[Columns.topP]
        frequencyPenalty = row[Columns.frequencyPenalty]
        presencePenalty = row[Columns.presencePenalty]
        let createdMillis: Int64 = row[Columns.createdAt]
        let updatedMillis: Int64 = row[Columns.updatedAt]
        createdAt = Date(timeIntervalSince1970: TimeInterval(createdMillis) / 1000.0)
        updatedAt = Date(timeIntervalSince1970: TimeInterval(updatedMillis) / 1000.0)
    }
}
