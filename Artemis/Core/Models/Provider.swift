import Foundation
import GRDB

public struct Provider: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var baseUrl: String
    public var apiKey: String
    public var models: [String]
    public var defaultModel: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString.lowercased(),
        name: String,
        baseUrl: String,
        apiKey: String = "",
        models: [String] = [],
        defaultModel: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.baseUrl = baseUrl
        self.apiKey = apiKey
        self.models = models
        self.defaultModel = defaultModel.isEmpty ? (models.first ?? "") : defaultModel
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - GRDB Records
extension Provider: FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "providers"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let name = Column(CodingKeys.name)
        public static let baseUrl = Column("base_url")
        public static let apiKey = Column("api_key")
        public static let models = Column(CodingKeys.models)
        public static let defaultModel = Column("default_model")
        public static let createdAt = Column("created_at")
        public static let updatedAt = Column("updated_at")
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.name] = name
        container[Columns.baseUrl] = baseUrl
        container[Columns.apiKey] = apiKey
        let data = try JSONEncoder().encode(models)
        let jsonString = String(data: data, encoding: .utf8) ?? "[]"
        container[Columns.models] = jsonString
        container[Columns.defaultModel] = defaultModel
        container[Columns.createdAt] = Int64(createdAt.timeIntervalSince1970 * 1000)
        container[Columns.updatedAt] = Int64(updatedAt.timeIntervalSince1970 * 1000)
    }

    public init(row: Row) throws {
        id = row[Columns.id]
        name = row[Columns.name]
        baseUrl = row[Columns.baseUrl]
        apiKey = row[Columns.apiKey]
        let jsonString: String = row[Columns.models]
        if let data = jsonString.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            models = decoded
        } else {
            models = []
        }
        defaultModel = row[Columns.defaultModel]
        let createdMillis: Int64 = row[Columns.createdAt]
        let updatedMillis: Int64 = row[Columns.updatedAt]
        createdAt = Date(timeIntervalSince1970: TimeInterval(createdMillis) / 1000.0)
        updatedAt = Date(timeIntervalSince1970: TimeInterval(updatedMillis) / 1000.0)
    }
}
