import Foundation
import FoundationModels

/// User-facing state of Apple's on-device model.
public enum OnDeviceModelStatus: Equatable, Sendable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady

    public static var current: OnDeviceModelStatus {
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

    public var isAvailable: Bool { self == .available }

    public var title: String {
        switch self {
        case .available: "Available"
        case .deviceNotEligible: "Not supported on this device"
        case .appleIntelligenceNotEnabled: "Apple Intelligence is off"
        case .modelNotReady: "Model is downloading"
        }
    }

    public var detail: String {
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
public enum OnDeviceModel {
    /// Loads the model into memory ahead of the first request.
    public static func prewarm() {
        guard OnDeviceModelStatus.current.isAvailable else { return }
        LanguageModelSession().prewarm()
    }
}
