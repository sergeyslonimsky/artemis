import SwiftUI

struct ChatView: View {
    /// Shows the chat list; `nil` when it is always visible (the iPad sidebar).
    var onOpenDrawer: (() -> Void)?
    var onNewChat: () -> Void = {}
    /// Focus of the composer's text field, owned by the screen so the drawer can dismiss the keyboard.
    var composerFocus: FocusState<Bool>.Binding

    @State private var session: ChatSessionModel
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var confirmedDrafts = 0

    /// Lines stay readable on iPad and in wide windows.
    private static let readableWidth: CGFloat = 760

    init(
        chatId: String,
        composerFocus: FocusState<Bool>.Binding,
        onOpenDrawer: (() -> Void)? = nil,
        onNewChat: @escaping () -> Void = {}
    ) {
        _session = State(initialValue: ChatSessionModel(chatId: chatId))
        self.composerFocus = composerFocus
        self.onOpenDrawer = onOpenDrawer
        self.onNewChat = onNewChat
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                ForEach(session.messages) { message in
                    bubble(for: message)
                }

                if session.isRouting {
                    Text("Choosing model…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .shimmer()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 16)
            .frame(maxWidth: Self.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition($scrollPosition)
        // Stays pinned to the bottom while a reply streams in.
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
        .overlay {
            if session.messages.isEmpty && !session.isBusy {
                emptyState
            }
        }
        .onChange(of: session.messages.last?.id) {
            withAnimation { scrollPosition.scrollTo(edge: .bottom) }
        }
        // Messages scroll under the glass composer.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ComposerView(
                text: $session.inputText,
                attachments: $session.attachments,
                focus: composerFocus,
                isBusy: session.isBusy,
                currentPresetTitle: session.selectedPreset?.title,
                onSend: session.send,
                onStop: session.stop,
                onFocus: session.prewarmIfUseful,
                onVoice: session.startVoice
            )
            .frame(maxWidth: Self.readableWidth)
        }
        .fullScreenCover(item: $session.voiceSession) { voice in
            VoiceModeView(session: voice)
        }
        .sheet(item: $session.draftSheet) { sheet in
            DraftSheetView(sheet: sheet) { completed in
                if session.finishDraftSheet(sheet, completed: completed) {
                    confirmedDrafts += 1
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(isPresented: $session.isShowingModelPicker) {
            ModelPickerSheet(session: session)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .errorAlert("Couldn't send message", message: $session.errorMessage)
        .sensoryFeedback(.success, trigger: confirmedDrafts)
        .task { await session.observeChat() }
        .task { await session.observeMessages() }
        .task { await session.observeProviders() }
        .task { await session.observeSettings() }
        .task { await session.observePresets() }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let onOpenDrawer {
            ToolbarItem(placement: .topBarLeading) {
                Button("Chats", systemImage: "line.3.horizontal", action: onOpenDrawer)
            }
        }
        ToolbarItem(placement: .principal) {
            Button {
                session.isShowingModelPicker = true
            } label: {
                HStack(spacing: 4) {
                    Text(session.routeTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Model: \(session.routeAccessibilityLabel)")
        }
        // With the sidebar showing, its own New chat button is enough.
        if onOpenDrawer != nil {
            ToolbarItem(placement: .topBarTrailing) {
                Button("New chat", systemImage: "square.and.pencil", action: onNewChat)
                    .disabled(session.messages.isEmpty)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("What can I help with?")
                .font(.title2.weight(.semibold))
            Label(session.emptyStateHint, systemImage: session.effectiveMode == .cloud ? "cloud" : "lock.iphone")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
        .accessibilityElement(children: .combine)
        .allowsHitTesting(false)
    }

    private func bubble(for message: Message) -> some View {
        MessageBubbleView(
            message: message,
            live: session.liveState(for: message),
            providerName: session.providerName(for: message),
            onRegenerate: session.canRegenerate(message) ? { session.regenerate(message) } : nil,
            onAskCloud: session.canAskCloud(message) ? { session.askCloud(message) } : nil,
            onConsent: { session.resolveConsent(message, choice: $0) },
            cloudAvailable: session.cloudTarget != nil,
            onDraft: { draft, confirm in
                Task {
                    if await session.resolveDraft(draft, in: message, confirm: confirm) {
                        confirmedDrafts += 1
                    }
                }
            },
            onEditDraft: { session.editDraft($0, in: message) }
        )
    }
}
