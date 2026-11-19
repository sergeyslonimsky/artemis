import Foundation
import os

/// The translation side of an on-device turn in a language the model doesn't speak: the prompt
/// and history reach the model in English, and the reply is translated back line by line as it
/// streams. Serves one turn.
final class TranslatedTurn {
    private let translator: OnDeviceTranslator
    /// English the reply hasn't finished a line of yet.
    private var untranslated = ""
    private var markdown = OnDeviceTranslator.MarkdownLines()

    private static let logger = Logger(subsystem: "com.artemis.ios", category: "TranslatedTurn")

    /// `nil` unless the conversation's language needs translating and is installed.
    init?(messages: [Message]) async {
        guard let translator = await OnDeviceTranslator.forText(Self.languageSample(of: messages)) else { return nil }
        self.translator = translator
    }

    /// Added to the model's instructions.
    var instructions: String {
        let language = translator.language.englishName
        return """
            The user writes in \(language). Their messages are machine-translated into English for you, and your reply \
            is translated back into \(language). Reply in clear, simple English. Keep names, numbers, addresses and code unchanged.
            """
    }

    func prompt(_ text: String) async throws -> String {
        try await reportingFailure { try await translator.toEnglish(text) }
    }

    /// Best effort: a message that can't be translated (say, one in another language) stays as is.
    func history(_ text: String) async -> String {
        (try? await translator.toEnglish(text)) ?? text
    }

    /// The lines `delta` completes, translated; empty while a line is still being written.
    func reply(_ delta: String) async throws -> String {
        untranslated += delta
        var output = ""
        while let newline = untranslated.firstIndex(of: "\n") {
            let line = String(untranslated[..<newline])
            untranslated.removeSubrange(...newline)
            output += try await reportingFailure { try await markdown.translate(line, with: translator) } + "\n"
        }
        return output
    }

    /// The reply's last, unfinished line.
    func finishReply() async throws -> String {
        let rest = untranslated
        untranslated = ""
        return try await reportingFailure { try await markdown.translate(rest, with: translator) }
    }

    /// Titles and message bodies the user will see in their language.
    func draft(_ draft: ActionDraft) async -> ActionDraft {
        var translated = draft
        translated.title = (try? await translator.fromEnglish(draft.title)) ?? draft.title
        if let body = draft.body {
            translated.body = (try? await translator.fromEnglish(body)) ?? body
        }
        return translated
    }

    /// The latest user messages, enough to tell a short follow-up's language ("yes", "and tomorrow?").
    private static func languageSample(of messages: [Message]) -> String {
        let userTexts = messages.filter { $0.role == .user }.map(\.content).suffix(3)
        guard let last = userTexts.last, last.count < 20 else { return userTexts.last ?? "" }
        return userTexts.joined(separator: "\n")
    }

    /// A failure is reported like a language the model can't handle, which a cloud model may
    /// answer instead.
    private func reportingFailure(_ operation: () async throws -> String) async throws -> String {
        do {
            return try await operation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Self.logger.error("On-device translation failed: \(error.localizedDescription, privacy: .public)")
            throw OnDeviceError.unsupportedLanguage
        }
    }
}
