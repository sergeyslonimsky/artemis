import SwiftUI

/// Full-screen voice conversation, like ChatGPT's voice mode.
struct VoiceModeView: View {
    @State var session: VoiceSession
    @Environment(\.dismiss) private var dismiss
    @State private var locales: [Locale] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                languageMenu
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            Spacer()

            VoiceOrb(state: session.state, level: session.level)
                .frame(width: 220, height: 220)
                .contentShape(Circle())
                .onTapGesture { session.interrupt() }
                .accessibilityLabel(statusText)
                .accessibilityHint(session.state == .speaking ? "Double-tap to stop the reply" : "")

            VStack(spacing: 10) {
                Text(statusText)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.easeInOut, value: statusText)

                captionText
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .lineLimit(5)
                    .frame(minHeight: 110, alignment: .top)
                    .padding(.horizontal, 32)
            }
            .padding(.top, 36)

            Spacer()

            if let pending = session.pendingDraft {
                VoiceDraftCard(draft: pending.draft) { confirm in
                    session.resolveDraft(confirm: confirm)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if session.state == .needsConsent {
                consentCard
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            controls
                .padding(.bottom, 24)
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .animation(.spring(duration: 0.35), value: session.state)
        .animation(.spring(duration: 0.35), value: session.pendingDraft)
        .task {
            await session.start()
            locales = await VoiceSession.suggestedLocales(current: session.locale)
        }
        .sheet(item: $session.draftSheet) { sheet in
            DraftSheetView(sheet: sheet) { completed in
                session.finishDraftSheet(sheet, completed: completed)
            }
        }
        .onDisappear {
            Task { await session.stop() }
        }
    }

    // MARK: - Text

    private var statusText: String {
        switch session.state {
        case .preparing(let message): message
        case .listening: session.isMuted ? "Microphone is off" : "Listening"
        case .thinking: "Thinking…"
        case .speaking: "Tap to interrupt"
        case .needsConsent: "Needs a cloud model"
        case .failed: "Voice isn't available"
        }
    }

    @ViewBuilder
    private var captionText: some View {
        switch session.state {
        case .failed(let message):
            VStack(spacing: 16) {
                Text(message).foregroundStyle(.secondary)
                if VoicePreferences.isMicrophoneDenied {
                    OpenSettingsButton()
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                }
            }
        case .speaking, .needsConsent:
            Text(session.transcript.isEmpty ? session.spokenReply : session.transcript)
                .foregroundStyle(session.transcript.isEmpty ? .primary : .secondary)
        case .listening, .thinking:
            Text(session.transcript)
                .foregroundStyle(.primary)
        case .preparing:
            Text("")
        }
    }

    // MARK: - Controls

    private var controls: some View {
        GlassEffectContainer(spacing: 48) {
            HStack(spacing: 48) {
                controlButton(
                    session.isMuted ? "Unmute" : "Mute",
                    systemImage: session.isMuted ? "mic.slash.fill" : "mic.fill",
                    foreground: session.isMuted ? Color(uiColor: .systemBackground) : .primary,
                    tint: session.isMuted ? .primary : nil
                ) {
                    session.isMuted.toggle()
                }

                controlButton("End voice mode", systemImage: "xmark", foreground: .white, tint: .red) {
                    dismiss()
                }
            }
        }
        .sensoryFeedback(.selection, trigger: session.isMuted)
    }

    /// A 64-pt glass circle; both controls share it so they line up exactly.
    private func controlButton(
        _ title: LocalizedStringKey,
        systemImage: String,
        foreground: Color,
        tint: Color?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.title2.weight(.semibold))
                .foregroundStyle(foreground)
                .frame(width: 64, height: 64)
                .glassEffect(.regular.tint(tint).interactive(), in: .circle)
        }
        .buttonStyle(.plain)
    }

    private var languageMenu: some View {
        Menu {
            Picker("Spoken language", selection: Binding(
                get: { session.locale.identifier },
                set: { identifier in
                    guard let locale = locales.first(where: { $0.identifier == identifier }) else { return }
                    Task { await session.setLocale(locale) }
                }
            )) {
                ForEach(locales, id: \.identifier) { locale in
                    Text(locale.displayName).tag(locale.identifier)
                }
            }
        } label: {
            Label(session.locale.displayName, systemImage: "globe")
                .font(.subheadline.weight(.medium))
        }
        .buttonStyle(.glass)
        .accessibilityLabel("Spoken language")
    }

    private var consentCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(session.consent?.routeReason.map { "A cloud model would answer better: \($0.explanation)." }
                ?? "This needs a cloud model.")
                .font(.subheadline)
            HStack {
                Button("Keep on-device") { session.resolveConsent(allow: false) }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Allow for this chat") { session.resolveConsent(allow: true) }
                    .buttonStyle(.borderedProminent)
            }
            .buttonBorderShape(.capsule)
        }
        .cardBackground()
    }
}

/// The reply's drafted action; "yes" or a tap confirms it.
private struct VoiceDraftCard: View {
    let draft: ActionDraft
    let onDecision: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                DraftSummary(draft: draft)
                Spacer(minLength: 0)
            }
            HStack {
                Button("Dismiss") { onDecision(false) }
                    .buttonStyle(.bordered)
                Spacer()
                Text("or say “yes”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(draft.kind.confirmTitle) { onDecision(true) }
                    .buttonStyle(.borderedProminent)
            }
            .buttonBorderShape(.capsule)
        }
        .cardBackground()
    }
}

/// A soft orb that breathes with the voice: the user's while listening, the reply's while speaking.
private struct VoiceOrb: View {
    let state: VoiceSession.State
    let level: Float

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let pulse = state == .thinking ? 0.06 * sin(time * 3) : 0
            let scale = 0.82 + 0.25 * Double(level) + pulse

            ZStack {
                Circle()
                    .fill(gradient(time: time))
                    .blur(radius: 18)
                    .opacity(0.45)
                    .scaleEffect(scale * 1.12)
                Circle()
                    .fill(gradient(time: time))
                    .overlay(
                        Circle()
                            .fill(.white.opacity(0.25))
                            .blur(radius: 24)
                            .offset(x: -30, y: -40)
                            .mask(Circle())
                    )
                    .scaleEffect(scale)
            }
            .opacity(isDimmed ? 0.35 : 1)
            .animation(.easeOut(duration: 0.12), value: level)
        }
    }

    private var isDimmed: Bool {
        switch state {
        case .preparing, .failed: true
        default: false
        }
    }

    private func gradient(time: TimeInterval) -> AngularGradient {
        let colors: [Color] = state == .speaking
            ? [.blue, .cyan, .mint, .blue]
            : [.indigo, .blue, .cyan, .indigo]
        return AngularGradient(colors: colors, center: .center, angle: .degrees(time * 40))
    }
}
