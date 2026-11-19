import CoreGraphics
import Foundation
import Synchronization

/// Reads the text in each attached image once, for whoever needs it: reading starts from the
/// full-size original when the image is attached, and the composer and the reply both await
/// that same work instead of starting their own.
final class ImageTextReader: Sendable {
    static let shared = ImageTextReader()

    /// Vision is heavy on memory: picking ten photos shouldn't decode ten originals at once.
    static let maxConcurrentReads = 2
    /// Finished readings kept for late callers (a reply that starts right after the composer got the text).
    static let keptReadings = 32

    private struct State {
        var readings: [String: Task<String?, any Error>] = [:]
        /// Attachment ids, oldest first, for evicting finished readings.
        var order: [String] = []
    }

    private let state = Mutex(State())
    private let gate = Gate(limit: maxConcurrentReads)

    /// Starts reading the image of attachment `id`, unless that's already under way or done.
    func start(id: String, image: @escaping @Sendable () -> CGImage?) {
        _ = reading(id: id, image: image)
    }

    /// The text in attachment `id` (`nil` when there's none): the reading started when it was
    /// attached, or a new one from `data`, the stored copy. Throws when reading failed or was
    /// cancelled, so the caller doesn't take that for "no text".
    func text(id: String, data: Data) async throws -> String? {
        try await reading(id: id) { AttachmentProcessor.uprightImage(from: data) }.value
    }

    /// Stops reading an image that was removed before it was sent.
    func cancel(id: String) {
        let task = state.withLock { state -> Task<String?, any Error>? in
            state.order.removeAll { $0 == id }
            return state.readings.removeValue(forKey: id)
        }
        task?.cancel()
    }

    private func reading(id: String, image: @escaping @Sendable () -> CGImage?) -> Task<String?, any Error> {
        state.withLock { state in
            if let existing = state.readings[id] { return existing }
            let task = Task.detached(priority: .userInitiated) { [gate] in
                do {
                    return try await gate.run { () async throws -> String? in
                        try Task.checkCancellation()
                        guard let image = image() else { return nil }
                        return try await ImageTextRecognizer.recognizeText(in: image)
                    }
                } catch {
                    // A failed reading can be retried by the next caller.
                    self.forget(id: id)
                    throw error
                }
            }
            state.readings[id] = task
            state.order.append(id)
            if state.order.count > Self.keptReadings {
                state.readings[state.order.removeFirst()] = nil
            }
            return task
        }
    }

    private func forget(id: String) {
        state.withLock { state in
            state.readings[id] = nil
            state.order.removeAll { $0 == id }
        }
    }
}

/// Runs at most `limit` operations at a time; the rest wait their turn in order.
private actor Gate {
    let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        if running < limit {
            running += 1
        } else {
            await withCheckedContinuation { waiting.append($0) }
        }
        defer {
            if waiting.isEmpty {
                running -= 1
            } else {
                waiting.removeFirst().resume()
            }
        }
        return try await operation()
    }
}
