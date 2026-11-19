import Foundation
import FoundationModels
import Translation

/// Translates with Apple's translation models, which beat the small language model at it and
/// cover languages it doesn't support. Works for languages downloaded on the device.
struct TranslateTool: Tool {
    let sink: ToolEventSink

    let name = "translate"
    let description = "Translates text into another language on the device."

    static let instructions = "To translate text into another language, call translate and give the user its result."

    @Generable
    struct Arguments {
        @Guide(description: "The exact text to translate")
        var text: String
        @Guide(description: "Target language in English, e.g. \"Russian\" or \"German\"")
        var targetLanguage: String
    }

    func call(arguments: Arguments) async throws -> String {
        let text = arguments.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "There is no text to translate." }
        guard let target = await Self.language(named: arguments.targetLanguage) else {
            return "\(arguments.targetLanguage) isn't a language on-device translation knows. Write the translation in your reply yourself."
        }
        guard let source = Locale.Language(detectedIn: text) else {
            return "Couldn't tell which language the text is in. Write the translation in your reply yourself."
        }
        if source.languageCode == target.languageCode {
            return "The text is already in \(target.englishName)."
        }

        guard await LanguageAvailability().status(from: source, to: target) == .installed else {
            return "Translation into \(target.englishName) isn't downloaded on this device. Write the translation in your reply yourself, "
                + "and tell the user they can download the language in Settings › On-device model › Translation."
        }
        sink.send(.started(.translation))
        do {
            let translated = try await TranslationSession(installedSource: source, target: target).translate(text).targetText
            return "Translation into \(target.englishName):\n\(translated)"
        } catch {
            return "On-device translation failed: \(error.localizedDescription). Write the translation in your reply yourself."
        }
    }

    /// "Russian", "russian", "ru" or "pt-BR" → a language translation supports. A language with
    /// regional variants resolves to the plain one ("Portuguese" over "Portuguese (Brazil)").
    static func language(named name: String) async -> Locale.Language? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let supported = await LanguageAvailability().supportedLanguages
        let matches = { (candidate: String?) in candidate?.caseInsensitiveCompare(trimmed) == .orderedSame }
        if let exact = supported.first(where: { matches($0.minimalIdentifier) || matches($0.languageCode?.identifier) }) {
            return exact
        }
        let named = supported.filter { matches($0.englishName) }
        return named.first { $0.region == nil } ?? named.first
    }
}
