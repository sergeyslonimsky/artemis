import Foundation

/// What a new chat starts with when it is opened from outside the app.
struct ChatLaunch: Equatable {
    /// The chat this launch belongs to; any other chat ignores it.
    let chatId: String
    var prompt = ""
    var attachments: [Attachment] = []
    var autoSend = false
    var voice = false
    var focusComposer = false
}

extension SharedInbox {
    /// Converts a shared item into a launch, like files picked in the composer, and removes it.
    /// Files that can't be read are left out.
    @concurrent
    static func takeLaunch(id: String, chatId: String) async throws -> ChatLaunch {
        defer { remove(id: id) }
        let (item, folder) = try item(id: id)
        let attachments = item.filenames.compactMap { name -> Attachment? in
            guard let data = try? Data(contentsOf: folder.appending(path: name)) else { return nil }
            return try? AttachmentProcessor.fileAttachment(from: data, filename: name)
        }
        return ChatLaunch(chatId: chatId, prompt: item.prompt, attachments: attachments, autoSend: item.autoSend)
    }
}
