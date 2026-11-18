import Foundation

extension AsyncThrowingStream where Failure == Error, Element: Sendable {
    /// A stream fed by `body` running in its own task. The task is cancelled when the consumer
    /// stops listening; an error thrown after cancellation surfaces as `CancellationError`.
    static func task(_ body: @escaping @Sendable (Continuation) async throws -> Void) -> Self {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await body(continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Task.isCancelled ? CancellationError() : error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
