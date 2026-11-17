import SwiftUI
import MarkdownUI

public struct MessageBubbleView: View {
    public let message: Message
    public var isStreaming: Bool = false
    public var onRegenerate: (() -> Void)?

    @State private var copied: Bool = false

    public init(
        message: Message,
        isStreaming: Bool = false,
        onRegenerate: (() -> Void)? = nil
    ) {
        self.message = message
        self.isStreaming = isStreaming
        self.onRegenerate = onRegenerate
    }

    public var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            if message.role == .user {
                userBubble
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

            Text(timeFormatter.string(from: message.createdAt))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.trailing, 4)
        }
    }

    // MARK: - Assistant Bubble
    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Reasoning box
            if !message.reasoning.isEmpty || (isStreaming && message.content.isEmpty) {
                ReasoningView(
                    text: message.reasoning,
                    isStreaming: isStreaming && message.content.isEmpty,
                    durationMs: message.stats?.durationMs
                )
            }

            // Main Content
            if isStreaming && message.content.isEmpty && message.reasoning.isEmpty {
                Text("Thinking…")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .shimmer(active: true)
                    .padding(.vertical, 4)
            } else if !message.content.isEmpty {
                Markdown(message.content)
                    .markdownTheme(.gitHub)
                    .textSelection(.enabled)
            }

            // Footer with stats and actions
            if !isStreaming {
                HStack(spacing: 12) {
                    Text(timeFormatter.string(from: message.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    if let stats = message.stats {
                        HStack(spacing: 4) {
                            if stats.isEstimated {
                                Text("≈")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Text("\(stats.tokens) tokens")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)

                            if let rate = stats.tokensPerSecond {
                                Text("·")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text(String(format: "%.1f t/s", rate))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

                    Spacer()

                    // Copy action
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

                    // Regenerate action
                    if let onRegenerate = onRegenerate {
                        Button(action: onRegenerate) {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timeFormatter: DateFormatter {
        let df = DateFormatter()
        df.timeStyle = .short
        return df
    }
}
