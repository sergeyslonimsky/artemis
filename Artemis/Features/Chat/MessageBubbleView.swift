import SwiftUI
import MarkdownUI

struct MessageBubbleView: View {
    let message: Message
    /// Live text from `ChatService` while the reply is generated.
    var live: ChatRunState? = nil
    /// Display name of `message.providerId`, if the provider still exists.
    var providerName: String? = nil
    var onRegenerate: (() -> Void)? = nil
    /// Re-answer an on-device reply with the cloud model; `nil` hides the action.
    var onAskCloud: (() -> Void)? = nil
    var onConsent: ((ConsentChoice) -> Void)? = nil
    /// Whether the chat has a cloud model to escalate to.
    var cloudAvailable = true
    /// Confirm (`true`) or dismiss a drafted event/reminder.
    var onDraft: ((ActionDraft, Bool) -> Void)? = nil
    /// Opens a drafted event in the calendar's editor.
    var onEditDraft: ((ActionDraft) -> Void)? = nil

    @State private var copied = false
    @State private var showingTextSelection = false

    private var cloudLabel: String {
        ModelName.label(provider: providerName, model: message.model) ?? "the cloud"
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

    var body: some View {
        Group {
            if message.role == .user {
                userMessage
            } else if message.status == .awaitingConsent {
                consentCard
            } else {
                assistantMessage
            }
        }
        .padding(.horizontal, 16)
        .sensoryFeedback(.impact(weight: .light), trigger: copied) { _, new in new }
        .sheet(isPresented: $showingTextSelection) {
            TextSelectionSheet(text: message.content)
        }
    }

    // MARK: - User

    private var userMessage: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if !message.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(message.attachments) { attachment in
                            AttachmentCardView(attachment: attachment)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .defaultScrollAnchor(.trailing)
                .scrollBounceBehavior(.basedOnSize)
            }

            if !message.content.isEmpty {
                HStack {
                    Spacer(minLength: 56)
                    Text(message.content)
                        .font(.body)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 22, style: .continuous))
                        .contentShape(.contextMenuPreview, .rect(cornerRadius: 22, style: .continuous))
                        .contextMenu { textActions }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: - Assistant

    private var assistantMessage: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !reasoning.isEmpty || (isStreaming && content.isEmpty) {
                ReasoningView(
                    text: reasoning,
                    isStreaming: isStreaming && content.isEmpty,
                    durationMs: message.stats?.durationMs
                )
            }

            if isStreaming && content.isEmpty, let activity = live?.activity {
                Label(activity.activityLabel, systemImage: activity.systemImage)
                    .foregroundStyle(.secondary)
                    .shimmer()
            } else if isStreaming && content.isEmpty && reasoning.isEmpty {
                Text("Thinking…")
                    .foregroundStyle(.secondary)
                    .shimmer()
            } else if !content.isEmpty {
                Group {
                    if isStreaming {
                        StreamingMarkdownView(text: content)
                    } else {
                        Markdown(content)
                            .markdownTheme(.artemis)
                    }
                }
                .padding(8)
                .background(Color(uiColor: .systemBackground))
                .contentShape(.contextMenuPreview, .rect(cornerRadius: 16, style: .continuous))
                .contextMenu { if !isStreaming { textActions } }
                .padding(-8)
            }

            if !isStreaming {
                ForEach(message.extras.drafts) { draft in
                    DraftCard(
                        draft: draft,
                        onDecision: { confirm in onDraft?(draft, confirm) },
                        onEdit: draft.kind == .event ? onEditDraft.map { edit in { edit(draft) } } : nil
                    )
                }
            }

            if !isStreaming, !message.extras.personalDataUsed.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { usedDataLabels }
                    VStack(alignment: .leading, spacing: 4) { usedDataLabels }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
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
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            if !isStreaming {
                actionBar
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var usedDataLabels: some View {
        ForEach(message.extras.personalDataUsed, id: \.self) { source in
            Label(source.usedLabel, systemImage: source.systemImage)
        }
        // Open-Meteo's license (CC BY 4.0) asks for attribution.
        if message.extras.personalDataUsed.contains(.weather) {
            Link("Weather data by Open-Meteo", destination: OpenMeteo.attributionURL)
                .underline()
        }
    }

    @ViewBuilder
    private var textActions: some View {
        Button("Copy", systemImage: "doc.on.doc", action: copy)
        Button("Select Text", systemImage: "selection.pin.in.out") { showingTextSelection = true }
        ShareLink(item: message.content)
        if let onRegenerate, message.role == .assistant {
            Button("Regenerate", systemImage: "arrow.clockwise", action: onRegenerate)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 2) {
            if !message.content.isEmpty {
                ActionIcon(systemName: copied ? "checkmark" : "doc.on.doc", label: "Copy", action: copy)
            }
            if let onRegenerate {
                ActionIcon(
                    systemName: "arrow.clockwise",
                    label: message.status == .failed ? "Retry" : "Regenerate",
                    action: onRegenerate
                )
            }
            if let onAskCloud {
                ActionIcon(systemName: "cloud", label: "Ask cloud", action: onAskCloud)
            }

            Spacer(minLength: 8)

            if message.status == .cancelled {
                Text("Stopped")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if let backend = message.backend {
                BackendBadge(
                    kind: backend,
                    providerName: providerName,
                    model: message.model,
                    reason: message.routeReason,
                    stats: message.stats
                )
            }
        }
        .padding(.leading, -8)
    }

    private func copy() {
        UIPasteboard.general.string = message.content
        withAnimation { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { copied = false }
        }
    }

    // MARK: - Consent

    private var consentCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Send to the cloud?", systemImage: "cloud")
                .font(.headline)

            Text("This is better handled by \(cloudLabel) because \(message.routeReason?.explanation ?? "it needs a more capable model"). The conversation will be sent to that provider, and this chat won't ask again.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    onConsent?(.allow)
                } label: {
                    Text("Send")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    onConsent?(.answerOnDevice)
                } label: {
                    Text("Keep on-device")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .buttonBorderShape(.capsule)
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private var errorBanner: some View {
        Label {
            Text(message.error ?? "Something went wrong.")
                .font(.subheadline)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 14, style: .continuous))
    }
}

/// A drafted action; nothing happens until the user confirms it.
private struct DraftCard: View {
    let draft: ActionDraft
    let onDecision: (Bool) -> Void
    /// Change the draft in a system editor before saving; `nil` when there is none.
    var onEdit: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            DraftSummary(draft: draft, showsBody: true)

            Spacer(minLength: 8)

            switch draft.status {
            case .pending:
                VStack(spacing: 6) {
                    Button(draft.kind.confirmTitle) { onDecision(true) }
                        .buttonStyle(.borderedProminent)
                    HStack(spacing: 10) {
                        if let onEdit {
                            Button("Edit", action: onEdit)
                        }
                        Button("Dismiss") { onDecision(false) }
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
                .controlSize(.small)
                .buttonBorderShape(.capsule)
            case .added:
                Label(draft.kind.doneTitle, systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            case .dismissed:
                Text("Dismissed")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .cardBackground(cornerRadius: 16, padding: 12)
    }
}

/// A borderless icon button for the assistant action bar.
private struct ActionIcon: View {
    let systemName: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Full message text in a sheet where any part can be selected, like ChatGPT's "Select Text".
private struct TextSelectionSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Select Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Backend Badge

/// Shows who generated a reply: the on-device model or a cloud provider and model.
struct BackendBadge: View {
    let kind: BackendKind
    let providerName: String?
    let model: String?
    var reason: RouteReason?
    var stats: MessageStats?

    @State private var showingDetails = false

    var body: some View {
        Button {
            showingDetails = true
        } label: {
            label
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingDetails) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if let reasonText {
                    Text(reasonText)
                        .font(.subheadline)
                }
                if let statsText {
                    Text(statsText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: 280, alignment: .leading)
            .presentationCompactAdaptation(.popover)
        }
    }

    private var reasonText: String? {
        guard let reason else { return nil }
        let prefix = kind == .onDevice ? "Answered on-device" : "Sent to the cloud"
        return "\(prefix): \(reason.explanation)."
    }

    private var statsText: String? {
        guard let stats else { return nil }
        var text = "\(stats.isEstimated ? "≈" : "")\(stats.tokens.formatted()) tokens"
        if let rate = stats.tokensPerSecond {
            text += " · \(rate.formatted(.number.precision(.fractionLength(1)))) tokens/s"
        }
        return text
    }

    private var label: some View {
        Label(shortTitle, systemImage: kind == .onDevice ? "iphone" : "cloud")
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.1), in: .capsule)
            .accessibilityLabel(kind == .onDevice ? "Answered on device" : "Answered by \(title)")
    }

    /// Model name without the vendor prefix (`openai/gpt-4o` → `gpt-4o`).
    private var shortTitle: String {
        guard kind == .cloud, let model else { return title }
        return ModelName(model).title
    }

    private var title: String {
        switch kind {
        case .onDevice:
            return "On-device"
        case .cloud:
            return ModelName.label(provider: providerName, model: model) ?? "Cloud"
        }
    }
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
            .markdownTheme(.artemis)
    }
}

extension Theme {
    /// GitHub styling for blocks, but body text on the system background at the system size
    /// (the GitHub theme paints its own background, which shows as a box in dark mode).
    @MainActor static let artemis = Theme.gitHub.text {
        ForegroundColor(.primary)
        FontSize(17)
    }
}
