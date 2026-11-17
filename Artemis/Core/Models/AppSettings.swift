import Foundation
import GRDB

public struct AppSettings: Identifiable, Codable, Equatable, Sendable {
    public var id: Int64
    public var defaultProviderId: String?
    /// Cloud model used by default (and for escalation); `nil` uses the provider's default model.
    public var defaultModel: String?
    public var systemPrompt: String
    public var defaultPresetId: String?
    public var debugMode: Bool
    public var routingMode: RoutingMode
    public var cloudPolicy: CloudPolicy
    public var onDeviceEnabled: Bool
    public var onDeviceTitles: Bool

    public init(
        id: Int64 = 1,
        defaultProviderId: String? = nil,
        defaultModel: String? = nil,
        systemPrompt: String = "",
        defaultPresetId: String? = nil,
        debugMode: Bool = false,
        routingMode: RoutingMode = .auto,
        cloudPolicy: CloudPolicy = .alwaysAsk,
        onDeviceEnabled: Bool = true,
        onDeviceTitles: Bool = true
    ) {
        self.id = id
        self.defaultProviderId = defaultProviderId
        self.defaultModel = defaultModel
        self.systemPrompt = systemPrompt
        self.defaultPresetId = defaultPresetId
        self.debugMode = debugMode
        self.routingMode = routingMode
        self.cloudPolicy = cloudPolicy
        self.onDeviceEnabled = onDeviceEnabled
        self.onDeviceTitles = onDeviceTitles
    }
}

// MARK: - GRDB Records
extension AppSettings: FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "settings"

    public enum Columns {
        public static let id = Column("id")
        public static let defaultProviderId = Column("default_provider_id")
        public static let defaultModel = Column("default_model")
        public static let systemPrompt = Column("system_prompt")
        public static let defaultPresetId = Column("default_preset_id")
        public static let debugMode = Column("debug_mode")
        public static let routingMode = Column("routing_mode")
        public static let cloudPolicy = Column("cloud_policy")
        public static let onDeviceEnabled = Column("on_device_enabled")
        public static let onDeviceTitles = Column("on_device_titles")
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.defaultProviderId] = defaultProviderId
        container[Columns.defaultModel] = defaultModel
        container[Columns.systemPrompt] = systemPrompt
        container[Columns.defaultPresetId] = defaultPresetId
        container[Columns.debugMode] = debugMode ? 1 : 0
        container[Columns.routingMode] = routingMode.rawValue
        container[Columns.cloudPolicy] = cloudPolicy.rawValue
        container[Columns.onDeviceEnabled] = onDeviceEnabled ? 1 : 0
        container[Columns.onDeviceTitles] = onDeviceTitles ? 1 : 0
    }

    public init(row: Row) throws {
        id = row[Columns.id]
        defaultProviderId = row[Columns.defaultProviderId]
        defaultModel = row[Columns.defaultModel]
        systemPrompt = row[Columns.systemPrompt] ?? ""
        defaultPresetId = row[Columns.defaultPresetId]
        let debugInt: Int? = row[Columns.debugMode]
        debugMode = (debugInt ?? 0) != 0
        let modeRaw: String = row[Columns.routingMode]
        routingMode = RoutingMode(rawValue: modeRaw) ?? .auto
        let policyRaw: String = row[Columns.cloudPolicy]
        cloudPolicy = CloudPolicy(rawValue: policyRaw) ?? .alwaysAsk
        let onDeviceInt: Int = row[Columns.onDeviceEnabled]
        onDeviceEnabled = onDeviceInt != 0
        let titlesInt: Int = row[Columns.onDeviceTitles]
        onDeviceTitles = titlesInt != 0
    }
}
