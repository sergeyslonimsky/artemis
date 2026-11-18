import SwiftUI
import MarkdownUI

/// The user's answer to a cloud-consent prompt.
public enum ConsentChoice {
    /// Send this turn and stop asking in this chat.
    case allow
    case answerOnDevice
}

public struct MessageBubbleView: View {
    public let message: Message
    /// Live text from `ChatService` while the reply is generated.
    public var live: ChatRunState?
    /// Display name of `message.providerId`, if the provider still exists.
    public var providerName: String?
    public var onRegenerate: (() -> Void)?
    /// Re-answer an on-device reply with the cloud model; `nil` hides the action.
    public var onAskCloud: (() -> Void)?
    public var onConsent: ((ConsentChoice) -> Void)?
    /// Whether the chat has a cloud model to escalate to.
    public var cloudAvailable: Bool

    @State private var copied: Bool = false

    public init(
        message: Message,
        live: ChatRunState? = nil,
        providerName: String? = nil,
        onRegenerate: (() -> Void)? = nil,
        onAskCloud: (() -> Void)? = nil,
        onConsent: ((ConsentChoice) -> Void)? = nil,
        cloudAvailable: Bool = true
    ) {
        self.message = message
        self.live = live
        self.providerName = providerName
        self.onRegenerate = onRegenerate
        self.onAskCloud = onAskCloud
        self.onConsent = onConsent
        self.cloudAvailable = cloudAvailable
    }

    private var cloudLabel: String {
        [providerName, message.model].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "the cloud"
    }

    private var isStreaming: Bool {
        message.status == .streaming && (live?.isActive ?? true)
    }

    private var content: String {
        message.status == .streaming ? (live?.content ?? "") : message.content
    }

    private var reasoning: String {
        message.status == .streaming ? (live?.reasoning ?? "") : message.reasoning
    }

    public var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            if message.role == .user {
                userBubble
            } else if message.status == .awaitingConsent {
                consentCard
            } else {
                assistantBubble
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    // MARK: - User Bubble
    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !message.attachments.isEmpty {
                ForEach(message.attachments) { att in
                    AttachmentCardView(attachment: att)
                }
            }

            if !message.content.isEmpty {
                Text(message.content)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

            Text(message.createdAt, format: .dateTime.hour().minute())
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.trailing, 4)
        }
    }

    // MARK: - Assistant Bubble
    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Reasoning box
            if !reasoning.isEmpty || (isStreaming && content.isEmpty) {
                ReasoningView(
                    text: reasoning,
                    isStreaming: isStreaming && content.isEmpty,
                    durationMs: message.stats?.durationMs
                )
            }

            // Main Content
            if isStreaming && content.isEmpty && reasoning.isEmpty {
                Text("Thinking…")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .shimmer(active: true)
                    .padding(.vertical, 4)
            } else if !content.isEmpty {
                if isStreaming {
                    StreamingMarkdownView(text: content)
                } else {
                    Markdown(content)
                        .markdownTheme(.gitHub)
                        .textSelection(.enabled)
                }
            }

            if message.status == .failed {
                errorBanner
            }

            if message.backend == .onDevice, !isStreaming, let reason = message.routeReason, reason.prefersCloud {
                Label(
                    "A cloud model may answer this better: \(reason.explanation)."
                        + (cloudAvailable ? "" : " Choose a cloud model to use it."),
                    systemImage: "info.circle"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let backend = message.backend {
                BackendBadge(kind: backend, providerName: providerName, model: message.model, reason: message.routeReason)
            }

            if !isStreaming {
                footer
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Consent

    private var consentCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Send to the cloud?", systemImage: "cloud")
                .font(.subheadline.weight(.semibold))

            Text("This request is better handled by \(cloudLabel) because \(message.routeReason?.explanation ?? "it needs a more capable model"). The conversation will be sent to that provider, and this chat won't ask again.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Send") { onConsent?(.allow) }
                    .buttonStyle(.borderedProminent)
                Button("Answer on-device") { onConsent?(.answerOnDevice) }
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)

        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var errorBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message.error ?? "Something went wrong.")
                .font(.callout)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(message.createdAt, format: .dateTime.hour().minute())
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if message.status == .cancelled {
                Text("Stopped")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let stats = message.stats {
                HStack(spacing: 4) {
                    if stats.isEstimated {
                        Text("≈")
                    }
                    Text("\(stats.tokens) tokens")

                    if let rate = stats.tokensPerSecond {
                        Text("·")
                        Text(String(format: "%.1f t/s", rate))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer()

            if !message.content.isEmpty {
                Button {
                    UIPasteboard.general.string = message.content
                    withAnimation { copied = true }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { copied = false }
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(copied ? .green : .secondary)
                }
                .buttonStyle(.plain)
            }

            if let onAskCloud {
                Button(action: onAskCloud) {
                    Label("Ask cloud", systemImage: "cloud")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if let onRegenerate = onRegenerate {
                Button(action: onRegenerate) {
                    Label(message.status == .failed ? "Retry" : "Regenerate", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
    }
}

// MARK: - Backend Badge

/// Shows who generated a reply: the on-device model or a cloud provider and model.
struct BackendBadge: View {
    let kind: BackendKind
    let providerName: String?
    let model: String?
    var reason: RouteReason?

    @State private var showingReason = false

    var body: some View {
        Button {
            showingReason = true
        } label: {
            label
        }
        .buttonStyle(.plain)
        .disabled(reason == nil)
        .popover(isPresented: $showingReason) {
            Text(reasonText)
                .font(.callout)
                .padding()
                .presentationCompactAdaptation(.popover)
        }
    }

    private var reasonText: String {
        guard let reason else { return "" }
        let prefix = kind == .onDevice ? "Answered on-device" : "Sent to the cloud"
        return "\(prefix): \(reason.explanation)."
    }

    private var label: some View {
        Label(title, systemImage: kind == .onDevice ? "iphone" : "cloud")
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.12))
            .clipShape(Capsule())
            .accessibilityLabel(kind == .onDevice ? "Answered on device" : "Answered by \(title)")
    }

    private var title: String {
        switch kind {
        case .onDevice:
            return "On-device"
        case .cloud:
            return [providerName, model].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "Cloud"
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Streaming Markdown

/// Renders a growing Markdown document without re-parsing it all on every update:
/// completed blocks are memoized and only the trailing block is re-rendered.
struct StreamingMarkdownView: View {
    let text: String

    var body: some View {
        let (stable, tail) = Self.split(text)
        VStack(alignment: .leading, spacing: 12) {
            if !stable.isEmpty {
                MarkdownChunk(text: stable).equatable()
            }
            if !tail.isEmpty {
                MarkdownChunk(text: tail)
            }
        }
    }

    /// Splits at the last blank line that is not inside a fenced code block.
    static func split(_ text: String) -> (stable: String, tail: String) {
        var searchEnd = text.endIndex
        while let range = text.range(of: "\n\n", options: .backwards, range: text.startIndex..<searchEnd) {
            let prefix = text[..<range.lowerBound]
            let fenceCount = prefix.components(separatedBy: "```").count - 1
            if fenceCount % 2 == 0 {
                return (String(prefix), String(text[range.upperBound...]))
            }
            searchEnd = range.lowerBound
        }
        return ("", text)
    }
}

private struct MarkdownChunk: View, Equatable {
    let text: String

    var body: some View {
        Markdown(text)
            .markdownTheme(.gitHub)
    }
}
