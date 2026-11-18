import Foundation
import GRDB

struct Preset: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var title: String
    var systemPrompt: String
    var temperature: Double?
    var topP: Double?
    var frequencyPenalty: Double?
    var presencePenalty: Double?
    var createdAt: Date
    var updatedAt: Date

    init(
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

    /// A preset's own instructions replace the general ones; `nil` when neither has any.
    static func effectiveSystemPrompt(preset: Preset?, fallback: String?) -> String? {
        if let own = preset?.systemPrompt, !own.isEmpty { return own }
        guard let fallback, !fallback.isEmpty else { return nil }
        return fallback
    }
}

// MARK: - GRDB Records
extension Preset: AppRecord {
    static let databaseTableName = "presets"

    enum Columns {
        static let createdAt = Column("created_at")
    }
}
