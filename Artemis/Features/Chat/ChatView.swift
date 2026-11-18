import SwiftUI
import os

public struct ChatView: View {
    public let chatId: String

    @State private var chat: Chat?
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

    private let chatService = ChatService.shared
    private let database = AppDatabase.shared
    private static let logger = Logger(subsystem: "com.artemis.ios", category: "ChatView")

    public init(chatId: String) {
        self.chatId = chatId
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
                    LazyVStack(spacing: 12) {
                        ForEach(messages) { msg in
                            MessageBubbleView(
                                message: msg,
                                live: chatService.liveState(chatId: chatId, messageId: msg.id),
                                providerName: providers.first { $0.id == msg.providerId }?.name,
                                onRegenerate: msg.role == .assistant && !isBusy ? { regenerate(from: msg) } : nil
                            )
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("scroll_bottom")
                    }
                    .padding(.vertical, 12)
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
                currentModel: routeLabel,
                currentPresetTitle: selectedPreset?.title,
                onSend: sendCurrentMessage,
                onStop: { chatService.cancel(chatId: chatId) },
                onSelectModel: { showingModelPicker = true }
            )
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(chat?.title ?? "Chat")
                        .font(.headline)
                        .lineLimit(1)
                    if !routeLabel.isEmpty {
                        Text(routeLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .sheet(isPresented: $showingModelPicker) {
            modelPickerSheet
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
        .task { loadDefaults() }
        .onChange(of: showingModelPicker) { _, showing in
            if showing { onDeviceStatus = .current }
        }
    }

    // MARK: - Observation

    private func observeChat() async {
        do {
            for try await value in database.observeChat(id: chatId) {
                chat = value
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

    private func loadDefaults() {
        settings = (try? database.fetchSettings()) ?? AppSettings()
        onDeviceStatus = .current
        if replyTargetIsOnDevice {
            OnDeviceModel.prewarm()
        }
        guard let presetId = settings.defaultPresetId else { return }
        selectedPreset = try? database.fetchPresets().first { $0.id == presetId }
    }

    private var replyTargetIsOnDevice: Bool {
        if case .onDevice = replyTarget { return true }
        return false
    }

    /// Picks the chat's saved model, falling back to the default provider. Keeps a valid current choice.
    private func resolveSelection() {
        // Wait for the chat so its saved model wins over the defaults.
        guard chat != nil else { return }
        if let current = selectedProvider, current.models.isEmpty || current.models.contains(selectedModel) {
            return
        }

        if let chat, let providerId = chat.providerId, let model = chat.model, !model.isEmpty,
           providers.contains(where: { $0.id == providerId }) {
            selectedProviderId = providerId
            selectedModel = model
            return
        }

        let defaultId = (try? database.fetchSettings())?.defaultProviderId
        guard let provider = providers.first(where: { $0.id == defaultId }) ?? providers.first else {
            selectedProviderId = nil
            selectedModel = ""
            return
        }
        selectedProviderId = provider.id
        selectedModel = provider.defaultModel.isEmpty ? (provider.models.first ?? "") : provider.defaultModel
    }

    private func selectModel(_ model: String, of provider: Provider) {
        selectedProviderId = provider.id
        selectedModel = model
        do {
            try database.setChatModel(chatId: chatId, providerId: provider.id, model: model)
        } catch {
            Self.logger.error("Failed to save chat model: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Persists an explicit choice of the on-device model (or clears it back to the cloud model).
    private func selectOnDevice() {
        setRoutingMode(.onDevice)
        OnDeviceModel.prewarm()
    }

    private func setRoutingMode(_ mode: RoutingMode?) {
        chat?.routingMode = mode
        do {
            try database.setChatRoutingMode(chatId: chatId, mode: mode)
        } catch {
            Self.logger.error("Failed to save routing mode: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Actions

    /// Who answers the next message. Until the router exists (stage 3), Auto prefers the selected
    /// cloud model and falls back to on-device when no provider is configured.
    private var replyTarget: ReplyTarget? {
        let cloud = selectedProvider.flatMap { provider in
            selectedModel.isEmpty ? nil : ReplyTarget.cloud(provider, model: selectedModel)
        }
        switch chat?.routingMode ?? settings.routingMode {
        case .onDevice:
            return isOnDeviceUsable ? .onDevice : nil
        case .cloud:
            return cloud
        case .auto:
            return cloud ?? (isOnDeviceUsable ? .onDevice : nil)
        }
    }

    private var isOnDeviceUsable: Bool {
        settings.onDeviceEnabled && onDeviceStatus.isAvailable
    }

    private var routeLabel: String {
        switch replyTarget {
        case .onDevice: "On-device"
        case .cloud(_, let model): model
        case nil: ""
        }
    }

    private func sendCurrentMessage() {
        guard let target = replyTarget else {
            showingModelPicker = true
            return
        }

        let prompt = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try chatService.send(
                chatId: chatId,
                content: prompt,
                attachments: attachments,
                target: target,
                preset: selectedPreset
            )
            inputText = ""
            attachments = []
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func regenerate(from message: Message) {
        guard let target = replyTarget else {
            showingModelPicker = true
            return
        }
        do {
            try chatService.regenerate(
                chatId: chatId,
                fromMessageId: message.id,
                target: target,
                preset: selectedPreset
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Model Picker Sheet
    private var modelPickerSheet: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        selectOnDevice()
                        showingModelPicker = false
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        HStack {
                            Label("Apple Intelligence", systemImage: "iphone")
                                .foregroundStyle(isOnDeviceUsable ? .primary : .secondary)
                            Spacer()
                            if chat?.routingMode == .onDevice {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .disabled(!isOnDeviceUsable)
                } header: {
                    Text("On-device")
                } footer: {
                    Text(settings.onDeviceEnabled ? onDeviceStatus.detail : "The on-device model is turned off in Settings.")
                }

                if providers.isEmpty {
                    Section("Cloud") {
                        Text("Add a provider in Settings to use cloud models.")
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(providers) { provider in
                    Section(header: Text(provider.name)) {
                        ForEach(provider.models, id: \.self) { model in
                            Button {
                                selectModel(model, of: provider)
                                setRoutingMode(.cloud)
                                showingModelPicker = false
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            } label: {
                                HStack {
                                    Text(model)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if chat?.routingMode != .onDevice && selectedProviderId == provider.id && selectedModel == model {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Select Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showingModelPicker = false }
                }
            }
        }
    }
}
