import SwiftUI

public struct ChatView: View {
    public let chatId: String
    @Environment(\.dismiss) private var dismiss

    @State private var messages: [Message] = []
    @State private var inputText: String = ""
    @State private var attachments: [Attachment] = []
    @State private var streamingContent: String = ""
    @State private var streamingReasoning: String = ""
    @State private var isStreaming: Bool = false

    @State private var providers: [Provider] = []
    @State private var selectedProvider: Provider?
    @State private var selectedModel: String = ""
    @State private var selectedPreset: Preset?
    @State private var showingModelPicker: Bool = false

    private let chatService = ChatService.shared
    private let database = AppDatabase.shared

    public init(chatId: String) {
        self.chatId = chatId
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Messages Scroll Area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(messages) { msg in
                            MessageBubbleView(
                                message: msg,
                                isStreaming: false,
                                onRegenerate: {
                                    regenerate(from: msg.id)
                                }
                            )
                        }

                        // Live Streaming Bubble
                        if isStreaming {
                            let liveMessage = Message(
                                chatId: chatId,
                                role: .assistant,
                                content: streamingContent,
                                reasoning: streamingReasoning
                            )
                            MessageBubbleView(message: liveMessage, isStreaming: true)
                                .id("bottom_anchor")
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("scroll_bottom")
                    }
                    .padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: streamingContent) { _, _ in
                    proxy.scrollTo("scroll_bottom", anchor: .bottom)
                }
                .onChange(of: streamingReasoning) { _, _ in
                    proxy.scrollTo("scroll_bottom", anchor: .bottom)
                }
            }

            // Floating Composer
            ComposerView(
                text: $inputText,
                attachments: $attachments,
                isBusy: isStreaming,
                currentModel: selectedModel,
                currentPresetTitle: selectedPreset?.title,
                onSend: sendCurrentMessage,
                onStop: {
                    chatService.cancel(chatId: chatId)
                    isStreaming = false
                },
                onSelectModel: {
                    showingModelPicker = true
                }
            )
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(chatTitle)
                        .font(.headline)
                        .lineLimit(1)
                    if !selectedModel.isEmpty {
                        Text(selectedModel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .sheet(isPresented: $showingModelPicker) {
            modelPickerSheet
        }
        .onAppear {
            loadChat()
        }
    }

    private var chatTitle: String {
        (try? database.fetchChat(id: chatId))?.title ?? "Chat"
    }

    private func loadChat() {
        do {
            messages = try database.fetchMessages(chatId: chatId)
            providers = try database.fetchProviders()
            let settings = try database.fetchSettings()

            if let defaultId = settings.defaultProviderId,
               let prov = providers.first(where: { $0.id == defaultId }) {
                selectedProvider = prov
                selectedModel = prov.defaultModel.isEmpty ? (prov.models.first ?? "") : prov.defaultModel
            } else if let first = providers.first {
                selectedProvider = first
                selectedModel = first.defaultModel.isEmpty ? (first.models.first ?? "") : first.defaultModel
            }

            if let presetId = settings.defaultPresetId {
                selectedPreset = try? database.fetchPresets().first(where: { $0.id == presetId })
            }
        } catch {
            print("Error loading chat: \(error)")
        }
    }

    private func sendCurrentMessage() {
        guard let provider = selectedProvider, !selectedModel.isEmpty else {
            showingModelPicker = true
            return
        }

        let prompt = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let atts = attachments

        inputText = ""
        attachments = []
        isStreaming = true
        streamingContent = ""
        streamingReasoning = ""

        // Optimistically add user message to list
        let optimisticUser = Message(chatId: chatId, role: .user, content: prompt, attachments: atts)
        messages.append(optimisticUser)

        chatService.send(
            chatId: chatId,
            content: prompt,
            attachments: atts,
            provider: provider,
            model: selectedModel,
            preset: selectedPreset,
            onDelta: { contentDelta, reasoningDelta in
                streamingContent += contentDelta
                streamingReasoning += reasoningDelta
            },
            onComplete: { result in
                isStreaming = false
                streamingContent = ""
                streamingReasoning = ""
                switch result {
                case .success(let finishedMessage):
                    messages.append(finishedMessage)
                case .failure(let error):
                    let errorMsg = Message(
                        chatId: chatId,
                        role: .assistant,
                        content: "⚠️ Error: \(error.localizedDescription)"
                    )
                    messages.append(errorMsg)
                }
            }
        )
    }

    private func regenerate(from messageId: String) {
        guard let provider = selectedProvider, !selectedModel.isEmpty else { return }
        do {
            try database.deleteMessagesFrom(chatId: chatId, messageId: messageId)
            messages = try database.fetchMessages(chatId: chatId)
            guard let lastUser = messages.last(where: { $0.role == .user }) else { return }

            isStreaming = true
            streamingContent = ""
            streamingReasoning = ""

            chatService.send(
                chatId: chatId,
                content: lastUser.content,
                attachments: lastUser.attachments,
                provider: provider,
                model: selectedModel,
                preset: selectedPreset,
                onDelta: { c, r in
                    streamingContent += c
                    streamingReasoning += r
                },
                onComplete: { result in
                    isStreaming = false
                    streamingContent = ""
                    streamingReasoning = ""
                    if case .success(let finished) = result {
                        messages.append(finished)
                    }
                }
            )
        } catch {
            print("Regenerate failed: \(error)")
        }
    }

    // MARK: - Model Picker Sheet
    private var modelPickerSheet: some View {
        NavigationStack {
            List {
                ForEach(providers) { provider in
                    Section(header: Text(provider.name)) {
                        ForEach(provider.models, id: \.self) { model in
                            Button {
                                selectedProvider = provider
                                selectedModel = model
                                showingModelPicker = false
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            } label: {
                                HStack {
                                    Text(model)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if selectedProvider?.id == provider.id && selectedModel == model {
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
