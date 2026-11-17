import Foundation
import UIKit
import os

/// Live state of an assistant reply that is being generated.
public struct ChatRunState: Equatable, Sendable {
    public let token: UUID
    public let messageId: String
    public var content: String = ""
    public var reasoning: String = ""
    public var isActive: Bool = true
}

/// Owns reply generation. Generation outlives any particular `ChatView`: views observe
/// `runs` for live text and the database for everything else.
@MainActor
@Observable
public final class ChatService {
    public static let shared = ChatService()

    private let database: AppDatabase
    private let autoTitling: AutoTitlingService

    /// Latest run per chat. Kept after completion (with `isActive == false`) until the next run,
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

    /// Live text for `messageId` while it is being generated.
    public func liveState(chatId: String, messageId: String) -> ChatRunState? {
        guard let run = runs[chatId], run.messageId == messageId else { return nil }
        return run
    }

    /// Stops generation. The partial reply is kept and marked cancelled.
    public func cancel(chatId: String) {
        tasks[chatId]?.cancel()
    }

    /// Appends the user's message and starts generating a reply.
    public func send(
        chatId: String,
        content: String,
        attachments: [Attachment] = [],
        provider: Provider,
        model: String,
        preset: Preset? = nil
    ) throws {
        cancel(chatId: chatId)
        let userMessage = Message(chatId: chatId, role: .user, content: content, attachments: attachments)
        try database.addMessage(userMessage)
        try generateReply(chatId: chatId, backend: cloudBackend(provider: provider, model: model), preset: preset)
    }

    /// Drops `messageId` and everything after it, then generates a fresh reply to the remaining history.
    public func regenerate(
        chatId: String,
        fromMessageId messageId: String,
        provider: Provider,
        model: String,
        preset: Preset? = nil
    ) throws {
        cancel(chatId: chatId)
        try database.deleteMessagesFrom(chatId: chatId, messageId: messageId)
        try generateReply(chatId: chatId, backend: cloudBackend(provider: provider, model: model), preset: preset)
    }

    private func cloudBackend(provider: Provider, model: String) -> OpenAICompatibleBackend {
        OpenAICompatibleBackend(provider: provider, apiKey: database.apiKey(providerId: provider.id), model: model)
    }

    // MARK: - Generation

    private func generateReply(chatId: String, backend: any ChatBackend, preset: Preset?) throws {
        let descriptor = backend.descriptor
        let placeholder = try database.addMessage(Message(
            chatId: chatId,
            role: .assistant,
            content: "",
            status: .streaming,
            backend: descriptor.kind,
            providerId: descriptor.providerId,
            model: descriptor.model
        ))

        let token = UUID()
        runs[chatId] = ChatRunState(token: token, messageId: placeholder.id)
        beginBackgroundTask(chatId: chatId)

        let job = ReplyJob(
            database: database,
            chatId: chatId,
            messageId: placeholder.id,
            backend: backend,
            preset: preset
        )

        tasks[chatId] = Task { [weak self] in
            let outcome = await job.run { [weak self] batch in
                await self?.apply(batch, chatId: chatId, token: token)
            }
            self?.finish(chatId: chatId, token: token, job: job, outcome: outcome)
        }
    }

    private func apply(_ batch: StreamBatcher.Batch, chatId: String, token: UUID) {
        guard runs[chatId]?.token == token else { return }
        runs[chatId]?.content += batch.content
        runs[chatId]?.reasoning += batch.reasoning
    }

    private func finish(chatId: String, token: UUID, job: ReplyJob, outcome: ReplyJob.Outcome) {
        // A newer run may have replaced this one (send right after cancel); leave it alone.
        guard runs[chatId]?.token == token else { return }
        runs[chatId]?.isActive = false
        tasks.removeValue(forKey: chatId)
        endBackgroundTask(chatId: chatId)

        guard outcome.status == .done else { return }
        let autoTitling = autoTitling
        Task {
            await autoTitling.generateTitleIfNeeded(
                chatId: chatId,
                userPrompt: outcome.lastUserPrompt,
                assistantReply: outcome.content,
                backend: job.backend
            )
        }
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
    private static func belongsInContext(_ message: Message) -> Bool {
        guard message.role == .assistant else { return true }
        switch message.status {
        case .done, .cancelled:
            return !message.content.isEmpty
        case .failed, .streaming:
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
