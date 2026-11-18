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
    /// Confirm (`true`) or dismiss a drafted event/reminder.
    public var onDraft: ((ActionDraft, Bool) -> Void)?

    @State private var copied = false
    @State private var showingTextSelection = false

    public init(
        message: Message,
        live: ChatRunState? = nil,
        providerName: String? = nil,
        onRegenerate: (() -> Void)? = nil,
        onAskCloud: (() -> Void)? = nil,
        onConsent: ((ConsentChoice) -> Void)? = nil,
        cloudAvailable: Bool = true,
        onDraft: ((ActionDraft, Bool) -> Void)? = nil
    ) {
        self.message = message
        self.live = live
        self.providerName = providerName
        self.onRegenerate = onRegenerate
        self.onAskCloud = onAskCloud
        self.onConsent = onConsent
        self.cloudAvailable = cloudAvailable
        self.onDraft = onDraft
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
        .sheet(isPresented: $showingTextSelection) {
            TextSelectionSheet(text: message.content)
        }
    }

    // MARK: - User

    private var userMessage: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if !message.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(message.attachments) { attachment in
                            AttachmentCardView(attachment: attachment)
                        }
                    }
                }
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
                        .background(
                            Color(uiColor: .secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                        )
                        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 22, style: .continuous))
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
                    .shimmer(active: true)
            } else if isStreaming && content.isEmpty && reasoning.isEmpty {
                Text("Thinking…")
                    .foregroundStyle(.secondary)
                    .shimmer(active: true)
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
                .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contextMenu { if !isStreaming { textActions } }
                .padding(-8)
            }

            if !isStreaming {
                ForEach(message.extras.drafts) { draft in
                    DraftCard(draft: draft) { confirm in onDraft?(draft, confirm) }
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
        Button {
            copy()
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        Button {
            showingTextSelection = true
        } label: {
            Label("Select Text", systemImage: "selection.pin.in.out")
        }
        if let onRegenerate, message.role == .assistant {
            Button(action: onRegenerate) {
                Label("Regenerate", systemImage: "arrow.clockwise")
            }
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
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// A drafted event or reminder; nothing is saved until the user taps Add.
private struct DraftCard: View {
    let draft: ActionDraft
    let onDecision: (Bool) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(draft.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let body = draft.body, !body.isEmpty {
                    Text("“\(body)”")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }

            Spacer(minLength: 8)

            switch draft.status {
            case .pending:
                VStack(spacing: 6) {
                    Button(confirmTitle) { onDecision(true) }
                        .buttonStyle(.borderedProminent)
                    Button("Dismiss") { onDecision(false) }
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
                .controlSize(.small)
                .buttonBorderShape(.capsule)
            case .added:
                Label(doneTitle, systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            case .dismissed:
                Text("Dismissed")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var icon: String { DraftPresentation.icon(for: draft) }
    private var confirmTitle: String { DraftPresentation.confirmTitle(for: draft) }
    private var doneTitle: String { DraftPresentation.doneTitle(for: draft) }
    private var detailText: String { DraftPresentation.detail(for: draft) }
}

/// How drafts read in the chat and in voice mode.
enum DraftPresentation {
    static func icon(for draft: ActionDraft) -> String {
        switch draft.kind {
        case .event: "calendar.badge.plus"
        case .reminder: "checklist"
        case .alarm: "alarm"
        case .timer: "timer"
        case .call: "phone"
        case .message: "message"
        case .email: "envelope"
        }
    }

    static func confirmTitle(for draft: ActionDraft) -> String {
        switch draft.kind {
        case .event: "Add"
        case .reminder: "Remind"
        case .alarm, .timer: "Set"
        case .call: "Call"
        case .message, .email: "Write"
        }
    }

    static func doneTitle(for draft: ActionDraft) -> String {
        switch draft.kind {
        case .event, .reminder: "Added"
        case .alarm, .timer: "Set"
        case .call: "Called"
        case .message, .email: "Opened"
        }
    }

    static func detail(for draft: ActionDraft) -> String {
        switch draft.kind {
        case .event, .reminder:
            let kind = draft.kind == .event ? "Event" : "Reminder"
            guard draft.hasTime else {
                return "\(kind) · \(draft.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))"
            }
            var text = "\(kind) · \(draft.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))"
            if draft.kind == .event, draft.durationMinutes > 0 {
                let end = draft.date.addingTimeInterval(TimeInterval(draft.durationMinutes * 60))
                text += "–" + end.formatted(date: .omitted, time: .shortened)
            }
            return text
        case .alarm:
            let day = Calendar.current.isDateInToday(draft.date) ? "Today"
                : Calendar.current.isDateInTomorrow(draft.date) ? "Tomorrow"
                : draft.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            let text = "Alarm · \(day), \(draft.date.formatted(date: .omitted, time: .shortened))"
            // AlarmKit alarms ring like Clock alarms but aren't listed in the Clock app.
            return draft.status == .added ? text + " · see Settings, not Clock" : text
        case .timer:
            let length = Duration.seconds(draft.durationMinutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide))
            return "Timer · \(length)"
        case .call:
            return "Call · \(draft.address ?? "")"
        case .message:
            return "Message · \(draft.address ?? "")"
        case .email:
            return "Email · \(draft.address ?? "")"
        }
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
        var text = "\(stats.isEstimated ? "≈" : "")\(stats.tokens) tokens"
        if let rate = stats.tokensPerSecond {
            text += " · " + String(format: "%.1f tokens/s", rate)
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
            .background(Color.secondary.opacity(0.1), in: Capsule())
            .accessibilityLabel(kind == .onDevice ? "Answered on device" : "Answered by \(title)")
    }

    /// Model name without the vendor prefix (`openai/gpt-4o` → `gpt-4o`).
    private var shortTitle: String {
        guard kind == .cloud, let model else { return title }
        return model.split(separator: "/").last.map(String.init) ?? model
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
