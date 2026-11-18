import SwiftUI
import os

public struct ChatView: View {
    /// May not exist in the database yet: a draft is stored when its first message is sent.
    public let chatId: String
    public var onOpenDrawer: () -> Void
    public var onNewChat: () -> Void

    @State private var chat: Chat?
    @State private var chatLoaded = false
    /// Mode picked before a draft chat exists.
    @State private var draftMode: RoutingMode?
    @State private var messages: [Message] = []
    @State private var providers: [Provider] = []
    @State private var inputText: String = ""
    @State private var attachments: [Attachment] = []

    @State private var selectedProviderId: String?
    @State private var selectedModel: String = ""
    @State private var selectedPreset: Preset?
    @State private var showingModelPicker: Bool = false
    @State private var errorMessage: String?
    @State private var settings = AppSettings()
    @State private var onDeviceStatus = OnDeviceModelStatus.current
    @State private var voiceSession: VoiceSession?
    /// The user picked a model in this chat; until then a draft follows the defaults.
    @State private var userPickedModel = false
    @State private var recentModels: [ModelRef] = []
    @State private var presets: [Preset] = []

    private let chatService = ChatService.shared
    private let database = AppDatabase.shared
    private static let logger = Logger(subsystem: "com.artemis.ios", category: "ChatView")

    public init(chatId: String, onOpenDrawer: @escaping () -> Void = {}, onNewChat: @escaping () -> Void = {}) {
        self.chatId = chatId
        self.onOpenDrawer = onOpenDrawer
        self.onNewChat = onNewChat
    }

    private var selectedProvider: Provider? {
        providers.first { $0.id == selectedProviderId }
    }

    private var isBusy: Bool {
        chatService.isRunning(chatId: chatId)
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 20) {
                        ForEach(messages) { msg in
                            bubble(for: msg)
                        }

                        if chatService.isRouting(chatId: chatId) {
                            Text("Choosing model…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .shimmer(active: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("scroll_bottom")
                    }
                    .padding(.vertical, 16)
                }
                .overlay {
                    if messages.isEmpty && !isBusy {
                        emptyState
                    }
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages.last) { _, _ in
                    withAnimation { proxy.scrollTo("scroll_bottom", anchor: .bottom) }
                }
                .onChange(of: chatService.runs[chatId]?.content) { _, _ in
                    proxy.scrollTo("scroll_bottom", anchor: .bottom)
                }
                .onChange(of: chatService.runs[chatId]?.reasoning) { _, _ in
                    proxy.scrollTo("scroll_bottom", anchor: .bottom)
                }
            }

