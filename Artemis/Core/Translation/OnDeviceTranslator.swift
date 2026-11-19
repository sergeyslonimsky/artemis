import Foundation
import Synchronization
import Translation

/// Apple's on-device translation between a language and English, the on-device model's best
/// language. Sessions made without SwiftUI can't download languages, so this only works for
/// pairs already installed (Settings › On-device model › Translation, or the Translate app).
/// An instance isn't shared between tasks; translations into English are cached for the process.
final class OnDeviceTranslator {
    static let english = Locale.Language(identifier: "en")

    let language: Locale.Language
    private let toEnglishSession: TranslationSession
    private let fromEnglishSession: TranslationSession

    /// The router and the backend translate the same message, and every turn that rebuilds the
    /// model's session translates the history again. Keyed by language and text.
    private static let englishCache = Mutex<[String: String]>([:])
    private static let cacheLimit = 500

    private init(language: Locale.Language) {
        self.language = language
        toEnglishSession = TranslationSession(installedSource: language, target: Self.english)
        fromEnglishSession = TranslationSession(installedSource: Self.english, target: language)
    }

    /// A translator for `text`'s language when the on-device model doesn't support it and the
    /// language is installed for translation; otherwise `nil` (the model reads `text` as is).
    static func forText(_ text: String) async -> OnDeviceTranslator? {
        guard let language = Locale.Language(detectedIn: text, minimumLength: 8),
              !OnDeviceModel.speaks(language),
              await isInstalled(language) else {
            return nil
        }
        return OnDeviceTranslator(language: language)
    }

    /// Whether both directions between `language` and English work without a download.
    static func isInstalled(_ language: Locale.Language) async -> Bool {
        guard language.languageCode != english.languageCode else { return false }
        async let there = LanguageAvailability().status(from: language, to: english)
        async let back = LanguageAvailability().status(from: english, to: language)
        let statuses = await (there, back)
        return statuses == (.installed, .installed)
    }

    // MARK: - Translating

    func toEnglish(_ text: String) async throws -> String {
        guard Self.hasWords(text) else { return text }
        let key = language.languageIdentifier + "\u{1}" + text
        if let cached = Self.englishCache.withLock({ $0[key] }) { return cached }
        let english = try await toEnglishSession.translate(text).targetText
        Self.englishCache.withLock { cache in
            if cache.count >= Self.cacheLimit { cache.removeAll() }
            cache[key] = english
        }
        return english
    }

    func fromEnglish(_ text: String) async throws -> String {
        guard Self.hasWords(text) else { return text }
        return try await fromEnglishSession.translate(text).targetText
    }

