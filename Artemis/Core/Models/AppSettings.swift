import Foundation
import GRDB

struct AppSettings: Identifiable, Codable, Equatable, Sendable {
    var id: Int64
    var defaultProviderId: String?
    /// Cloud model used by default (and for escalation); `nil` uses the provider's default model.
    var defaultModel: String?
    var systemPrompt: String
    var defaultPresetId: String?
    var debugMode: Bool
    var routingMode: RoutingMode
    var cloudPolicy: CloudPolicy
    var onDeviceEnabled: Bool
    var onDeviceTitles: Bool
    /// Let the on-device model use device data and draft actions (master switch).
    var personalDataTools: Bool
    /// Tool groups switched off individually.
    var disabledToolGroups: Set<ToolGroup>
    /// Starred cloud models, shown first in the model picker.
    var favoriteModels: [ModelRef]

    init(
        id: Int64 = 1,
        defaultProviderId: String? = nil,
        defaultModel: String? = nil,
        systemPrompt: String = "",
        defaultPresetId: String? = nil,
        debugMode: Bool = false,
        routingMode: RoutingMode = .auto,
        cloudPolicy: CloudPolicy = .alwaysAsk,
        onDeviceEnabled: Bool = true,
        onDeviceTitles: Bool = true,
        personalDataTools: Bool = true,
        disabledToolGroups: Set<ToolGroup> = [],
        favoriteModels: [ModelRef] = []
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
        self.personalDataTools = personalDataTools
        self.disabledToolGroups = disabledToolGroups
        self.favoriteModels = favoriteModels
    }

    var enabledToolGroups: Set<ToolGroup> {
        personalDataTools ? Set(ToolGroup.allCases).subtracting(disabledToolGroups) : []
    }
}

// MARK: - GRDB Records
extension AppSettings: AppRecord {
    static let databaseTableName = "settings"
}

/// A cloud model of a particular provider.
struct ModelRef: Codable, Hashable, Sendable {
    var providerId: String
    var model: String
}
