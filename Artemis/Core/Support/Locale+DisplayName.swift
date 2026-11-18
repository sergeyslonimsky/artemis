import Foundation

extension Locale.Language {
    /// "English (United Kingdom)", in the user's language; script subtags are left out.
    var displayName: String? {
        guard let code = languageCode?.identifier else { return nil }
        let identifier = region.map { "\(code)-\($0.identifier)" } ?? code
        return Locale.current.localizedString(forIdentifier: identifier)
    }
}

extension Locale {
    /// The language (and region) for menus, e.g. "Polish" or "English (United States)".
    var displayName: String {
        language.displayName ?? identifier
    }
}
