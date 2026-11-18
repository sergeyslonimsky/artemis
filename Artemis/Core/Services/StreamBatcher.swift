import Foundation

/// Coalesces stream fragments so high-speed models (100+ tokens/sec) do not trigger
/// excessive UI layout passes. The owner awaits the returned batch itself, which keeps
/// deltas strictly ordered.
struct StreamBatcher {
    struct Batch: Sendable, Equatable {
        var content: String
        var reasoning: String
    }

    private var pending = Batch(content: "", reasoning: "")
    private var lastFlushTime: Date
    private let flushInterval: TimeInterval

    init(flushInterval: TimeInterval = 0.080, now: Date = Date()) {
        self.flushInterval = flushInterval
        self.lastFlushTime = now
    }

    /// Buffers the fragment and returns a batch once the flush interval has elapsed.
    mutating func append(content: String = "", reasoning: String = "", now: Date = Date()) -> Batch? {
        pending.content += content
        pending.reasoning += reasoning
        guard now.timeIntervalSince(lastFlushTime) >= flushInterval else { return nil }
        return drain(now: now)
    }

    /// Returns everything buffered so far, or `nil` when there is nothing pending.
    mutating func drain(now: Date = Date()) -> Batch? {
        guard !pending.content.isEmpty || !pending.reasoning.isEmpty else { return nil }
        let batch = pending
        pending = Batch(content: "", reasoning: "")
        lastFlushTime = now
        return batch
    }
}
