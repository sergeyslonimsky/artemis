import Foundation
import UIKit

@MainActor
@Observable
public final class ChatService {
    public static let shared = ChatService()

    private let database: AppDatabase
    private let autoTitling: AutoTitlingService
    private var activeTasks: [String: Task<Void, Never>] = [:]

    /// Tracks which chats are currently generating: [chatId: isBusy]
    public private(set) var runningChats: Set<String> = []

    public init(database: AppDatabase = .shared) {
        self.database = database
        self.autoTitling = AutoTitlingService(database: database)
    }

    public func isRunning(chatId: String) -> Bool {
        runningChats.contains(chatId)
    }

    public func cancel(chatId: String) {
        activeTasks[chatId]?.cancel()
        activeTasks.removeValue(forKey: chatId)
        runningChats.remove(chatId)
    }

    public func send(
        chatId: String,
        content: String,
        attachments: [Attachment] = [],
        provider: Provider,
        model: String,
        preset: Preset? = nil,
        onDelta: @escaping @MainActor (String, String) -> Void,
        onComplete: @escaping @MainActor (Result<Message, Error>) -> Void
    ) {
        // Cancel any in-flight stream for this chat
        cancel(chatId: chatId)
        runningChats.insert(chatId)

        let task = Task {
            var backgroundTaskID = UIBackgroundTaskIdentifier.invalid
            backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "ArtemisStream-\(chatId)") {
                Task { @MainActor in
                    if backgroundTaskID != .invalid {
                        UIApplication.shared.endBackgroundTask(backgroundTaskID)
                        backgroundTaskID = .invalid
                    }
                }
            }

            defer {
                Task { @MainActor in
                    self.runningChats.remove(chatId)
                    self.activeTasks.removeValue(forKey: chatId)
                    if backgroundTaskID != .invalid {
                        UIApplication.shared.endBackgroundTask(backgroundTaskID)
                    }
                }
            }

            do {
                // 1. Add user message
                let userMessage = Message(
                    chatId: chatId,
                    role: .user,
                    content: content,
                    attachments: attachments
                )
                try database.addMessage(userMessage)

                // 2. Prepare assistant placeholder
                let assistantId = UUID().uuidString.lowercased()
                let assistantPlaceholder = Message(
                    id: assistantId,
                    chatId: chatId,
                    role: .assistant,
                    content: "",
                    reasoning: ""
                )
                try database.addMessage(assistantPlaceholder)

                // 3. Read conversation history
                let history = try database.fetchMessages(chatId: chatId).filter { $0.id != assistantId }
                let settings = try database.fetchSettings()

                let client = LLMClient(baseUrl: provider.baseUrl, apiKey: provider.apiKey)
                let request = LLMRequest(
                    model: model,
                    messages: history,
                    systemPrompt: settings.systemPrompt,
                    preset: preset
                )

                var accumulatedContent = ""
                var accumulatedReasoning = ""

                let batcher = StreamBatcher(flushInterval: 0.050) { c, r in
                    Task { @MainActor in
                        onDelta(c, r)
                    }
                }

                var finalStats: MessageStats?

                for try await event in client.stream(request: request) {
                    if Task.isCancelled { break }

                    switch event {
                    case .content(let delta):
                        accumulatedContent += delta
                        await batcher.appendContent(delta)

                    case .reasoning(let delta):
                        accumulatedReasoning += delta
                        await batcher.appendReasoning(delta)

                    case .done(let tokens, let isEstimated, let durationMs):
                        await batcher.flush()
                        finalStats = MessageStats(tokens: tokens, isEstimated: isEstimated, durationMs: durationMs)

                    case .error(let errorMsg):
                        await batcher.flush()
                        throw NSError(domain: "ChatService", code: 1, userInfo: [NSLocalizedDescriptionKey: errorMsg])
                    }
                }

                await batcher.flush()

                // 4. Record finished message in database
                try database.finishMessage(
                    id: assistantId,
                    content: accumulatedContent,
                    reasoning: accumulatedReasoning,
                    stats: finalStats
                )

                let finishedMessage = Message(
                    id: assistantId,
                    chatId: chatId,
                    role: .assistant,
                    content: accumulatedContent,
                    reasoning: accumulatedReasoning,
                    stats: finalStats
                )

                // 5. Trigger auto-titling in background
                Task {
                    await self.autoTitling.generateTitleIfNeeded(
                        chatId: chatId,
                        userPrompt: content,
                        assistantReply: accumulatedContent,
                        client: client,
                        model: model
                    )
                }

                onComplete(.success(finishedMessage))
            } catch {
                onComplete(.failure(error))
            }
        }

        activeTasks[chatId] = task
    }
}
