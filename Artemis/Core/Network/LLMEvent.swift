import Foundation

public enum LLMEvent: Sendable, Equatable {
    case content(String)
    case reasoning(String)
    case done(tokens: Int, isEstimated: Bool, durationMs: Int)
    case error(String)
    /// The on-device model started reading a personal-data source.
    case toolStarted(PersonalDataSource)
    /// The on-device model proposed an event or reminder for the user to confirm.
    case actionDraft(ActionDraft)
}
