import Foundation
import os

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
        var extras = MessageExtras()
    }

    let database: AppDatabase
    let chatId: String
    let messageId: String
    let backend: any ChatBackend
    let preset: Preset?
    /// On-device tools the route allows; narrowed further by the settings.
    var toolGroups: Set<ToolGroup> = []
    /// The reply will be read aloud.
    var isVoice = false

    private static let voiceInstructions = """
        The user is talking to you by voice and hears your reply read aloud. Answer conversationally, \
        in a few short spoken sentences. Don't use Markdown, lists, tables, emoji or code unless the user asks. \
        When you prepare a draft, say the user can say "yes" or tap the card to confirm it.
        """

    private static let logger = Logger(subsystem: "com.artemis.ios", category: "ReplyJob")

    @concurrent
    func run(
        onBatch: @escaping @Sendable (StreamBatcher.Batch) async -> Void,
        onActivity: @escaping @Sendable (PersonalDataSource?) async -> Void = { _ in }
    ) async -> Outcome {
        var outcome = Outcome()
        var batcher = StreamBatcher()

        do {
            let turn = try makeTurn()
            outcome.lastUserPrompt = turn.messages.last(where: { $0.role == .user })?.content ?? ""

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
                case .toolStarted(let source):
                    if !outcome.extras.personalDataUsed.contains(source) {
                        outcome.extras.personalDataUsed.append(source)
                    }
                    await onActivity(source)
                case .actionDraft(let draft):
                    outcome.extras.drafts.append(draft)
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
                stats: outcome.stats,
                extras: outcome.extras
            )
        } catch {
            Self.logger.error("Failed to persist reply \(messageId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        return outcome
    }

    /// The history and instructions to answer with. The cloud never sees private replies or tools.
    private func makeTurn() throws -> ChatTurn {
        let isCloud = backend.descriptor.kind == .cloud
        let history = try database.fetchMessages(chatId: chatId, includeAttachmentData: true)
            .filter { $0.id != messageId && Self.belongsInContext($0) }
            .map { isCloud ? Self.withoutPersonalData($0) : $0 }
        let settings = try database.fetchSettings()

        var systemPrompt = settings.systemPrompt
        var preset = preset
        if isVoice {
            // A preset's prompt replaces the default one, so the note goes wherever the prompt is.
            if var custom = preset, !custom.systemPrompt.isEmpty {
                custom.systemPrompt += "\n\n" + Self.voiceInstructions
                preset = custom
            } else {
                systemPrompt = systemPrompt.isEmpty ? Self.voiceInstructions : systemPrompt + "\n\n" + Self.voiceInstructions
            }
        }

        var turn = ChatTurn(messages: history, systemPrompt: systemPrompt, preset: preset)
        turn.conversationId = chatId
        turn.replyId = messageId
        turn.toolGroups = isCloud ? [] : toolGroups.intersection(settings.enabledToolGroups)
        return turn
    }

    /// Replies built from the user's private data stay on the device: the cloud provider sees that
    /// such a reply existed, not what it said.
    static func withoutPersonalData(_ message: Message) -> Message {
        guard message.role == .assistant, message.extras.usedPrivateData else { return message }
        var redacted = message
        let sources = message.extras.personalDataUsed.filter(\.isPrivate).map(\.rawValue).joined(separator: ", ")
        redacted.content = "[An on-device answer based on the user's private data (\(sources)), not shared.]"
        return redacted
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
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .emptyResponse: "The model returned an empty response."
        }
    }
}
