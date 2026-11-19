import Foundation
import GRDB
import os

/// The user's answer to a cloud-consent prompt.
enum ConsentChoice {
    /// Send this turn and stop asking in this chat.
    case allow
    case answerOnDevice
}

/// State and actions of one chat screen: the stored chat (or a draft not yet saved), the model
/// selection, the composer's content, and the turns it starts through `ChatService`.
@MainActor
@Observable
final class ChatSessionModel {
    /// May not exist in the database yet: a draft is stored when its first message is sent.
    let chatId: String

    private(set) var chat: Chat?
    private(set) var messages: [Message] = []
    private(set) var providers: [Provider] = []
    private(set) var presets: [Preset] = []
    private(set) var settings = AppSettings()
    private(set) var recentModels: [ModelRef] = []
    private(set) var onDeviceStatus = OnDeviceModelStatus.current

    private(set) var selectedProviderId: String?
    private(set) var selectedModel = ""
    private(set) var selectedPreset: Preset?

    var inputText = ""
    var attachments: [Attachment] = [] {
        didSet { attachmentsChanged(from: oldValue) }
    }
    var isShowingModelPicker = false
    var voiceSession: VoiceSession?
    /// A system composer or editor finishing a drafted action.
    var draftSheet: DraftSheet?
    var errorMessage: String?

    /// Mode picked before a draft chat exists.
    private var draftMode: RoutingMode?
    /// The user picked a model in this chat; until then a draft follows the defaults.
    private var userPickedModel = false
    private var chatLoaded = false
    private var providersLoaded = false
    private var settingsLoaded = false
    private var presetsLoaded = false
    private var defaultPresetApplied = false
    /// Images whose text the composer is waiting for, so a change to the list doesn't wait twice.
    @ObservationIgnored private var awaitedTextIds: Set<String> = []
    /// Set while sent attachments leave the composer: their text is still being read for the reply.
    @ObservationIgnored private var isHandingOffAttachments = false
    /// What the chat was opened with; applied once everything the turn depends on has loaded.
    private var pendingLaunch: ChatLaunch?
    /// The chat was opened to type in (a control, the New Chat shortcut).
    let launchFocusesComposer: Bool

    /// Tells the screen the launch ran, so a recreated session doesn't run it again.
    @ObservationIgnored private let onLaunchApplied: () -> Void
    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let chatService: ChatService
    private static let logger = Logger(subsystem: "com.artemis.ios", category: "ChatSession")

    init(
        chatId: String,
        launch: ChatLaunch? = nil,
        onLaunchApplied: @escaping () -> Void = {},
        database: AppDatabase = .shared,
        chatService: ChatService = .shared
    ) {
        self.chatId = chatId
        self.pendingLaunch = launch
        self.launchFocusesComposer = launch?.focusComposer ?? false
        self.onLaunchApplied = onLaunchApplied
        self.database = database
        self.chatService = chatService
    }

    // MARK: - Observation

    // Each runs until the calling task is cancelled (the view's `.task`).

    func observeChat() async {
        await observe(database.observeChat(id: chatId), "chat") { chat in
            self.chat = chat
            chatLoaded = true
            resolveSelection()
            applyLaunchIfReady()
        }
    }

    func observeMessages() async {
        await observe(database.observeMessages(chatId: chatId), "messages") { messages = $0 }
    }

    func observeProviders() async {
        await observe(database.observeProviders(), "providers") { providers in
            self.providers = providers
            providersLoaded = true
            resolveSelection()
            applyLaunchIfReady()
        }
    }

    func observeSettings() async {
        await observe(database.observeSettings(), "settings") { settings in
            self.settings = settings
            settingsLoaded = true
            resolveSelection()
            resolvePreset()
            applyLaunchIfReady()
        }
    }

    func observePresets() async {
        await observe(database.observePresets(), "presets") { presets in
            self.presets = presets
            presetsLoaded = true
            resolvePreset()
            applyLaunchIfReady()
        }
    }