    /// Inline code, link targets and bare URLs are marked to be left as they are.
    func fromEnglish(markdown text: String) async throws -> String {
        guard Self.hasWords(text) else { return text }
        var attributed = AttributedString(text)
        for match in text.matches(of: /`[^`]+`|\]\([^)]*\)|https?:\/\/\S+/) {
            if let range = Range(match.range, in: attributed) {
                attributed[range].translation.skipsTranslation = true
            }
        }
        let response = try await fromEnglishSession.translate(attributed)
        return response.attributedTargetText.map { String($0.characters) } ?? response.targetText
    }

    /// Lines with nothing to translate (rules, separators, numbers) would only fail.
    private static func hasWords(_ text: String) -> Bool {
        text.contains(where: \.isLetter)
    }

    // MARK: - Markdown

    /// Translates Markdown one line at a time, as the reply streams: code blocks stay as they are,
    /// and list, heading and quote markers are kept out of the translation.
    struct MarkdownLines {
        private var inCodeBlock = false

        mutating func translate(_ line: String, with translator: OnDeviceTranslator) async throws -> String {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inCodeBlock.toggle()
                return line
            }
            guard !inCodeBlock else { return line }
            let (marker, text) = Self.split(line)
            return marker + (try await translator.fromEnglish(markdown: text))
        }

        /// "  - **Bold** text" → ("  - ", "**Bold** text").
        static func split(_ line: String) -> (marker: String, text: String) {
            guard let match = line.prefixMatch(of: /\s*(?:#{1,6}\s+|[-*+]\s+(?:\[[ xX]\]\s+)?|\d+[.)]\s+|>\s*)*/) else {
                return ("", line)
            }
            return (String(match.output), String(line[match.range.upperBound...]))
        }
    }

    // MARK: - Catalog

    /// What translation offers on this device, for the settings.
    struct Catalog: Sendable {
        struct Entry: Identifiable, Sendable {
            let language: Locale.Language
            let isInstalled: Bool
            /// Chats in this language need no translation.
            let isSpokenByModel: Bool
            var id: String { language.languageIdentifier }
            var name: String { language.languageName }
        }

        /// One entry per language; regional variants share a download ("English (US)", "(UK)").
        var languages: [Entry] = []
        /// Downloaded languages and the downloaded languages each one translates into.
        var directions: [(source: Locale.Language, targets: [Locale.Language])] = []

        func entry(for language: Locale.Language) -> Entry? {
            languages.first { $0.id == language.languageIdentifier }
        }
    }

    /// Languages are checked against English (a download always pairs with it), then the
    /// downloaded ones against each other: a handful of checks instead of every pair. Each check
    /// asks the system's translation service, so this takes a while; use `TranslationCatalogStore`.
    @concurrent
    static func catalog() async -> Catalog {
        var seen = Set<String>()
        let languages = await LanguageAvailability().supportedLanguages
            .filter { $0.languageCode != nil && seen.insert($0.languageIdentifier).inserted }
        let englishVariant = languages.first { $0.languageCode == english.languageCode } ?? english
        let others = languages.filter { $0 != englishVariant }

        let installedOthers = Set(zip(others, await statuses(others.map { ($0, englishVariant) }))
            .filter { $0.1 == .installed }
            .map(\.0.languageIdentifier))
        var catalog = Catalog()
        catalog.languages = languages.map { language in
            Catalog.Entry(
                language: language,
                isInstalled: language == englishVariant ? !installedOthers.isEmpty : installedOthers.contains(language.languageIdentifier),
                isSpokenByModel: OnDeviceModel.speaks(language)
            )
        }

        let installed = catalog.languages.filter(\.isInstalled).map(\.language)
        let pairs = installed.flatMap { source in installed.filter { $0 != source }.map { (source, $0) } }
        let pairStatuses = await statuses(pairs)
        for source in installed {
            let targets = zip(pairs, pairStatuses).filter { $0.0.0 == source && $0.1 == .installed }.map(\.0.1)
            if !targets.isEmpty { catalog.directions.append((source, targets)) }
        }
        return catalog
    }

    /// The user's preferred languages the on-device model doesn't speak, with whether each is
    /// downloaded: one check per language, quick enough to show right away.
    @concurrent
    static func preferredLanguages() async -> [(name: String, status: LanguageAvailability.Status)] {
        var seen = Set<String>()
        let languages = Locale.preferredLocales.map(\.language)
            .filter { seen.insert($0.languageIdentifier).inserted && !OnDeviceModel.speaks($0) }
        return zip(languages, await statuses(languages.map { ($0, english) })).map { ($0.languageName, $1) }
    }

    /// Statuses of language pairs, in the order given. A few at a time: dozens of parallel
    /// requests flood the translation service, which other apps (and the keyboard) rely on too.
    private static func statuses(_ pairs: [(Locale.Language, Locale.Language)]) async -> [LanguageAvailability.Status] {
        var results = Array(repeating: LanguageAvailability.Status.unsupported, count: pairs.count)
        await withTaskGroup(of: (Int, LanguageAvailability.Status).self) { group in
            var next = 0
            func addNext() {
                guard next < pairs.count, !Task.isCancelled else { return }
                let (index, pair) = (next, pairs[next])
                group.addTask { (index, await LanguageAvailability().status(from: pair.0, to: pair.1)) }
                next += 1
            }
            for _ in 0..<4 { addNext() }
            for await (index, status) in group {
                results[index] = status
                addNext()
            }
        }
        return results
    }
}

/// The catalog, loaded once and shared by the settings pages: leaving and reopening a page
/// doesn't ask the translation service again. The load runs at utility priority and isn't
/// cancelled with the page, so its result is ready next time.
actor TranslationCatalogStore {
    static let shared = TranslationCatalogStore()

    private var catalog: OnDeviceTranslator.Catalog?
    private var loading: Task<OnDeviceTranslator.Catalog, Never>?

    func catalog(refresh: Bool = false) async -> OnDeviceTranslator.Catalog {
        if refresh { catalog = nil }
        if let catalog { return catalog }
        let task = loading ?? Task.detached(priority: .utility) { await OnDeviceTranslator.catalog() }
        loading = task
        let loaded = await task.value
        loading = nil
        catalog = loaded
        return loaded
    }

    /// Languages may be downloaded or removed in the Translate settings while the app is away.
    func invalidate() {
        catalog = nil
    }
}
