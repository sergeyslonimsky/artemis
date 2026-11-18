import Foundation

/// Why a reply went to the backend it did. Persisted in `messages.route_reason`.
public enum RouteReason: String, Codable, Sendable {
    // Explicit user choices
    case userSelectedOnDevice = "user_on_device"
    case userSelectedCloud = "user_cloud"
    case userAskedCloud = "user_asked_cloud"

    // Rules
    case unsupportedAttachment = "unsupported_attachment"
    case unsupportedLanguage = "unsupported_language"
    case longInput = "long_input"
    case onDeviceUnavailable = "on_device_unavailable"
    /// Legacy: kept so replies stored before the classifier ran without a cloud still decode.
    case noCloudProvider = "no_cloud_provider"
    case smallTalk = "small_talk"

    // Classifier
    case simple
    case writing
    case deviceAction = "device_action"
    case freshInformation = "fresh_information"
    case complexReasoning = "complex_reasoning"
    case code
    case longForm = "long_form"

    // Escalation after the on-device model failed
    case onDeviceFailed = "on_device_failed"

    /// The request would be better served by the cloud. On-device replies with such a reason
    /// were kept local only because the cloud was denied, declined or not configured.
    public var prefersCloud: Bool {
        switch self {
        case .userAskedCloud, .userSelectedCloud, .unsupportedAttachment, .unsupportedLanguage,
             .longInput, .onDeviceUnavailable, .freshInformation, .complexReasoning, .code, .longForm,
             .onDeviceFailed:
            true
        case .userSelectedOnDevice, .noCloudProvider, .smallTalk, .simple, .writing, .deviceAction:
            false
        }
    }

    /// Short explanation shown to the user ("Sent to the cloud: …" / "Answered on-device: …").
    public var explanation: String {
        switch self {
        case .userSelectedOnDevice: "you chose the on-device model"
        case .userSelectedCloud: "you chose a cloud model"
        case .userAskedCloud: "you asked the cloud model"
        case .unsupportedAttachment: "the on-device model can't read this attachment"
        case .unsupportedLanguage: "the on-device model doesn't support this language"
        case .longInput: "the message is too long for the on-device model"
        case .onDeviceUnavailable: "the on-device model isn't available"
        case .noCloudProvider: "no cloud provider is configured"
        case .smallTalk: "a quick reply"
        case .simple: "a simple question"
        case .writing: "a writing task"
        case .deviceAction: "device actions aren't possible from chat"
        case .freshInformation: "it needs up-to-date information"
        case .complexReasoning: "it needs complex reasoning"
        case .code: "it involves code"
        case .longForm: "it needs a long, detailed answer"
        case .onDeviceFailed: "the on-device model couldn't answer"
        }
    }
}

/// Router output for one turn.
public struct RouteDecision: Equatable, Sendable {
    public var backend: BackendKind
    public var reason: RouteReason

    public static func onDevice(_ reason: RouteReason) -> RouteDecision {
        RouteDecision(backend: .onDevice, reason: reason)
    }

    public static func cloud(_ reason: RouteReason) -> RouteDecision {
        RouteDecision(backend: .cloud, reason: reason)
    }
}
