import Foundation
import UIKit
import os

/// Live state of a turn: routing, then streaming the reply.
public struct ChatRunState: Equatable, Sendable {
    public enum Phase: Sendable {
        /// Deciding between the on-device model and the cloud.
        case routing
        case generating
        case finished
    }

    public let token: UUID
    public var phase: Phase = .routing
    /// The assistant message being generated, once routing is done.
    public var messageId: String?
    public var content: String = ""
    public var reasoning: String = ""

    public var isActive: Bool { phase != .finished }
}

/// A cloud model the user picked for this chat.
public struct CloudTarget: Equatable, Sendable {
    public var provider: Provider
    public var model: String

    public init(provider: Provider, model: String) {
        self.provider = provider
        self.model = model
    }
}

/// How the chat wants its turns routed.
public struct RouteRequest: Equatable, Sendable {
    public var mode: RoutingMode
    /// Used in Cloud mode and for escalation in Auto mode.
    public var cloud: CloudTarget?

    public init(mode: RoutingMode, cloud: CloudTarget?) {
        self.mode = mode
        self.cloud = cloud
    }
}

/// Owns turns: routing, cloud consent, generation and escalation. Turns outlive any particular
/// `ChatView`: views observe `runs` for live state and the database for everything else.
@MainActor
@Observable
public final class ChatService {
    public static let shared = ChatService()

    private static let logger = Logger(subsystem: "com.artemis.ios", category: "ChatService")

    private let database: AppDatabase
    private let autoTitling: AutoTitlingService
    private let router = Router()

    /// Latest run per chat. Kept after completion (`phase == .finished`) until the next run,
    /// so the bubble never flashes empty while the database observation catches up.
    public private(set) var runs: [String: ChatRunState] = [:]

    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var backgroundTasks: [String: UIBackgroundTaskIdentifier] = [:]

    public init(database: AppDatabase = .shared) {
        self.database = database
        self.autoTitling = AutoTitlingService(database: database)
    }

    public func isRunning(chatId: String) -> Bool {
        runs[chatId]?.isActive == true
    }

    public func isRouting(chatId: String) -> Bool {
        runs[chatId]?.phase == .routing
    }

    /// Live text for `messageId` while it is being generated.
    public func liveState(chatId: String, messageId: String) -> ChatRunState? {
        guard let run = runs[chatId], run.messageId == messageId else { return nil }
        return run
    }

    /// Stops the turn. A partial reply is kept and marked cancelled.
    public func cancel(chatId: String) {
        tasks[chatId]?.cancel()
    }

    // MARK: - Public actions

    /// Appends the user's message and answers it.
    public func send(
        chatId: String,
        content: String,
        attachments: [Attachment] = [],
        route: RouteRequest,
        preset: Preset? = nil
    ) throws {
        cancel(chatId: chatId)
        try database.deletePendingConsents(chatId: chatId)
        try database.addMessage(Message(chatId: chatId, role: .user, content: content, attachments: attachments))
        startTurn(chatId: chatId, route: route, preset: preset, forced: nil)
    }

    /// Drops `messageId` and everything after it, then answers the remaining history again.
    public func regenerate(chatId: String, fromMessageId messageId: String, route: RouteRequest, preset: Preset? = nil) throws {
        cancel(chatId: chatId)
        try database.deleteMessagesFrom(chatId: chatId, messageId: messageId)
        startTurn(chatId: chatId, route: route, preset: preset, forced: nil)
    }

    /// Re-answers an on-device reply with the cloud model. An explicit request counts as consent.
    public func askCloud(chatId: String, replacing messageId: String, route: RouteRequest, preset: Preset? = nil) throws {
        cancel(chatId: chatId)
        try database.deleteMessagesFrom(chatId: chatId, messageId: messageId)
        startTurn(chatId: chatId, route: route, preset: preset, forced: .cloud(.userAskedCloud))
    }

