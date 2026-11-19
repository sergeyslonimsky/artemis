import Foundation

extension Locale.Language {
    /// "English (United Kingdom)", in the user's language; script subtags are left out.
    var displayName: String? {
        guard let code = languageCode?.identifier else { return nil }
        let identifier = region.map { "\(code)-\($0.identifier)" } ?? code
        return Locale.current.localizedString(forIdentifier: identifier)
    }

    /// The language without its region, "Chinese (Simplified)" or "Russian", in the user's language.
    var languageName: String {
        name(in: .current)
    }

    /// The language without its region in English, for instructions to models.
    var englishName: String {
        name(in: Locale(identifier: "en"))
    }

    /// Language and script, e.g. "zh-Hans": regional variants share it.
    var languageIdentifier: String {
        [languageCode?.identifier, script?.identifier].compactMap(\.self).joined(separator: "-")
    }

    private func name(in locale: Locale) -> String {
        locale.localizedString(forIdentifier: languageIdentifier) ?? minimalIdentifier
    }
}

extension Locale {
    /// The language (and region) for menus, e.g. "Polish" or "English (United States)".
    var displayName: String {
        language.displayName ?? identifier
    }
}
