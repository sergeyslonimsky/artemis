import Foundation
import GRDB
import Testing
@testable import Artemis

@Suite("Database")
struct DatabaseTests {
    @Test func migrationsProduceDefaults() throws {
        let database = try makeDatabase()
        let settings = try database.fetchSettings()
        #expect(settings.routingMode == .auto)
        #expect(settings.cloudPolicy == .alwaysAsk)
        #expect(settings.personalDataTools)
        #expect(settings.enabledToolGroups == Set(ToolGroup.allCases))
        #expect(settings.favoriteModels.isEmpty)
    }

    @Test func settingsRoundTrip() throws {
        let database = try makeDatabase()
        var settings = try database.fetchSettings()
        settings.cloudPolicy = .deny
        settings.disabledToolGroups = [.health, .contacts]
        settings.favoriteModels = [ModelRef(providerId: "p", model: "openai/gpt-5.1")]
        settings.systemPrompt = "Be brief."
        try database.saveSettings(settings)

        let loaded = try database.fetchSettings()
        #expect(loaded.cloudPolicy == .deny)
        #expect(loaded.enabledToolGroups == Set(ToolGroup.allCases).subtracting([.health, .contacts]))
        #expect(loaded.favoriteModels == settings.favoriteModels)
        #expect(loaded.systemPrompt == "Be brief.")
    }

    @Test func providerRoundTripKeepsKeyOutOfTheRecord() throws {
        let database = try makeDatabase()
        let provider = Provider(
            name: "OpenRouter", kind: .openRouter, baseUrl: "https://openrouter.ai/api/v1",
            models: ["a:free", "b"], modelCapabilities: ["b": ["tools"]], onlyFreeModels: true
        )
        try database.saveProvider(provider, apiKey: "secret")

        let loaded = try #require(try database.fetchProviders().first)
        #expect(loaded.kind == .openRouter)
        #expect(loaded.models == ["a:free", "b"])
        #expect(loaded.onlyFreeModels)
        #expect(loaded.supportsWebSearch(model: "b"))
        #expect(database.apiKey(providerId: provider.id) == "secret")
    }

    @Test func messagesGetIncreasingSeqAndDeleteFromTruncates() throws {
        let database = try makeDatabase()
        let chat = try database.createChat(title: "Test")
        let first = try database.addMessage(Message(chatId: chat.id, role: .user, content: "1"))
        let second = try database.addMessage(Message(chatId: chat.id, role: .assistant, content: "2"))
        let third = try database.addMessage(Message(chatId: chat.id, role: .user, content: "3"))
        #expect(first.seq < second.seq && second.seq < third.seq)

        try database.deleteMessagesFrom(chatId: chat.id, messageId: second.id)
        #expect(try database.fetchMessages(chatId: chat.id).map(\.content) == ["1"])
    }

    @Test func recognizedImageTextPersists() throws {
        let database = try makeDatabase()
        let chat = try database.createChat(title: "Test")
        let scan = Attachment(filename: "scan.jpg", mime: "image/jpeg", kind: .image, isScan: true, data: Data([1]))
        let photo = Attachment(filename: "photo.jpg", mime: "image/jpeg", kind: .image, data: Data([2]))
        try database.addMessage(Message(chatId: chat.id, role: .user, content: "", attachments: [scan, photo]))
        try database.setRecognizedText("TOTAL 9.99", attachmentId: scan.id)

        let loaded = try #require(try database.fetchMessages(chatId: chat.id).first).attachments
        #expect(loaded.map(\.recognizedText) == ["TOTAL 9.99", nil])
        #expect(loaded.map(\.isScan) == [true, false])
    }

    @Test func extrasAndDraftStatusPersist() throws {
        let database = try makeDatabase()
        let chat = try database.createChat(title: "Test")
        let reply = try database.addMessage(Message(chatId: chat.id, role: .assistant, content: "", status: .streaming))
        let draft = ActionDraft(kind: .alarm, title: "Wake up", date: Date(timeIntervalSince1970: 1_800_000_000))
        try database.finishMessage(
            id: reply.id, content: "Ready.", reasoning: "", status: .done, error: nil, stats: nil,
            extras: MessageExtras(personalDataUsed: [.calendar], drafts: [draft])
        )
        try database.setDraftStatus(messageId: reply.id, draftId: draft.id, status: .added)

        let loaded = try #require(try database.fetchMessages(chatId: chat.id).first)
        #expect(loaded.extras.personalDataUsed == [.calendar])
        #expect(loaded.extras.drafts.first?.status == .added)
        #expect(loaded.extras.usedPrivateData)
    }

    @Test func recentModelsComeFromChats() throws {
        let database = try makeDatabase()
        try database.saveProvider(Provider(id: "p", name: "P", baseUrl: "https://p.example/v1", models: ["old", "new"]), apiKey: "")
        try database.createChat(title: "A", providerId: "p", model: "old", now: Date(timeIntervalSince1970: 100))
        try database.createChat(title: "B", providerId: "p", model: "new", now: Date(timeIntervalSince1970: 200))
        try database.createChat(title: "C")
        #expect(try database.recentModels() == [ModelRef(providerId: "p", model: "new"), ModelRef(providerId: "p", model: "old")])
    }

    @Test func toolGroupListMigratesFromCSV() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v14_favorite_models")
        try queue.write { db in
            try db.execute(sql: "UPDATE settings SET disabled_tool_groups = 'health,contacts' WHERE id = 1")
        }
        let attachments = FileManager.default.temporaryDirectory.appending(path: "artemis-tests-\(UUID().uuidString)")
        let database = try AppDatabase(queue, attachmentsDirectory: attachments, apiKeys: InMemoryAPIKeyStore())

        #expect(try database.fetchSettings().disabledToolGroups == [.health, .contacts])
    }

    @Test func searchReturnsWholeChats() throws {
        let database = try makeDatabase()
        let chat = try database.createChat(title: "Trip", routingMode: .cloud, providerId: nil, model: "m")
        try database.addMessage(Message(chatId: chat.id, role: .user, content: "Pack the umbrella for Paris"))

        let hit = try #require(try database.search(query: "umbrella").first)
        #expect(hit.chat.id == chat.id)
        #expect(hit.chat.routingMode == .cloud)
        #expect(hit.chat.model == "m")
        #expect(hit.snippet.contains("umbrella"))
    }

    @Test func generatedTitleNeverReplacesAManualOne() throws {
        let database = try makeDatabase()
        let chat = try database.createChat(title: "New Chat")
        try database.renameChat(chatId: chat.id, title: "Mine")

        #expect(try !database.setGeneratedTitle(chatId: chat.id, title: "Generated"))
        #expect(try database.fetchChat(id: chat.id)?.title == "Mine")
    }
}