    /// Answers a consent prompt: send this turn to the cloud, or answer on-device anyway.
    public func resolveConsent(
        chatId: String,
        consent: Message,
        allow: Bool,
        rememberForChat: Bool,
        route: RouteRequest,
        preset: Preset? = nil
    ) throws {
        cancel(chatId: chatId)
        try database.deleteMessagesFrom(chatId: chatId, messageId: consent.id)
        if allow && rememberForChat {
            try database.setChatCloudAllowed(chatId: chatId, allowed: true)
        }
        let reason = consent.routeReason ?? .userAskedCloud
        startTurn(chatId: chatId, route: route, preset: preset, forced: allow ? .cloud(reason) : .onDevice(reason))
    }

    // MARK: - Turn

    /// `forced` skips routing and the cloud policy (explicit user choices).
    private func startTurn(chatId: String, route: RouteRequest, preset: Preset?, forced: RouteDecision?) {
        let token = UUID()
        runs[chatId] = ChatRunState(token: token)
        beginBackgroundTask(chatId: chatId)

        tasks[chatId] = Task { [weak self] in
            guard let self else { return }
            await self.performTurn(chatId: chatId, token: token, route: route, preset: preset, forced: forced)
            self.finishRun(chatId: chatId, token: token)
        }
    }

    private func performTurn(chatId: String, token: UUID, route: RouteRequest, preset: Preset?, forced: RouteDecision?) async {
        if let forced {
            await reply(chatId: chatId, token: token, decision: forced, route: route, preset: preset, mayEscalate: false)
            return
        }

        guard let context = routeContext(chatId: chatId, route: route) else { return }
        let decision = await router.route(context)
        guard isCurrent(chatId: chatId, token: token), !Task.isCancelled else { return }
        Self.logger.info("Routed to \(decision.backend.rawValue, privacy: .public): \(decision.reason.rawValue, privacy: .public)")

        let settings = (try? database.fetchSettings()) ?? AppSettings()
        let chatAllowsCloud = (try? database.fetchChat(id: chatId))?.cloudAllowed ?? false
        switch settings.cloudPolicy.apply(to: decision, mode: route.mode, chatAllowsCloud: chatAllowsCloud) {
        case .proceed(let decision):
            await reply(chatId: chatId, token: token, decision: decision, route: route, preset: preset, mayEscalate: route.mode == .auto)
        case .keepOnDevice(let reason):
            await reply(chatId: chatId, token: token, decision: .onDevice(reason), route: route, preset: preset, mayEscalate: false)
        case .needsConsent(let reason):
            askForConsent(chatId: chatId, reason: reason, route: route)
        }
    }

    private func reply(
        chatId: String,
        token: UUID,
        decision: RouteDecision,
        route: RouteRequest,
        preset: Preset?,
        mayEscalate: Bool
    ) async {
        guard let backend = backend(for: decision.backend, route: route) else {
            recordFailure(chatId: chatId, decision: decision, error: "Choose a cloud model to answer this message.")
            return
        }

        let descriptor = backend.descriptor
        let placeholder: Message
        do {
            placeholder = try database.addMessage(Message(
                chatId: chatId,
                role: .assistant,
                content: "",
                status: .streaming,
                backend: descriptor.kind,
                providerId: descriptor.providerId,
                model: descriptor.model,
                routeReason: decision.reason
            ))
        } catch {
            Self.logger.error("Failed to add reply placeholder: \(error.localizedDescription, privacy: .public)")
            return
        }

        runs[chatId]?.phase = .generating
        runs[chatId]?.messageId = placeholder.id
        runs[chatId]?.content = ""
        runs[chatId]?.reasoning = ""

        let job = ReplyJob(database: database, chatId: chatId, messageId: placeholder.id, backend: backend, preset: preset)
        let outcome = await job.run { [weak self] batch in
            await self?.apply(batch, chatId: chatId, token: token)
        }
        guard isCurrent(chatId: chatId, token: token) else { return }

        if outcome.onDeviceError != nil, mayEscalate, decision.backend == .onDevice, !Task.isCancelled {
            await escalate(chatId: chatId, token: token, failedMessageId: placeholder.id, route: route, preset: preset)
            return
        }

        if outcome.status == .done {
            generateTitle(chatId: chatId, outcome: outcome, replyBackend: backend)
        }
    }

