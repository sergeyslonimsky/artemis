import Foundation
import UIKit
import os

/// Live state of a turn: routing, then streaming the reply.
struct ChatRunState: Equatable, Sendable {
    enum Phase: Sendable {
        /// Deciding between the on-device model and the cloud.
        case routing
        case generating
        case finished
    }

    let token: UUID
    var phase: Phase = .routing
    /// The assistant message being generated, once routing is done.
    var messageId: String?
    var content = ""
    var reasoning = ""
    /// Personal-data tool the on-device model is using right now ("Checking your calendar…").
    var activity: PersonalDataSource?

    var isActive: Bool { phase != .finished }
}

/// A cloud model the user picked for this chat.
struct CloudTarget: Equatable, Sendable {
    var provider: Provider
    var model: String
}

/// How the chat wants its turns routed.
struct RouteRequest: Equatable, Sendable {
    var mode: RoutingMode
    /// Used in Cloud mode and for escalation in Auto mode.
    var cloud: CloudTarget?
}

/// The chat's current choices that every turn is answered with.
struct TurnOptions: Equatable, Sendable {
    var route: RouteRequest
    var preset: Preset?
}

/// Owns turns: routing, cloud consent, generation and escalation. Turns outlive any particular
/// `ChatView`: views observe `runs` for live state and the database for everything else.
@MainActor
@Observable
final class ChatService {
    static let shared = ChatService()

    private static let logger = Logger(subsystem: "com.artemis.ios", category: "ChatService")

    private let database: AppDatabase
    private let autoTitling: AutoTitlingService
    private let router = Router()

    /// Latest run per chat. Kept after completion (`phase == .finished`) until the next run,
    /// so the bubble never flashes empty while the database observation catches up.
    private(set) var runs: [String: ChatRunState] = [:]

    /// The task and background-execution grant of each chat's active run.
    private struct Execution {
        var task: Task<Void, Never>
        var backgroundTask: UIBackgroundTaskIdentifier
    }

    @ObservationIgnored private var executions: [String: Execution] = [:]
    /// Chats in voice mode: their replies are written to be read aloud.
    @ObservationIgnored private var voiceChats: Set<String> = []

    init(database: AppDatabase = .shared) {
        self.database = database
        self.autoTitling = AutoTitlingService(database: database)
    }

    func isRunning(chatId: String) -> Bool {
        runs[chatId]?.isActive == true
    }

    func isRouting(chatId: String) -> Bool {
        runs[chatId]?.phase == .routing
    }

    /// Live text for `messageId` while it is being generated.
    func liveState(chatId: String, messageId: String) -> ChatRunState? {
        guard let run = runs[chatId], run.messageId == messageId else { return nil }
        return run
    }

    func setVoiceMode(_ isOn: Bool, chatId: String) {
        if isOn { voiceChats.insert(chatId) } else { voiceChats.remove(chatId) }
    }

    /// Stops the turn. A partial reply is kept and marked cancelled.
    func cancel(chatId: String) {
        executions[chatId]?.task.cancel()
    }

    // MARK: - Actions

    /// Appends the user's message and answers it.
    func send(chatId: String, content: String, attachments: [Attachment] = [], options: TurnOptions) throws {
        cancel(chatId: chatId)
        try database.deletePendingConsents(chatId: chatId)
        try database.addMessage(Message(chatId: chatId, role: .user, content: content, attachments: attachments))
        startTurn(chatId: chatId, options: options, forced: nil)
    }

    /// Drops `messageId` and everything after it, then answers the remaining history again.
    func regenerate(chatId: String, fromMessageId messageId: String, options: TurnOptions) throws {
        try restart(chatId: chatId, from: messageId, options: options, forced: nil)
    }

    /// Re-answers an on-device reply with the cloud model. An explicit request counts as consent.
    func askCloud(chatId: String, replacing messageId: String, options: TurnOptions) throws {
        try restart(chatId: chatId, from: messageId, options: options, forced: .cloud(.userAskedCloud))
    }

