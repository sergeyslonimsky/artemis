import Foundation

/// Coalesces stream fragments at ~60ms intervals so high-speed models (100+ tokens/sec)
/// do not trigger excessive UI layout passes and frame drops.
public actor StreamBatcher {
    private var pendingContent = ""
    private var pendingReasoning = ""
    private var lastFlushTime = Date()
    private let flushInterval: TimeInterval
    private let onFlush: @Sendable (String, String) -> Void

    public init(
        flushInterval: TimeInterval = 0.060, // 60ms
        onFlush: @escaping @Sendable (String, String) -> Void
    ) {
        self.flushInterval = flushInterval
        self.onFlush = onFlush
    }

    public func appendContent(_ text: String) {
        pendingContent += text
        checkFlush()
    }

    public func appendReasoning(_ text: String) {
        pendingReasoning += text
        checkFlush()
    }

    public func flush() {
        guard !pendingContent.isEmpty || !pendingReasoning.isEmpty else { return }
        let c = pendingContent
        let r = pendingReasoning
        pendingContent = ""
        pendingReasoning = ""
        lastFlushTime = Date()
        onFlush(c, r)
    }

    private func checkFlush() {
        let now = Date()
        if now.timeIntervalSince(lastFlushTime) >= flushInterval {
            flush()
        }
    }
}