            ComposerView(
                text: $inputText,
                attachments: $attachments,
                isBusy: isBusy,
                currentPresetTitle: selectedPreset?.title,
                onSend: sendCurrentMessage,
                onStop: { chatService.cancel(chatId: chatId) },
                onFocus: {
                    // Apple: prewarm when a request is likely at least a second away, e.g. typing starts.
                    if effectiveMode != .cloud && isOnDeviceUsable {
                        OnDeviceModel.prewarm()
                    }
                },
                onVoice: startVoice
            )
            .fullScreenCover(item: $voiceSession) { session in
                VoiceModeView(session: session)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onOpenDrawer) {
                    Image(systemName: "line.3.horizontal")
                }
                .accessibilityLabel("Chats")
            }
            ToolbarItem(placement: .principal) {
                Button {
                    showingModelPicker = true
                } label: {
                    HStack(spacing: 4) {
                        Text(routeTitle)
                            .font(.headline)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Model: \(routeLabel)")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onNewChat) {
                    Image(systemName: "square.and.pencil")
                }
                .disabled(messages.isEmpty)
                .accessibilityLabel("New chat")
            }
        }
        .sheet(isPresented: $showingModelPicker) {
            modelPickerSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .alert(
            "Couldn't send message",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .task { await observeChat() }
        .task { await observeMessages() }
        .task { await observeProviders() }
        .task { await observeSettings() }
        .task { loadDefaults() }
        .onChange(of: showingModelPicker) { _, showing in
            if showing {
                onDeviceStatus = .current
                recentModels = (try? database.recentModels()) ?? []
                presets = (try? database.fetchPresets()) ?? []
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("What can I help with?")
                .font(.title2.weight(.semibold))
            Label(emptyStateHint, systemImage: effectiveMode == .cloud ? "cloud" : "lock.iphone")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
        .allowsHitTesting(false)
    }

    private var emptyStateHint: String {
        switch effectiveMode {
        case .onDevice: "Answered privately on this iPhone"
        case .cloud: "Answered by \(selectedModel.isEmpty ? "your cloud model" : selectedModel)"
        case .auto: "On-device first, cloud only when needed"
        }
    }

    private func bubble(for message: Message) -> some View {
        let canAct = message.role == .assistant && !isBusy
        // Replies built on calendar/reminders aren't offered to the cloud: it would only see a redaction.
        let canAskCloud = canAct && message.backend == .onDevice && cloudTarget != nil
            && !message.extras.usedPrivateData
        return MessageBubbleView(
            message: message,
            live: chatService.liveState(chatId: chatId, messageId: message.id),
            providerName: providers.first { $0.id == message.providerId }?.name,
            onRegenerate: canAct ? { perform { try chatService.regenerate(chatId: chatId, fromMessageId: message.id, route: routeRequest, preset: selectedPreset) } } : nil,
            onAskCloud: canAskCloud ? { perform { try chatService.askCloud(chatId: chatId, replacing: message.id, route: routeRequest, preset: selectedPreset) } } : nil,
            onConsent: { choice in resolveConsent(message, choice: choice) },
            cloudAvailable: cloudTarget != nil,
            onDraft: { draft, confirm in resolveDraft(draft, in: message, confirm: confirm) }
        )
    }

    // MARK: - Observation

    private func observeChat() async {
        do {
            for try await value in database.observeChat(id: chatId) {
                chat = value
                chatLoaded = true
                resolveSelection()
            }
        } catch {
            Self.logger.error("Chat observation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func observeMessages() async {
        do {
            for try await value in database.observeMessages(chatId: chatId) {
                messages = value
            }
        } catch {
            Self.logger.error("Messages observation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func observeProviders() async {
        do {
            for try await value in database.observeProviders() {
                providers = value
                resolveSelection()
            }
        } catch {
            Self.logger.error("Providers observation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func observeSettings() async {
        do {
            for try await value in database.observeSettings() {
                settings = value ?? AppSettings()
                resolveSelection()
            }
        } catch {
            Self.logger.error("Settings observation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadDefaults() {
        settings = (try? database.fetchSettings()) ?? AppSettings()
        onDeviceStatus = .current
        guard let presetId = settings.defaultPresetId else { return }
        selectedPreset = try? database.fetchPresets().first { $0.id == presetId }
    }

    /// Picks the chat's saved cloud model, falling back to the default provider. Keeps a valid current choice.
    private func resolveSelection() {
        // Wait for the chat so its saved model wins over the defaults.
        guard chatLoaded else { return }
        // A new chat follows the default provider until the user picks a model in it.
        let followsDefaults = chat == nil && !userPickedModel
        if !followsDefaults, let current = selectedProvider, current.models.isEmpty || current.models.contains(selectedModel) {
            return
        }

        if let chat, let providerId = chat.providerId, let model = chat.model, !model.isEmpty,
           providers.contains(where: { $0.id == providerId }) {
            selectedProviderId = providerId
            selectedModel = model
            return
        }

        let defaultId = settings.defaultProviderId
        guard let provider = providers.first(where: { $0.id == defaultId }) ?? providers.first else {
            selectedProviderId = nil
            selectedModel = ""
            return
        }
        selectedProviderId = provider.id
        selectedModel = provider.defaultModel.isEmpty ? (provider.models.first ?? "") : provider.defaultModel
    }

    private func selectModel(_ model: String, of provider: Provider) {
        userPickedModel = true
        selectedProviderId = provider.id
        selectedModel = model
        guard chat != nil else { return } // a draft saves its selection when it's created
        do {
            try database.setChatModel(chatId: chatId, providerId: provider.id, model: model)
        } catch {
            Self.logger.error("Failed to save chat model: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func setRoutingMode(_ mode: RoutingMode) {
        if chat == nil {
            draftMode = mode
        } else {
            chat?.routingMode = mode
            do {
                try database.setChatRoutingMode(chatId: chatId, mode: mode)
            } catch {
                Self.logger.error("Failed to save routing mode: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Routing

    private var effectiveMode: RoutingMode {
        chat?.routingMode ?? draftMode ?? settings.routingMode
    }

    private var cloudTarget: CloudTarget? {
        guard let provider = selectedProvider, !selectedModel.isEmpty else { return nil }
        return CloudTarget(provider: provider, model: selectedModel)
    }

    private var routeRequest: RouteRequest {
        RouteRequest(mode: effectiveMode, cloud: cloudTarget)
    }

    private var isOnDeviceUsable: Bool {
        settings.onDeviceEnabled && onDeviceStatus.isAvailable
    }

    /// Whether the next message has anyone to answer it.
    private var canSend: Bool {
        switch effectiveMode {
        case .onDevice: isOnDeviceUsable
        case .cloud: cloudTarget != nil
        case .auto: isOnDeviceUsable || cloudTarget != nil
        }
    }

    /// Compact title for the navigation bar.
    private var routeTitle: String {
        switch effectiveMode {
        case .onDevice: "On-device"
        case .auto: "Auto"
        case .cloud: selectedModel.split(separator: "/").last.map(String.init) ?? "Cloud"
        }
    }

    private var routeLabel: String {
        switch effectiveMode {
        case .onDevice:
            "On-device"
        case .cloud:
            selectedModel
        case .auto:
            cloudTarget.map { "Auto · \($0.model)" } ?? "Auto · On-device"
        }
    }

    // MARK: - Actions

    private func sendCurrentMessage() {
        guard canSend else {
            showingModelPicker = true
            return
        }

        let prompt = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        perform {
            if chat == nil {
                chat = try database.createChat(
                    id: chatId,
                    title: "New Chat",
                    routingMode: draftMode,
                    providerId: selectedProviderId,
                    model: selectedModel.isEmpty ? nil : selectedModel
                )
            }
            try chatService.send(
                chatId: chatId,
                content: prompt,
                attachments: attachments,
                route: routeRequest,
                preset: selectedPreset
            )
            inputText = ""
            attachments = []
        }
    }

    private func startVoice() {
        guard canSend else {
            showingModelPicker = true
            return
        }
        if effectiveMode != .cloud && isOnDeviceUsable {
            OnDeviceModel.prewarm()
        }
        voiceSession = VoiceSession(
            chatId: chatId,
            send: { text in
                if chat == nil {
                    chat = try database.createChat(
                        id: chatId,
                        title: "New Chat",
                        routingMode: draftMode,
                        providerId: selectedProviderId,
                        model: selectedModel.isEmpty ? nil : selectedModel
                    )
                }
                try chatService.send(chatId: chatId, content: text, route: routeRequest, preset: selectedPreset)
            },
            answerConsent: { consent, allow in
                resolveConsent(consent, choice: allow ? .allow : .answerOnDevice)
            }
        )
    }

    private func resolveConsent(_ consent: Message, choice: ConsentChoice) {
        perform {
            try chatService.resolveConsent(
                chatId: chatId,
                consent: consent,
                allow: choice == .allow,
                rememberForChat: choice == .allow,
                route: routeRequest,
                preset: selectedPreset
            )
        }
    }

    /// Carries out a drafted action only after the user confirms it.
    private func resolveDraft(_ draft: ActionDraft, in message: Message, confirm: Bool) {
        Task {
            do {
                try await DraftPerformer.resolve(draft, messageId: message.id, confirm: confirm)
                if confirm { UINotificationFeedbackGenerator().notificationOccurred(.success) }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Model Picker Sheet
    private var modelPickerSheet: some View {
        ModelPickerSheet(
            providers: providers,
            mode: effectiveMode,
            modeDescription: modeDescription,
            selection: selectedProviderId.map { ModelRef(providerId: $0, model: selectedModel) },
            favorites: settings.favoriteModels,
            recents: recentModels,
            presets: presets,
            presetId: selectedPreset?.id,
            onSelectPreset: { selectedPreset = $0 },
            onModeChange: setRoutingMode,
            onSelect: { provider, model in
                selectModel(model, of: provider)
                if effectiveMode == .onDevice {
                    setRoutingMode(.cloud)
                }
                showingModelPicker = false
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            },
            onToggleFavorite: toggleFavorite,
            onDone: { showingModelPicker = false }
        )
    }

    private func toggleFavorite(_ ref: ModelRef) {
        var updated = settings
        if let index = updated.favoriteModels.firstIndex(of: ref) {
            updated.favoriteModels.remove(at: index)
        } else {
            updated.favoriteModels.append(ref)
        }
        perform { try database.saveSettings(updated) }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private var modeDescription: String {
        let onDeviceNote = isOnDeviceUsable ? "" : " " + (settings.onDeviceEnabled ? onDeviceStatus.detail : "The on-device model is turned off in Settings.")
        switch effectiveMode {
        case .auto:
            return "Answers on-device and uses the cloud model below only when needed." + onDeviceNote
        case .onDevice:
            return "Everything stays on this device." + onDeviceNote
        case .cloud:
            return "Every message goes to the cloud model below."
        }
    }
}
