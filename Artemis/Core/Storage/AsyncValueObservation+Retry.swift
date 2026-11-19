import Foundation
import GRDB

extension AsyncValueObservation {
    /// Delivers values until the calling task is cancelled. A failed read (say, a row that no longer
    /// decodes) used to end the observation for good, leaving the screen stale with no sign of it:
    /// now `onError` hears about it, once until values flow again, and observation restarts after
    /// `retryDelay`, so a fix shows up without relaunching.
    func keepDelivering(
        retryDelay: Duration = .seconds(5),
        isolation: isolated (any Actor)? = #isolation,
        onError: (any Error) -> Void,
        _ apply: (Element) async -> Void
    ) async {
        var reportedError = false
        while !Task.isCancelled {
            do {
                for try await value in self {
                    reportedError = false
                    await apply(value)
                }
                return // ends only when the task is cancelled
            } catch is CancellationError {
                return
            } catch {
                if !reportedError {
                    reportedError = true
                    onError(error)
                }
                do { try await Task.sleep(for: retryDelay) } catch { return }
            }
        }
    }
}
