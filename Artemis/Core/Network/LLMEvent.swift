import Foundation

public enum LLMEvent: Sendable, Equatable {
    case content(String)
    case reasoning(String)
    case done(tokens: Int, isEstimated: Bool, durationMs: Int)
    case error(String)
}
