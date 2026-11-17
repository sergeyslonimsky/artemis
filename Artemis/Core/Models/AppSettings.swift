import Foundation
import GRDB

public struct AppSettings: Identifiable, Codable, Equatable, Sendable {
    public var id: Int64
    public var defaultProviderId: String?
    public var systemPrompt: String
    public var defaultPresetId: String?
    public var debugMode: Bool

    public init(
        id: Int64 = 1,
        defaultProviderId: String? = nil,
        systemPrompt: String = "",
        defaultPresetId: String? = nil,
        debugMode: Bool = false
    ) {
        self.id = id
        self.defaultProviderId = defaultProviderId
        self.systemPrompt = systemPrompt
        self.defaultPresetId = defaultPresetId
        self.debugMode = debugMode
    }
}

// MARK: - GRDB Records
extension AppSettings: FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "settings"

    public enum Columns {
        public static let id = Column(CodingKeys.id)
        public static let defaultProviderId = Column("default_provider_id")
        public static let systemPrompt = Column("system_prompt")
        public static let defaultPresetId = Column("default_preset_id")
        public static let debugMode = Column("debug_mode")
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.defaultProviderId] = defaultProviderId
        container[Columns.systemPrompt] = systemPrompt
        container[Columns.defaultPresetId] = defaultPresetId
        container[Columns.debugMode] = debugMode ? 1 : 0
    }

    public init(row: Row) throws {
        id = row[Columns.id]
        defaultProviderId = row[Columns.defaultProviderId]
        systemPrompt = row[Columns.systemPrompt] ?? ""
        defaultPresetId = row[Columns.defaultPresetId]
        let debugInt: Int? = row[Columns.debugMode]
        debugMode = (debugInt ?? 0) != 0
    }
}
