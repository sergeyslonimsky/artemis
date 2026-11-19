import Foundation
import os

/// The translation side of an on-device turn in a language the model doesn't speak: the prompt
/// and history reach the model in English, and the reply is translated back paragraph by
/// paragraph as it streams. Serves one turn.
final class TranslatedTurn {
    private let translator: OnDeviceTranslator
    /// English the reply hasn't finished a paragraph of yet.
    private var english = ""
    /// Whether the model replied in another language, to show as is; decided once enough text arrived.
    private var keepsOriginal: Bool?

    private static let logger = Logger(subsystem: "com.artemis.ios", category: "TranslatedTurn")

    /// `nil` unless the conversation's language needs translating and is installed.
    init?(messages: [Message]) async {
        guard let translator = await OnDeviceTranslator.forText(Self.languageSample(of: messages)) else { return nil }
        self.translator = translator
    }

    /// Added to the model's instructions. The language isn't named: told the user writes
    /// Russian, the model wrote broken Russian, which then went through translation again.
    let instructions = """
        The user's messages are machine-translated into English for you, and your reply is translated for them. \
        Write your reply and everything you pass to tools in clear, simple English only. \
        Keep names, numbers, addresses and code unchanged.
        """

    func prompt(_ text: String) async throws -> String {
        try await reportingFailure { try await translator.toEnglish(text) }
    }

    /// Best effort: a message that can't be translated (say, one in another language) stays as is.
    func history(_ text: String) async -> String {
        (try? await translator.toEnglish(text)) ?? text
    }

    /// The reply's paragraphs that `delta` completes, translated; empty while one is still being
    /// written. Line by line was too little: short lines lost their context ("Alarm set." came
    /// back as "Audit set").
    func reply(_ delta: String) async throws -> String {
        english += delta
        guard let end = OnDeviceTranslator.MarkdownBlock.completedEnd(of: english) else { return "" }
        let done = String(english[..<end])
        english.removeSubrange(..<end)
        return try await translate(done)
    }

    /// What's left of the reply once it ends, or fails partway.
    func finishReply() async throws -> String {
        let rest = english
        english = ""
        return try await translate(rest)
    }

    /// Paragraphs at once, list items and headings one by one, code as is.
    private func translate(_ text: String) async throws -> String {
        // A reply already in another language would come back garbled.
        if keepsOriginal == nil, let language = Locale.Language(detectedIn: text, minimumLength: 20)?.languageCode {
            keepsOriginal = language != .english
        }
        guard keepsOriginal != true else { return text }
        var output: [String] = []
        for block in OnDeviceTranslator.MarkdownBlock.blocks(of: text) {
            switch block {
            case .verbatim(let line):
                output.append(line)
            case .paragraph(let paragraph):
                output.append(try await reportingFailure { try await translator.fromEnglish(markdown: paragraph) })
            case .item(let marker, let item):
                output.append(marker + (try await reportingFailure { try await translator.fromEnglish(markdown: item) }))
            }
        }
        return output.joined(separator: "\n")
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
