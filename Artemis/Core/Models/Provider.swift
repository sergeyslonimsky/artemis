import Foundation
import GRDB

/// Known OpenAI-compatible services. Drives the request shape via `ProviderCapabilities`
/// instead of `if`s on provider names.
public enum ProviderKind: String, Codable, Sendable, CaseIterable {
    case openRouter = "openrouter"
    case openAI = "openai"
    case mistral
    case groq
    case custom

    public var displayName: String {
        switch self {
        case .openRouter: "OpenRouter"
        case .openAI: "OpenAI"
        case .mistral: "Mistral"
        case .groq: "Groq"
        case .custom: "Custom"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .openRouter: "https://openrouter.ai/api/v1"
        case .openAI: "https://api.openai.com/v1"
        case .mistral: "https://api.mistral.ai/v1"
        case .groq: "https://api.groq.com/openai/v1"
        case .custom: ""
        }
    }

    public var capabilities: ProviderCapabilities {
        switch self {
        case .openRouter, .openAI:
            ProviderCapabilities(supportsImages: true, supportsFileParts: true, supportsStreamUsage: true)
        case .mistral:
            // Mistral rejects unknown request fields such as `stream_options`.
            ProviderCapabilities(supportsImages: true, supportsFileParts: false, supportsStreamUsage: false)
        case .groq:
            ProviderCapabilities(supportsImages: true, supportsFileParts: false, supportsStreamUsage: false)
        case .custom:
            ProviderCapabilities(supportsImages: true, supportsFileParts: false, supportsStreamUsage: true)
        }
    }

    /// Best guess from the endpoint host, used for providers created without an explicit kind.
    public static func infer(fromBaseURL baseURL: String) -> ProviderKind {
        guard let host = URL(string: baseURL)?.host()?.lowercased() else { return .custom }
        if host.hasSuffix("openrouter.ai") { return .openRouter }
        if host == "api.openai.com" { return .openAI }
        if host.hasSuffix("mistral.ai") { return .mistral }
        if host.hasSuffix("groq.com") { return .groq }
        return .custom
    }
}

/// What a provider's `/chat/completions` endpoint accepts.
public struct ProviderCapabilities: Equatable, Sendable {
    /// `image_url` content parts.
    public var supportsImages: Bool
    /// `file` content parts (e.g. PDFs as base64 `file_data`).
    public var supportsFileParts: Bool
    /// `stream_options.include_usage`.
    public var supportsStreamUsage: Bool
}

/// An OpenAI-compatible endpoint. The API key is not part of the record:
/// it lives in the Keychain, see `APIKeyStore`.
public struct Provider: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var kind: ProviderKind
    public var baseUrl: String
    public var models: [String]
    public var defaultModel: String
    public var createdAt: Date
    public var updatedAt: Date

    public var capabilities: ProviderCapabilities { kind.capabilities }

    public init(
        id: String = UUID().uuidString.lowercased(),
        name: String,
        kind: ProviderKind? = nil,
        baseUrl: String,
        models: [String] = [],
        defaultModel: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.kind = kind ?? ProviderKind.infer(fromBaseURL: baseUrl)
        self.baseUrl = baseUrl
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
        public static let id = Column("id")
        public static let name = Column("name")
        public static let kind = Column("kind")
        public static let baseUrl = Column("base_url")
        public static let models = Column("models")
        public static let defaultModel = Column("default_model")
        public static let createdAt = Column("created_at")
        public static let updatedAt = Column("updated_at")
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.name] = name
        container[Columns.kind] = kind.rawValue
        container[Columns.baseUrl] = baseUrl
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
        let kindRaw: String = row[Columns.kind]
        kind = ProviderKind(rawValue: kindRaw) ?? .custom
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