    private func observe<Value>(_ values: AsyncValueObservation<Value>, _ name: String, _ apply: (Value) -> Void) async {
        await values.keepDelivering(onError: { error in
            Self.logger.error("Observing \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Couldn't load \(name): \(error.localizedDescription)"
        }, apply)
    }

    /// Fresh data for the model picker: the on-device status can change while the app runs.
    func refreshPickerData() {
        onDeviceStatus = .current
        recentModels = (try? database.recentModels()) ?? []
    }

    // MARK: - Launch

    /// Fills the composer with what the chat was opened with, then sends it or starts voice mode.
    /// Waits for the model selection and the preset, which decide where the turn goes.
    private func applyLaunchIfReady() {
        guard let launch = pendingLaunch, chatLoaded, providersLoaded, settingsLoaded, presetsLoaded else { return }
        pendingLaunch = nil
        onLaunchApplied()
        inputText = launch.prompt
        attachments = launch.attachments
        if launch.voice {
            startVoice()
        } else if launch.autoSend {
            send()
        }
    }

    // MARK: - Attachments

    /// Removed images stop being read. New ones were already being read since they were attached
    /// (picked, scanned or shared): the composer takes the text so it's stored with the message,
    /// and an on-device reply doesn't wait for it.
    private func attachmentsChanged(from old: [Attachment]) {
        if !isHandingOffAttachments {
            let kept = Set(attachments.map(\.id))
            for attachment in old where !kept.contains(attachment.id) {
                ImageTextReader.shared.cancel(id: attachment.id)
            }
        }
        for attachment in attachments where attachment.kind == .image && attachment.recognizedText == nil {
            guard let data = attachment.data, !awaitedTextIds.contains(attachment.id) else { continue }
            awaitedTextIds.insert(attachment.id)
            Task {
                defer { awaitedTextIds.remove(attachment.id) }
                let text: String
                do {
                    text = try await ImageTextReader.shared.text(id: attachment.id, data: data) ?? ""
                } catch {
                    return
                }
                if let index = attachments.firstIndex(where: { $0.id == attachment.id }) {
                    attachments[index].recognizedText = text
                } else {
                    // Sent before the reading finished (a cloud reply doesn't wait for it).
                    try? database.setRecognizedText(text, attachmentId: attachment.id)
                }
            }
        }
    }

    // MARK: - Selection

    var selectedProvider: Provider? {
        providers.first { $0.id == selectedProviderId }
    }

    var selection: ModelRef? {
        selectedProviderId.map { ModelRef(providerId: $0, model: selectedModel) }
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

        guard let provider = providers.first(where: { $0.id == settings.defaultProviderId }) ?? providers.first else {
            selectedProviderId = nil
            selectedModel = ""
            return
        }
        selectedProviderId = provider.id
        selectedModel = provider.defaultModel.isEmpty ? (provider.models.first ?? "") : provider.defaultModel
    }

    /// Starts with the default preset; afterwards follows edits to the selected one and drops it once deleted.
    private func resolvePreset() {
        guard settingsLoaded, presetsLoaded else { return }
        if !defaultPresetApplied {
            defaultPresetApplied = true
            selectedPreset = presets.first { $0.id == settings.defaultPresetId }
        } else if let selected = selectedPreset {
            selectedPreset = presets.first { $0.id == selected.id }
        }
    }

    func selectPreset(_ preset: Preset?) {
        selectedPreset = preset
    }

    func selectModel(_ model: String, of provider: Provider) {
        userPickedModel = true
        selectedProviderId = provider.id
        selectedModel = model
        // Picking a cloud model in On-device mode means the user wants it.
        if effectiveMode == .onDevice {
            setRoutingMode(.cloud)
        }
        isShowingModelPicker = false
        guard chat != nil else { return } // a draft saves its selection when it's created
        save("chat model") { try database.setChatModel(chatId: chatId, providerId: provider.id, model: model) }
    }

    func setRoutingMode(_ mode: RoutingMode) {
        guard chat != nil else {
            draftMode = mode
            return
        }
        chat?.routingMode = mode
        save("routing mode") { try database.setChatRoutingMode(chatId: chatId, mode: mode) }
    }

    func toggleFavorite(_ ref: ModelRef) {
        var updated = settings
        if let index = updated.favoriteModels.firstIndex(of: ref) {
            updated.favoriteModels.remove(at: index)
        } else {
            updated.favoriteModels.append(ref)
        }
        perform { try database.saveSettings(updated) }
    }

    // MARK: - Routing

    var effectiveMode: RoutingMode {
        chat?.routingMode ?? draftMode ?? settings.routingMode
    }

    var cloudTarget: CloudTarget? {
        guard let provider = selectedProvider, !selectedModel.isEmpty else { return nil }
        return CloudTarget(provider: provider, model: selectedModel)
    }

    private var turnOptions: TurnOptions {
        TurnOptions(route: RouteRequest(mode: effectiveMode, cloud: cloudTarget), preset: selectedPreset)
    }

    var isOnDeviceUsable: Bool {
        settings.onDeviceEnabled && onDeviceStatus.isAvailable
    }

    /// Whether the next message has anyone to answer it.
    var canSend: Bool {
        switch effectiveMode {
        case .onDevice: isOnDeviceUsable
        case .cloud: cloudTarget != nil
        case .auto: isOnDeviceUsable || cloudTarget != nil
        }
    }

    /// Apple: prewarm when a request is likely at least a second away, e.g. typing starts.
    func prewarmIfUseful() {
        if effectiveMode != .cloud && isOnDeviceUsable {
            OnDeviceModel.prewarm()
        }
    }

    // MARK: - Run state

    var isBusy: Bool { chatService.isRunning(chatId: chatId) }
    var isRouting: Bool { chatService.isRouting(chatId: chatId) }

    func liveState(for message: Message) -> ChatRunState? {
        chatService.liveState(chatId: chatId, messageId: message.id)
    }

    func providerName(for message: Message) -> String? {
        providers.first { $0.id == message.providerId }?.name
    }

    func canRegenerate(_ message: Message) -> Bool {
        message.role == .assistant && !isBusy
    }

    /// Replies built on calendar/reminders aren't offered to the cloud: it would only see a redaction.
    func canAskCloud(_ message: Message) -> Bool {
        canRegenerate(message) && message.backend == .onDevice && cloudTarget != nil && !message.extras.usedPrivateData
    }

    // MARK: - Actions

    func send() {
        guard canSend else {
            isShowingModelPicker = true
            return
        }
        let prompt = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        perform {
            try ensureChat()
            try chatService.send(chatId: chatId, content: prompt, attachments: attachments, options: turnOptions)
            inputText = ""
            isHandingOffAttachments = true
            attachments = []
            isHandingOffAttachments = false
        }
    }

    func stop() {
        chatService.cancel(chatId: chatId)
    }

    func startVoice() {
        guard canSend else {
            isShowingModelPicker = true
            return
        }
        prewarmIfUseful()
        voiceSession = VoiceSession(
            chatId: chatId,
            send: { [weak self] text in
                guard let self else { return }
                try ensureChat()
                try chatService.send(chatId: chatId, content: text, options: turnOptions)
            },
            answerConsent: { [weak self] consent, allow in
                self?.resolveConsent(consent, choice: allow ? .allow : .answerOnDevice)
            }
        )
    }

    func regenerate(_ message: Message) {
        perform { try chatService.regenerate(chatId: chatId, fromMessageId: message.id, options: turnOptions) }
    }

    func askCloud(_ message: Message) {
        perform { try chatService.askCloud(chatId: chatId, replacing: message.id, options: turnOptions) }
    }

    func resolveConsent(_ consent: Message, choice: ConsentChoice) {
        perform {
            try chatService.resolveConsent(chatId: chatId, consent: consent, allow: choice == .allow, options: turnOptions)
        }
    }

    /// Carries out a drafted action only after the user confirms it. Returns whether it was carried
    /// out right away (a message or email opens the composer first).
    @discardableResult
    func resolveDraft(_ draft: ActionDraft, in message: Message, confirm: Bool) async -> Bool {
        do {
            switch try await DraftPerformer.resolve(draft, messageId: message.id, confirm: confirm, database: database) {
            case .done:
                return confirm
            case .needsSheet(let sheet):
                draftSheet = sheet
                return false
            }
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Opens a drafted event in the calendar's editor, to change it before saving.
    func editDraft(_ draft: ActionDraft, in message: Message) {
        draftSheet = DraftSheet(kind: .editEvent, draft: draft, messageId: message.id)
    }

    /// Records what happened in the composer or editor. Returns whether the action was completed.
    @discardableResult
    func finishDraftSheet(_ sheet: DraftSheet, completed: Bool) -> Bool {
        draftSheet = nil
        do {
            try DraftPerformer.finish(sheet, completed: completed, database: database)
            return completed
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Stores a draft chat with the selection made so far.
    private func ensureChat() throws {
        guard chat == nil else { return }
        chat = try database.createChat(
            id: chatId,
            title: "New Chat",
            routingMode: draftMode,
            providerId: selectedProviderId,
            model: selectedModel.isEmpty ? nil : selectedModel
        )
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Background saves of a choice: a failure is logged; the choice still applies to this session.
    private func save(_ what: String, _ action: () throws -> Void) {
        do {
            try action()
        } catch {
            Self.logger.error("Failed to save \(what, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Text

    /// Compact title for the navigation bar.
    var routeTitle: String {
        switch effectiveMode {
        case .cloud: selectedModel.isEmpty ? RoutingMode.cloud.title : ModelName(selectedModel).title
        default: effectiveMode.title
        }
    }

    var routeAccessibilityLabel: String {
        switch effectiveMode {
        case .onDevice: RoutingMode.onDevice.title
        case .cloud: selectedModel
        case .auto: "Auto · " + (cloudTarget?.model ?? RoutingMode.onDevice.title)
        }
    }

    var emptyStateHint: String {
        switch effectiveMode {
        case .onDevice: "Answered privately on this iPhone"
        case .cloud: "Answered by \(selectedModel.isEmpty ? "your cloud model" : selectedModel)"
        case .auto: "On-device first, cloud only when needed"
        }
    }

    var modeDescription: String {
        let onDeviceNote = isOnDeviceUsable ? ""
            : " " + (settings.onDeviceEnabled ? onDeviceStatus.detail : "The on-device model is turned off in Settings.")
        switch effectiveMode {
        case .auto: return "Answers on-device and uses the cloud model below only when needed." + onDeviceNote
        case .onDevice: return "Everything stays on this device." + onDeviceNote
        case .cloud: return "Every message goes to the cloud model below."
        }
    }
}
