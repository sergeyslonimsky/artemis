import SwiftUI
// The download task hands over a session that isn't marked Sendable.
@preconcurrency import Translation

/// On-device translation: whether the user's languages are covered, what translates into what,
/// and where to download more. The full catalog is slow to build, so only the pages below load it
/// (from `TranslationCatalogStore`); this one checks just the user's languages.
struct TranslationSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var yourLanguages: [(name: String, status: LanguageAvailability.Status)]?

    var body: some View {
        Form {
            Section {
                if let yourLanguages {
                    if yourLanguages.isEmpty {
                        Text("Apple's on-device model speaks all your languages; nothing to download.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(yourLanguages, id: \.name) { language in
                        LabeledContent(language.name, value: Self.describe(language.status))
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            } header: {
                Text("Your languages")
            } footer: {
                Text("Chats in a language the on-device model doesn't speak are translated on this iPhone "
                    + "once the language is downloaded. Otherwise they go to your cloud model.")
            }

            Section {
                NavigationLink("Available translations") { TranslationDirectionsView() }
                NavigationLink("Download languages") { TranslationDownloadsView() }
            } footer: {
                Text("Translation languages are shared with the Translate app. You can also download or remove them in "
                    + "Settings › Apps › Translate › Downloaded Languages. Artemis also uses them when you ask it to translate something.")
            }
        }
        .navigationTitle("Translation")
        .navigationBarTitleDisplayMode(.inline)
        // Languages may have been downloaded in the Translate settings meanwhile.
        .task(id: scenePhase) {
            switch scenePhase {
            case .active: yourLanguages = await OnDeviceTranslator.preferredLanguages()
            case .background: await TranslationCatalogStore.shared.invalidate()
            default: break
            }
        }
    }

    private static func describe(_ status: LanguageAvailability.Status) -> String {
        switch status {
        case .installed: "Translated on device"
        case .supported: "Not downloaded"
        case .unsupported: "Not available"
        @unknown default: "Not available"
        }
    }
}

// MARK: - Directions

/// Every downloaded language and the languages it translates into, then what can be downloaded.
private struct TranslationDirectionsView: View {
    @State private var catalog: OnDeviceTranslator.Catalog?

    var body: some View {
        List {
            Section {
                if catalog == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else if directions.isEmpty {
                    Text("No languages downloaded yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(directions, id: \.source) { direction in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(direction.source)
                        Text("Into \(direction.targets)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Downloaded")
            } footer: {
                Text("Each language translates into the other downloaded ones, on this iPhone and offline.")
            }

            if !available.isEmpty {
                Section {
                    ForEach(available, id: \.self) { name in
                        Text(name)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Available to download")
                } footer: {
                    Text("Download them in Settings › On-device model › Translation › Download languages, "
                        + "or in Settings › Apps › Translate › Downloaded Languages.")
                }
            }
        }
        .navigationTitle("Available translations")
        .navigationBarTitleDisplayMode(.inline)
        .task { catalog = await TranslationCatalogStore.shared.catalog() }
    }

    private var directions: [(source: String, targets: String)] {
        (catalog?.directions ?? []).map { direction in
            (direction.source.languageName, direction.targets.map(\.languageName).sorted(using: .localizedStandard).formatted(.list(type: .and)))
        }
        .sorted(using: KeyPathComparator(\.source, comparator: .localizedStandard))
    }

    private var available: [String] {
        (catalog?.languages ?? []).filter { !$0.isInstalled }.map(\.name).sorted(using: .localizedStandard)
    }
}

// MARK: - Downloads

/// Downloads languages for on-device translation. Only a SwiftUI translation task can ask the
/// system to download; the chat's own sessions use what's installed.
private struct TranslationDownloadsView: View {
    @State private var catalog: OnDeviceTranslator.Catalog?
    @State private var download: TranslationSession.Configuration?
    @State private var downloading: Locale.Language?

    var body: some View {
        List {
            Section {
                if catalog == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
                ForEach(entries) { entry in
                    LabeledContent(entry.name) {
                        if entry.isInstalled {
                            Text("Downloaded")
                                .foregroundStyle(.secondary)
                        } else if downloading == entry.language {
                            ProgressView()
                        } else {
                            Button("Download") { startDownload(entry.language) }
                                .disabled(downloading != nil)
                        }
                    }
                }
            } footer: {
                Text("Apple's on-device model doesn't speak these languages. When you write in a downloaded one, "
                    + "Artemis translates the conversation on this iPhone instead of sending it to the cloud.")
            }
        }
        .navigationTitle("Download languages")
        .navigationBarTitleDisplayMode(.inline)
        .translationTask(download) { session in
            // The system shows its own download sheet; cancelling it ends up here as an error.
            try? await session.prepareTranslation()
            downloading = nil
            download = nil
            catalog = await TranslationCatalogStore.shared.catalog(refresh: true)
        }
        .task { catalog = await TranslationCatalogStore.shared.catalog() }
    }

    /// Languages the on-device model doesn't speak, the user's own first.
    private var entries: [OnDeviceTranslator.Catalog.Entry] {
        let preferred = Set(Locale.preferredLocales.map(\.language.languageIdentifier))
        return (catalog?.languages ?? [])
            .filter { !$0.isSpokenByModel && $0.language.languageCode != OnDeviceTranslator.english.languageCode }
            .sorted { lhs, rhs in
                let lhsPreferred = preferred.contains(lhs.id)
                if lhsPreferred != preferred.contains(rhs.id) { return lhsPreferred }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    private func startDownload(_ language: Locale.Language) {
        downloading = language
        download = TranslationSession.Configuration(source: language, target: OnDeviceTranslator.english)
    }
}
