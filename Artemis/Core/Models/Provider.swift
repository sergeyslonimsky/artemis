import Foundation
import GRDB

/// Known OpenAI-compatible services. Drives the request shape via `ProviderCapabilities`
/// instead of `if`s on provider names.
enum ProviderKind: String, Codable, Sendable, CaseIterable {
    case openRouter = "openrouter"
    case openAI = "openai"
    case mistral
    case groq
    case custom

    var displayName: String {
        switch self {
        case .openRouter: "OpenRouter"
        case .openAI: "OpenAI"
        case .mistral: "Mistral"
        case .groq: "Groq"
        case .custom: "Custom"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openRouter: "https://openrouter.ai/api/v1"
        case .openAI: "https://api.openai.com/v1"
        case .mistral: "https://api.mistral.ai/v1"
        case .groq: "https://api.groq.com/openai/v1"
        case .custom: ""
        }
    }

    var capabilities: ProviderCapabilities {
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
    static func infer(fromBaseURL baseURL: String) -> ProviderKind {
        guard let host = URL(string: baseURL)?.host()?.lowercased() else { return .custom }
        if host.hasSuffix("openrouter.ai") { return .openRouter }
        if host == "api.openai.com" { return .openAI }
        if host.hasSuffix("mistral.ai") { return .mistral }
        if host.hasSuffix("groq.com") { return .groq }
        return .custom
    }

    /// Kinds offered when adding a provider; others are still recognized from the endpoint.
    static let selectable: [ProviderKind] = [.openRouter, .openAI, .mistral, .custom]

    /// Model IDs of OpenRouter's free variants end with this tag.
    static let freeModelSuffix = ":free"
}

enum ProviderError: LocalizedError, Equatable {
    case nameTaken(String)

    var errorDescription: String? {
        switch self {
        case .nameTaken(let name): "A provider named “\(name)” already exists."
        }
    }
}

/// What a provider's `/chat/completions` endpoint accepts.
struct ProviderCapabilities: Equatable, Sendable {
    /// `image_url` content parts.
    var supportsImages: Bool
    /// `file` content parts (e.g. PDFs as base64 `file_data`).
    var supportsFileParts: Bool
    /// `stream_options.include_usage`.
    var supportsStreamUsage: Bool
}

/// An OpenAI-compatible endpoint. The API key is not part of the record:
/// it lives in the Keychain, see `APIKeyStore`.
struct Provider: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var kind: ProviderKind
    var baseUrl: String
    var models: [String]
    var defaultModel: String
    /// Per-model capabilities reported by `/models` (e.g. `"tools"`). Models added by hand have none.
    var modelCapabilities: [String: [String]]
    /// OpenRouter: list only free models (IDs ending in `:free`).
    var onlyFreeModels: Bool
    var createdAt: Date
    var updatedAt: Date

    var capabilities: ProviderCapabilities { kind.capabilities }

    /// Capability that marks a model the gateway can run its web search/fetch tool loop for.
    static let toolsCapability = "tools"
    /// Gateway capabilities for the attachment kinds this app sends.
    static let imageInputCapability = "image_input"
    static let pdfInputCapability = "pdf_input"

    /// What `model` accepts: from its `/models` capabilities when the provider reports them,
    /// otherwise the provider kind's defaults.
    func capabilities(for model: String) -> ProviderCapabilities {
        var result = kind.capabilities
        if let reported = modelCapabilities[model], !reported.isEmpty {
            result.supportsImages = reported.contains(Self.imageInputCapability)
            result.supportsFileParts = reported.contains(Self.pdfInputCapability)
        }
        return result
    }

    func supportsWebSearch(model: String) -> Bool {
        modelCapabilities[model]?.contains(Self.toolsCapability) == true
    }

    /// Names are unique regardless of case and surrounding spaces.
    static func nameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    init(
        id: String = UUID().uuidString.lowercased(),
        name: String,
        kind: ProviderKind? = nil,
        baseUrl: String,
        models: [String] = [],
        defaultModel: String = "",
        modelCapabilities: [String: [String]] = [:],
        onlyFreeModels: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.kind = kind ?? ProviderKind.infer(fromBaseURL: baseUrl)
        self.baseUrl = baseUrl
        self.models = models
        self.defaultModel = defaultModel.isEmpty ? (models.first ?? "") : defaultModel
        self.modelCapabilities = modelCapabilities
        self.onlyFreeModels = onlyFreeModels
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - GRDB Records
extension Provider: AppRecord {
    static let databaseTableName = "providers"

    enum Columns {
        static let createdAt = Column("created_at")
    }
}