    /// The on-device model failed in Auto mode: retry in the cloud if the policy allows it.
    private func escalate(chatId: String, token: UUID, failedMessageId: String, route: RouteRequest, preset: Preset?) async {
        guard route.cloud != nil else { return }
        let settings = (try? database.fetchSettings()) ?? AppSettings()
        let chatAllowsCloud = (try? database.fetchChat(id: chatId))?.cloudAllowed ?? false

        switch settings.cloudPolicy.apply(to: .cloud(.onDeviceFailed), mode: .auto, chatAllowsCloud: chatAllowsCloud) {
        case .proceed(let decision):
            try? database.deleteMessagesFrom(chatId: chatId, messageId: failedMessageId)
            await reply(chatId: chatId, token: token, decision: decision, route: route, preset: preset, mayEscalate: false)
        case .needsConsent(let reason):
            try? database.deleteMessagesFrom(chatId: chatId, messageId: failedMessageId)
            askForConsent(chatId: chatId, reason: reason, route: route)
        case .keepOnDevice:
            break // The failure stays visible; "Ask cloud" remains available as an explicit choice.
        }
    }

    private func askForConsent(chatId: String, reason: RouteReason, route: RouteRequest) {
        do {
            try database.addMessage(Message(
                chatId: chatId,
                role: .assistant,
                content: "",
                status: .awaitingConsent,
                backend: .cloud,
                providerId: route.cloud?.provider.id,
                model: route.cloud?.model,
                routeReason: reason
            ))
        } catch {
            Self.logger.error("Failed to add consent prompt: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func recordFailure(chatId: String, decision: RouteDecision, error: String) {
        _ = try? database.addMessage(Message(
            chatId: chatId,
            role: .assistant,
            content: "",
            status: .failed,
            error: error,
            backend: decision.backend,
            routeReason: decision.reason
        ))
    }

    private func routeContext(chatId: String, route: RouteRequest) -> RouteContext? {
        guard let messages = try? database.fetchMessages(chatId: chatId),
              let index = messages.lastIndex(where: { $0.role == .user }) else {
            return nil
        }
        let settings = (try? database.fetchSettings()) ?? AppSettings()
        return RouteContext(
            message: messages[index],
            recentHistory: Array(messages[..<index].filter(ReplyJob.belongsInContext).suffix(2)),
            mode: route.mode,
            onDeviceUsable: settings.onDeviceEnabled && OnDeviceModelStatus.current.isAvailable,
            hasCloud: route.cloud != nil
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

    // MARK: - Run state

    private func isCurrent(chatId: String, token: UUID) -> Bool {
        runs[chatId]?.token == token
    }

    private func apply(_ batch: StreamBatcher.Batch, chatId: String, token: UUID) {
        guard isCurrent(chatId: chatId, token: token) else { return }
        runs[chatId]?.content += batch.content
        runs[chatId]?.reasoning += batch.reasoning
    }

    private func finishRun(chatId: String, token: UUID) {
        // A newer run may have replaced this one (send right after cancel); leave it alone.
        guard isCurrent(chatId: chatId, token: token) else { return }
        runs[chatId]?.phase = .finished
        tasks.removeValue(forKey: chatId)
        endBackgroundTask(chatId: chatId)
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
        let settings = (try? database.fetchSettings()) ?? AppSettings()
        let onDeviceUsable = settings.onDeviceEnabled && OnDeviceModelStatus.current.isAvailable
        if onDeviceUsable && (settings.onDeviceTitles || replyBackend.descriptor.kind == .onDevice) {
            return AppleOnDeviceBackend()
        }
        return replyBackend.descriptor.kind == .cloud ? replyBackend : nil
    }

    // MARK: - Background execution

    private func beginBackgroundTask(chatId: String) {
        endBackgroundTask(chatId: chatId)
        backgroundTasks[chatId] = UIApplication.shared.beginBackgroundTask(withName: "ArtemisStream-\(chatId)") { [weak self] in
            // Expiration handlers run on the main thread.
            MainActor.assumeIsolated {
                self?.endBackgroundTask(chatId: chatId)
            }
        }
    }

    private func endBackgroundTask(chatId: String) {
        guard let id = backgroundTasks.removeValue(forKey: chatId), id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
    }
}

// MARK: - Reply job

/// One assistant reply: reads history, streams from the provider and persists the result.
/// Runs off the main actor; UI updates go through `onBatch`.
struct ReplyJob: Sendable {
    struct Outcome: Sendable {
        var content = ""
        var reasoning = ""
        var status: MessageStatus = .done
        var error: String?
        var stats: MessageStats?
        var lastUserPrompt = ""
        /// Set when the on-device model failed; such failures may escalate to the cloud.
        var onDeviceError: OnDeviceError?
    }

    let database: AppDatabase
    let chatId: String
    let messageId: String
    let backend: any ChatBackend
    let preset: Preset?

    private static let logger = Logger(subsystem: "com.artemis.ios", category: "ReplyJob")

    @concurrent
    func run(onBatch: @escaping @Sendable (StreamBatcher.Batch) async -> Void) async -> Outcome {
        var outcome = Outcome()
        var batcher = StreamBatcher()

        do {
            let history = try database.fetchMessages(chatId: chatId, includeAttachmentData: true)
                .filter { $0.id != messageId && Self.belongsInContext($0) }
            outcome.lastUserPrompt = history.last(where: { $0.role == .user })?.content ?? ""

            let settings = try database.fetchSettings()
            let turn = ChatTurn(messages: history, systemPrompt: settings.systemPrompt, preset: preset)

            for try await event in backend.stream(turn) {
                try Task.checkCancellation()
                switch event {
                case .content(let delta):
                    outcome.content += delta
                    if let batch = batcher.append(content: delta) { await onBatch(batch) }
                case .reasoning(let delta):
                    outcome.reasoning += delta
                    if let batch = batcher.append(reasoning: delta) { await onBatch(batch) }
                case .done(let tokens, let isEstimated, let durationMs):
                    outcome.stats = MessageStats(tokens: tokens, isEstimated: isEstimated, durationMs: durationMs)
                case .error(let message):
                    throw ReplyError.provider(message)
                }
            }
            // Backends may end the stream quietly when cancelled.
            try Task.checkCancellation()

            if outcome.content.isEmpty && outcome.reasoning.isEmpty {
                throw ReplyError.emptyResponse
            }
        } catch {
            if Task.isCancelled || error is CancellationError {
                outcome.status = .cancelled
            } else {
                outcome.status = .failed
                outcome.error = error.localizedDescription
                outcome.onDeviceError = error as? OnDeviceError
            }
        }

        if let batch = batcher.drain() { await onBatch(batch) }

        do {
            try database.finishMessage(
                id: messageId,
                content: outcome.content,
                reasoning: outcome.reasoning,
                status: outcome.status,
                error: outcome.error,
                stats: outcome.stats
            )
        } catch {
            Self.logger.error("Failed to persist reply \(messageId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        return outcome
    }

    /// Failed or empty assistant turns carry no useful context for the model.
    static func belongsInContext(_ message: Message) -> Bool {
        guard message.role == .assistant else { return true }
        switch message.status {
        case .done, .cancelled:
            return !message.content.isEmpty
        case .failed, .streaming, .awaitingConsent:
            return false
        }
    }
}

enum ReplyError: LocalizedError {
    case provider(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .provider(let message):
            return message
        case .emptyResponse:
            return "The model returned an empty response."
        }
    }
}
