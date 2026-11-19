import Foundation
import NaturalLanguage

extension Locale.Language {
    /// The language most of `text` is written in; `nil` when it can't be told or the text is
    /// shorter than `minimumLength`.
    init?(detectedIn text: String, minimumLength: Int = 1) {
        guard text.count >= minimumLength else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        self.init(identifier: language.rawValue)
    }
}