    /// Answers a consent prompt: send this turn to the cloud (and stop asking in this chat),
    /// or answer on-device anyway.
    func resolveConsent(chatId: String, consent: Message, allow: Bool, options: TurnOptions) throws {
        if allow {
            try database.setChatCloudAllowed(chatId: chatId, allowed: true)
        }
        let reason = consent.routeReason ?? .userAskedCloud
        try restart(chatId: chatId, from: consent.id, options: options, forced: allow ? .cloud(reason) : .onDevice(reason))
    }

    private func restart(chatId: String, from messageId: String, options: TurnOptions, forced: RouteDecision?) throws {
        cancel(chatId: chatId)
        try database.deleteMessagesFrom(chatId: chatId, messageId: messageId)
        startTurn(chatId: chatId, options: options, forced: forced)
    }

    // MARK: - Turn

    /// `forced` skips routing and the cloud policy (explicit user choices).
    private func startTurn(chatId: String, options: TurnOptions, forced: RouteDecision?) {
        let token = UUID()
        runs[chatId] = ChatRunState(token: token)
        if let previous = executions.removeValue(forKey: chatId) {
            endBackgroundTask(previous.backgroundTask)
        }

        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ArtemisReply") { [weak self] in
            // Expiration handlers run on the main thread and must end the grant before returning.
            MainActor.assumeIsolated {
                self?.endBackgroundTask(chatId: chatId)
            }
        }
        let task = Task { [weak self] in
            guard let self else { return }
            let turn = Turn(chatId: chatId, token: token, options: options)
            if let forced {
                await reply(turn, decision: forced, mayEscalate: false)
            } else {
                await routeAndReply(turn)
            }
            finishRun(turn)
        }
        executions[chatId] = Execution(task: task, backgroundTask: backgroundTask)
    }

    /// One run of a chat; `token` tells it apart from a newer run that replaced it.
    private struct Turn {
        let chatId: String
        let token: UUID
        let options: TurnOptions
        var route: RouteRequest { options.route }
    }

    private func routeAndReply(_ turn: Turn) async {
        let settings = currentSettings()
        guard let context = routeContext(turn, settings: settings) else { return }
        let decision = await router.route(context)
        guard isCurrent(turn), !Task.isCancelled else { return }
        Self.logger.info("Routed to \(decision.backend.rawValue, privacy: .public): \(decision.reason.rawValue, privacy: .public)")

        switch policyOutcome(for: decision, turn: turn, mode: turn.route.mode) {
        case .proceed(let decision):
            // Escalating is pointless when the cloud model is why the turn stayed local, or when the
            // turn is about personal data the cloud can't see.
            let mayEscalate = turn.route.mode == .auto && decision.reason != .cloudCantReadAttachment
                && !decision.reason.keepsDataOnDevice
            await reply(turn, decision: decision, mayEscalate: mayEscalate)
        case .keepOnDevice(let reason):
            await reply(turn, decision: .onDevice(reason), mayEscalate: false)
        case .needsConsent(let reason):
            addAssistantMessage(turn, status: .awaitingConsent, backend: .cloud, reason: reason)
        }
    }

    private func reply(_ turn: Turn, decision: RouteDecision, mayEscalate: Bool) async {
        guard let backend = backend(for: decision.backend, route: turn.route) else {
            addAssistantMessage(turn, status: .failed, backend: decision.backend, reason: decision.reason,
                                error: "Choose a cloud model to answer this message.")
            return
        }
        guard let placeholder = addAssistantMessage(
            turn, status: .streaming, backend: decision.backend, reason: decision.reason, descriptor: backend.descriptor
        ) else { return }

        runs[turn.chatId]?.phase = .generating
        runs[turn.chatId]?.messageId = placeholder.id
        runs[turn.chatId]?.content = ""
        runs[turn.chatId]?.reasoning = ""

        let job = ReplyJob(
            database: database, chatId: turn.chatId, messageId: placeholder.id, backend: backend,
            preset: turn.options.preset,
            toolGroups: decision.reason.toolGroups,
            offersTranslation: decision.reason == .translation,
            isVoice: voiceChats.contains(turn.chatId)
        )
        let token = turn.token
        let chatId = turn.chatId
        let outcome = await job.run(
            onBatch: { [weak self] batch in
                await self?.apply(batch, chatId: chatId, token: token)
            },
            onActivity: { [weak self] source in
                await self?.setActivity(source, chatId: chatId, token: token)
            }
        )
        guard isCurrent(turn) else { return }

        if mayEscalate, decision.backend == .onDevice, turn.route.cloud != nil, !outcome.extras.usedPrivateData,
           !Task.isCancelled, let reason = await escalationReason(for: outcome), isCurrent(turn), !Task.isCancelled {
            await escalate(turn, failedMessageId: placeholder.id, reason: reason)
            return
        }

        if outcome.status == .done {
            generateTitle(chatId: turn.chatId, outcome: outcome, replyBackend: backend)
        }
    }

    /// Why an on-device reply should be retried in the cloud, if it should.
    private func escalationReason(for outcome: ReplyJob.Outcome) async -> RouteReason? {
        if outcome.onDeviceError != nil { return .onDeviceFailed }
        // A reply built on tool results (weather, places…) is grounded, not a refusal.
        if outcome.status == .done, outcome.extras.isEmpty, await RefusalDetector.isRefusal(outcome.content) {
            return .onDeviceDeclined
        }
        return nil
    }

    /// The on-device model failed or declined in Auto mode: retry in the cloud if the policy allows it.
    private func escalate(_ turn: Turn, failedMessageId: String, reason: RouteReason) async {
        switch policyOutcome(for: .cloud(reason), turn: turn, mode: .auto) {
        case .proceed(let decision):
            try? database.deleteMessagesFrom(chatId: turn.chatId, messageId: failedMessageId)
            await reply(turn, decision: decision, mayEscalate: false)
        case .needsConsent(let reason) where reason == .onDeviceDeclined:
            // The reply may still be useful (the refusal check can be wrong): keep it, and offer
            // "Ask cloud" under it instead of replacing it with a consent prompt.
            try? database.setRouteReason(messageId: failedMessageId, reason: reason)
        case .needsConsent(let reason):
            try? database.deleteMessagesFrom(chatId: turn.chatId, messageId: failedMessageId)
            addAssistantMessage(turn, status: .awaitingConsent, backend: .cloud, reason: reason)
        case .keepOnDevice:
            // The reply or failure stays visible; its reason shows that a cloud model might do
            // better, and "Ask cloud" remains available as an explicit choice.
            try? database.setRouteReason(messageId: failedMessageId, reason: reason)
        }
    }

    private func policyOutcome(for decision: RouteDecision, turn: Turn, mode: RoutingMode) -> PolicyOutcome {
        let chatAllowsCloud = (try? database.fetchChat(id: turn.chatId))?.cloudAllowed ?? false
        return currentSettings().cloudPolicy.apply(to: decision, mode: mode, chatAllowsCloud: chatAllowsCloud)
    }

    /// Adds an assistant message: a streaming placeholder, a consent prompt or a failure.
    /// A consent prompt names the chat's cloud model; a reply names whoever generates it.
    @discardableResult
    private func addAssistantMessage(
        _ turn: Turn,
        status: MessageStatus,
        backend: BackendKind,
        reason: RouteReason,
        descriptor: BackendDescriptor? = nil,
        error: String? = nil
    ) -> Message? {
        let consentTarget = status == .awaitingConsent ? turn.route.cloud : nil
        do {
            return try database.addMessage(Message(
                chatId: turn.chatId,
                role: .assistant,
                content: "",
                status: status,
                error: error,
                backend: descriptor?.kind ?? backend,
                providerId: descriptor?.providerId ?? consentTarget?.provider.id,
                model: descriptor?.model ?? consentTarget?.model,
                routeReason: reason
            ))
        } catch {
            Self.logger.error("Failed to add \(status.rawValue, privacy: .public) message: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func routeContext(_ turn: Turn, settings: AppSettings) -> RouteContext? {
        guard let messages = try? database.fetchMessages(chatId: turn.chatId),
              let index = messages.lastIndex(where: { $0.role == .user }) else {
            return nil
        }
        let cloud = turn.route.cloud
        return RouteContext(
            message: messages[index],
            recentHistory: Array(messages[..<index].filter(ReplyJob.belongsInContext).suffix(2)),
            mode: turn.route.mode,
            onDeviceUsable: settings.isOnDeviceUsable,
            hasCloud: cloud != nil,
            cloudCapabilities: cloud.map { $0.provider.capabilities(for: $0.model) },
            availableTools: settings.enabledToolGroups
        )
    }

    private func backend(for kind: BackendKind, route: RouteRequest) -> (any ChatBackend)? {
        switch kind {
        case .onDevice:
            return AppleOnDeviceBackend()
        case .cloud:
            guard let cloud = route.cloud else { return nil }
            return OpenAICompatibleBackend(
                provider: cloud.provider,
                apiKey: database.apiKey(providerId: cloud.provider.id),
                model: cloud.model
            )
        }
    }

    private func currentSettings() -> AppSettings {
        do {
            return try database.fetchSettings()
        } catch {
            Self.logger.error("Failed to read settings: \(error.localizedDescription, privacy: .public)")
            return AppSettings()
        }
    }

    // MARK: - Run state

    private func isCurrent(_ turn: Turn) -> Bool {
        runs[turn.chatId]?.token == turn.token
    }

    private func setActivity(_ source: PersonalDataSource?, chatId: String, token: UUID) {
        guard runs[chatId]?.token == token else { return }
        runs[chatId]?.activity = source
    }

    private func apply(_ batch: StreamBatcher.Batch, chatId: String, token: UUID) {
        guard runs[chatId]?.token == token else { return }
        if !batch.content.isEmpty { runs[chatId]?.activity = nil }
        runs[chatId]?.content += batch.content
        runs[chatId]?.reasoning += batch.reasoning
    }

    private func finishRun(_ turn: Turn) {
        // A newer run may have replaced this one (send right after cancel); leave it alone.
        guard isCurrent(turn) else { return }
        runs[turn.chatId]?.phase = .finished
        if let execution = executions.removeValue(forKey: turn.chatId) {
            endBackgroundTask(execution.backgroundTask)
        }
    }

    private func endBackgroundTask(chatId: String) {
        guard let id = executions[chatId]?.backgroundTask else { return }
        executions[chatId]?.backgroundTask = .invalid
        endBackgroundTask(id)
    }

    private func endBackgroundTask(_ id: UIBackgroundTaskIdentifier) {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
    }

    // MARK: - Titles

    private func generateTitle(chatId: String, outcome: ReplyJob.Outcome, replyBackend: any ChatBackend) {
        guard let titler = titlingBackend(for: replyBackend) else { return }
        let autoTitling = autoTitling
        Task {
            await autoTitling.generateTitleIfNeeded(
                chatId: chatId,
                userPrompt: outcome.lastUserPrompt,
                assistantReply: outcome.content,
                backend: titler
            )
        }
    }

    /// Titles stay on-device when possible; a cloud reply may be titled by the same provider,
    /// since that conversation was already sent there.
    private func titlingBackend(for replyBackend: any ChatBackend) -> (any ChatBackend)? {
        let settings = currentSettings()
        if settings.isOnDeviceUsable && (settings.onDeviceTitles || replyBackend.descriptor.kind == .onDevice) {
            return AppleOnDeviceBackend()
        }
        return replyBackend.descriptor.kind == .cloud ? replyBackend : nil
    }
}
