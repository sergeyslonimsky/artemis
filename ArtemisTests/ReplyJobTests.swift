import Foundation
import Testing
@testable import Artemis

@Suite("Reply job")
struct ReplyJobTests {
    /// A chat with one user message and an empty reply placeholder.
    func setUp(history: [Message] = []) throws -> (AppDatabase, chatId: String, replyId: String) {
        let database = try makeDatabase()
        let chat = try database.createChat(title: "Test")
        for message in history {
            var message = message
            message.chatId = chat.id
            try database.addMessage(message)
        }
        try database.addMessage(Message(chatId: chat.id, role: .user, content: "Question"))
        let reply = try database.addMessage(Message(chatId: chat.id, role: .assistant, content: "", status: .streaming))
        return (database, chat.id, reply.id)
    }

    func reply(_ database: AppDatabase, _ id: String) throws -> Message {
        try #require(try database.fetchMessages(chatId: try database.fetchChats().first!.id).first { $0.id == id })
    }

    @Test func persistsContentStatsAndExtras() async throws {
        let (database, chatId, replyId) = try setUp()
        let draft = ActionDraft(kind: .reminder, title: "Buy milk")
        let backend = FakeBackend(events: [
            .toolStarted(.reminders),
            .content("Hello"),
            .content(" there"),
            .actionDraft(draft),
            .done(tokens: 3, isEstimated: false, durationMs: 120),
        ])
        let job = ReplyJob(database: database, chatId: chatId, messageId: replyId, backend: backend, preset: nil)
        let outcome = await job.run(onBatch: { _ in })

        #expect(outcome.status == .done)
        let saved = try reply(database, replyId)
        #expect(saved.content == "Hello there")
        #expect(saved.status == .done)
        #expect(saved.stats?.tokens == 3)
        #expect(saved.extras.personalDataUsed == [.reminders])
        #expect(saved.extras.drafts.map(\.title) == ["Buy milk"])
    }

    @Test func providerErrorMarksTheReplyFailed() async throws {
        let (database, chatId, replyId) = try setUp()
        let backend = FakeBackend(kind: .cloud, events: [.error("Rate limited")])
        let outcome = await ReplyJob(database: database, chatId: chatId, messageId: replyId, backend: backend, preset: nil)
            .run(onBatch: { _ in })

        #expect(outcome.status == .failed)
        #expect(try reply(database, replyId).error == "Rate limited")
    }

    @Test func onDeviceFailureIsReportedForEscalation() async throws {
        let (database, chatId, replyId) = try setUp()
        let backend = FakeBackend(events: [], failure: OnDeviceError.contextTooLong)
        let outcome = await ReplyJob(database: database, chatId: chatId, messageId: replyId, backend: backend, preset: nil)
            .run(onBatch: { _ in })

        #expect(outcome.onDeviceError == .contextTooLong)
    }

    @Test func emptyResponseFails() async throws {
        let (database, chatId, replyId) = try setUp()
        let outcome = await ReplyJob(database: database, chatId: chatId, messageId: replyId, backend: FakeBackend(events: []), preset: nil)
            .run(onBatch: { _ in })
        #expect(outcome.status == .failed)
    }

    @Test func cloudNeverSeesPrivateRepliesOrTools() async throws {
        var privateReply = Message(chatId: "", role: .assistant, content: "You have a dentist appointment at 3pm.")
        privateReply.extras = MessageExtras(personalDataUsed: [.calendar])
        let (database, chatId, replyId) = try setUp(history: [userMessage("What do I have today?"), privateReply])

        let backend = RecordingBackend(kind: .cloud)
        _ = await ReplyJob(
            database: database, chatId: chatId, messageId: replyId, backend: backend, preset: nil,
            toolGroups: Set(ToolGroup.allCases)
        ).run(onBatch: { _ in })

        let turn = try #require(backend.lastTurn)
        #expect(turn.toolGroups.isEmpty)
        #expect(!turn.messages.contains { $0.content.contains("dentist") })
        #expect(turn.messages.contains { $0.content.contains("private data (calendar)") })
    }

    @Test func onDeviceGetsOnlyEnabledTools() async throws {
        let (database, chatId, replyId) = try setUp()
        var settings = try database.fetchSettings()
        settings.disabledToolGroups = [.health]
        try database.saveSettings(settings)

        let backend = RecordingBackend(kind: .onDevice)
        _ = await ReplyJob(
            database: database, chatId: chatId, messageId: replyId, backend: backend, preset: nil,
            toolGroups: [.health, .weather]
        ).run(onBatch: { _ in })

        #expect(backend.lastTurn?.toolGroups == [.weather])
    }

    @Test func voiceRepliesAskForSpokenAnswers() async throws {
        let (database, chatId, replyId) = try setUp()
        let backend = RecordingBackend(kind: .cloud)
        _ = await ReplyJob(database: database, chatId: chatId, messageId: replyId, backend: backend, preset: nil, isVoice: true)
            .run(onBatch: { _ in })
        #expect(backend.lastTurn?.systemPrompt?.contains("talking to you by voice") == true)
    }
}
