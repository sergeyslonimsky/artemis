import SwiftUI

public struct ReasoningView: View {
    public let text: String
    public let isStreaming: Bool
    public let durationMs: Int?

    @State private var isOpen: Bool = false
    @State private var userDecided: Bool = false

    public init(text: String, isStreaming: Bool = false, durationMs: Int? = nil) {
        self.text = text
        self.isStreaming = isStreaming
        self.durationMs = durationMs
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                userDecided = true
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isOpen.toggle()
                }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(labelTitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .shimmer(active: isStreaming)

                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            if isOpen {
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary.opacity(0.15))
                        .frame(width: 2)

                    Text(text)
                        .font(.system(size: 13, design: .default))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 4)
        .onChange(of: isStreaming) { _, streaming in
            if !userDecided {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isOpen = streaming
                }
            }
        }
        .onAppear {
            if isStreaming && !userDecided {
                isOpen = true
            }
        }
    }

    private var labelTitle: String {
        if isStreaming {
            return "Thinking…"
        } else if let ms = durationMs, ms > 0 {
            let seconds = String(format: "%.1f", Double(ms) / 1000.0)
            return "Thought for \(seconds)s"
        } else {
            return "Thought process"
        }
    }
}
