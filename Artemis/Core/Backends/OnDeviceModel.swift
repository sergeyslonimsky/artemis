import Foundation
import FoundationModels

/// User-facing state of Apple's on-device model.
enum OnDeviceModelStatus: Equatable, Sendable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady

    static var current: OnDeviceModelStatus {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            return .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady):
            return .modelNotReady
        case .unavailable:
            return .modelNotReady
        }
    }

    var isAvailable: Bool { self == .available }

    var title: String {
        switch self {
        case .available: "Available"
        case .deviceNotEligible: "Not supported on this device"
        case .appleIntelligenceNotEnabled: "Apple Intelligence is off"
        case .modelNotReady: "Model is downloading"
        }
    }

    var detail: String {
        switch self {
        case .available:
            "Replies are generated privately on this device."
        case .deviceNotEligible:
            "This device can't run Apple's on-device model. Chats will use your cloud providers."
        case .appleIntelligenceNotEnabled:
            "Turn on Apple Intelligence in Settings to use the on-device model."
        case .modelNotReady:
            "The on-device model isn't ready yet. Try again once the download finishes."
        }
    }
}

/// Entry points for the on-device model that don't need a session.
enum OnDeviceModel {
    /// Display names of the languages the model supports ("English (United Kingdom)"), sorted.
    static var supportedLanguageNames: [String] {
        SystemLanguageModel.default.supportedLanguages
            .compactMap(\.displayName)
            .sorted()
    }

    @MainActor private static var lastPrewarm: Date?

    /// Loads the model into memory ahead of the first request. Repeated calls within a short
    /// window are ignored (focus can toggle often).
    @MainActor
    static func prewarm() {
        guard OnDeviceModelStatus.current.isAvailable else { return }
        if let lastPrewarm, Date().timeIntervalSince(lastPrewarm) < 30 { return }
        lastPrewarm = Date()
        LanguageModelSession(instructions: AppleOnDeviceBackend.baseInstructions()).prewarm()
    }
}

extension AppSettings {
    /// The on-device model is switched on and the system can run it right now.
    var isOnDeviceUsable: Bool {
        onDeviceEnabled && OnDeviceModelStatus.current.isAvailable
    }
}
