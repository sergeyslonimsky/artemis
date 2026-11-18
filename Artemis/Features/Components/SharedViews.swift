import SwiftUI
import UIKit

// MARK: - Error alert

extension View {
    /// Shows `message` in an alert while it is non-`nil` and clears it when dismissed.
    func errorAlert(_ title: LocalizedStringKey, message: Binding<String?>) -> some View {
        alert(
            title,
            isPresented: Binding(get: { message.wrappedValue != nil }, set: { if !$0 { message.wrappedValue = nil } }),
            presenting: message.wrappedValue
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { text in
            Text(text)
        }
    }

    /// The app's rounded card: secondary background with continuous corners.
    func cardBackground(cornerRadius: CGFloat = 20, padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - Buttons

/// Opens the app's page in the Settings app (permissions, notifications).
struct OpenSettingsButton: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button("Open Settings") {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                openURL(url)
            }
        }
    }
}

// MARK: - Badges

/// A small tinted capsule, e.g. "Default" next to a provider.
struct TagBadge: View {
    let text: LocalizedStringKey
    var tint = Color.accentColor

    init(_ text: LocalizedStringKey, tint: Color = .accentColor) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: .capsule)
            .foregroundStyle(tint)
    }
}

// MARK: - Drafts

/// Icon, title and when/who of a drafted action; shared by the chat and voice cards.
struct DraftSummary: View {
    let draft: ActionDraft
    var showsBody = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: draft.kind.systemImage)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(draft.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(draft.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if showsBody, let body = draft.body, !body.isEmpty {
                    Text("“\(body)”")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}
