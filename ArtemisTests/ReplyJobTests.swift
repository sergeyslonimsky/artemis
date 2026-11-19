import Foundation
import Testing
import UIKit
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
        let backend = FakeBackend(kind: .cloud, events: [], failure: LLMError.provider("Rate limited"))
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

    @Test func translationToolOnlyOnDeviceAndIndependentOfDeviceData() async throws {
        let (database, chatId, replyId) = try setUp()
        var settings = try database.fetchSettings()
        settings.personalDataTools = false
        try database.saveSettings(settings)

        let onDevice = RecordingBackend(kind: .onDevice)
        _ = await ReplyJob(
            database: database, chatId: chatId, messageId: replyId, backend: onDevice, preset: nil, offersTranslation: true
        ).run(onBatch: { _ in })
        #expect(onDevice.lastTurn?.offersTranslation == true)

        let cloud = RecordingBackend(kind: .cloud)
        _ = await ReplyJob(
            database: database, chatId: chatId, messageId: replyId, backend: cloud, preset: nil, offersTranslation: true
        ).run(onBatch: { _ in })
        #expect(cloud.lastTurn?.offersTranslation == false)
    }

    @Test func onDeviceTurnsReadAndKeepTextOfUnreadImages() async throws {
        let blank = try AttachmentProcessor.downscaledJPEG(from: UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).pngData { _ in })
        let unread = Attachment(filename: "photo.jpg", mime: "image/jpeg", kind: .image, data: blank)
        let read = Attachment(filename: "receipt.jpg", mime: "image/jpeg", kind: .image, recognizedText: "TOTAL 9.99", data: blank)
        let (database, chatId, replyId) = try setUp(history: [userMessage("Look", attachments: [unread, read])])

        let cloud = RecordingBackend(kind: .cloud)
        _ = await ReplyJob(database: database, chatId: chatId, messageId: replyId, backend: cloud, preset: nil).run(onBatch: { _ in })
        #expect(cloud.lastTurn?.messages.first?.attachments.first?.recognizedText == nil)

        let onDevice = RecordingBackend(kind: .onDevice)
        _ = await ReplyJob(database: database, chatId: chatId, messageId: replyId, backend: onDevice, preset: nil).run(onBatch: { _ in })
        #expect(onDevice.lastTurn?.messages.first?.attachments.map(\.recognizedText) == ["", "TOTAL 9.99"])
        let stored = try #require(try database.fetchMessages(chatId: chatId).first).attachments
        #expect(stored.map(\.recognizedText) == ["", "TOTAL 9.99"])
    }

    @Test func readsAtMostAFewImagesPerTurn() async throws {
        let blank = try AttachmentProcessor.downscaledJPEG(from: UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).pngData { _ in })
        let images = (1...6).map { Attachment(filename: "\($0).jpg", mime: "image/jpeg", kind: .image, data: blank) }
        let (database, chatId, replyId) = try setUp(history: [userMessage("Look", attachments: images)])

        _ = await ReplyJob(database: database, chatId: chatId, messageId: replyId, backend: RecordingBackend(kind: .onDevice), preset: nil)
            .run(onBatch: { _ in })
        let stored = try #require(try database.fetchMessages(chatId: chatId).first).attachments
        #expect(stored.count { $0.recognizedText != nil } == ReplyJob.maxImagesReadPerTurn)
    }

    @Test func voiceRepliesAskForSpokenAnswers() async throws {
        let (database, chatId, replyId) = try setUp()
        let backend = RecordingBackend(kind: .cloud)
        _ = await ReplyJob(database: database, chatId: chatId, messageId: replyId, backend: backend, preset: nil, isVoice: true)
            .run(onBatch: { _ in })
        #expect(backend.lastTurn?.systemPrompt?.contains("talking to you by voice") == true)
    }
}
