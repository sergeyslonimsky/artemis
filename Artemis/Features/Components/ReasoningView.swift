import SwiftUI

/// The model's reasoning, collapsed under "Thought for 2.3s". It opens by itself while the model
/// thinks and closes when the answer starts, unless the user opened or closed it themselves.
struct ReasoningView: View {
    let text: String
    var isStreaming = false
    var durationMs: Int?

    @State private var isExpanded = false
    @State private var userDecided = false

    var body: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { isExpanded },
            set: { newValue in
                userDecided = true
                isExpanded = newValue
            }
        )) {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.primary.opacity(0.15))
                    .frame(width: 2)

                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 2)
        } label: {
            Label {
                Text(title)
                    .shimmer(active: isStreaming)
            } icon: {
                Image(systemName: "brain.head.profile")
            }
        }
        .disclosureGroupStyle(.reasoning)
        .padding(.vertical, 4)
        .sensoryFeedback(.impact(weight: .light), trigger: isExpanded) { _, _ in userDecided }
        .onChange(of: isStreaming, initial: true) { _, streaming in
            guard !userDecided else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                isExpanded = streaming
            }
        }
    }

    private var title: String {
        if isStreaming { return "Thinking…" }
        guard let durationMs, durationMs > 0 else { return "Thought process" }
        let seconds = Duration.milliseconds(durationMs)
            .formatted(.units(allowed: [.seconds], width: .narrow, fractionalPart: .show(length: 1)))
        return "Thought for \(seconds)"
    }
}

/// A compact caption-sized row with a rotating chevron; the content slides in below.
private struct ReasoningDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    configuration.label
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")

            if configuration.isExpanded {
                configuration.content
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

extension DisclosureGroupStyle where Self == ReasoningDisclosureStyle {
    fileprivate static var reasoning: ReasoningDisclosureStyle { ReasoningDisclosureStyle() }
}
