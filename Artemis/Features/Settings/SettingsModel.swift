import GRDB
import SwiftUI
import os

/// Settings, providers and presets shared by the settings pages. Mirrors the database while
/// `observe()` runs; every change is saved at once.
@MainActor
@Observable
final class SettingsModel {
    private(set) var settings = AppSettings()
    private(set) var providers: [Provider] = []
    private(set) var presets: [Preset] = []
    var errorMessage: String?

    @ObservationIgnored private let database: AppDatabase
    private static let logger = Logger(subsystem: "com.artemis.ios", category: "Settings")

    init(database: AppDatabase = .shared) {
        self.database = database
        // The first frame shows real values instead of defaults; observation keeps them current.
        settings = (try? database.fetchSettings()) ?? AppSettings()
        providers = (try? database.fetchProviders()) ?? []
        presets = (try? database.fetchPresets()) ?? []
    }

    // MARK: - Observation

    func observeSettings() async {
        await observe(database.observeSettings(), "settings") { settings = $0 }
    }

    func observeProviders() async {
        await observe(database.observeProviders(), "providers") { providers = $0 }
    }

    func observePresets() async {
        await observe(database.observePresets(), "presets") { presets = $0 }
    }

    private func observe<Value>(_ values: AsyncValueObservation<Value>, _ name: String, _ apply: (Value) -> Void) async {
        await values.keepDelivering(onError: { error in
            Self.logger.error("Observing \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Couldn't load \(name): \(error.localizedDescription)"
        }, apply)
    }

    // MARK: - Settings

    /// Applies `change` and saves it; on failure the shown value stays as it was.
    func update(_ change: (inout AppSettings) -> Void) {
        var updated = settings
        change(&updated)
        guard updated != settings else { return }
        perform {
            try database.saveSettings(updated)
            settings = updated
        }
    }

    func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { value in self.update { $0[keyPath: keyPath] = value } }
        )
    }

    /// On when `member` is in the set at `keyPath`; `inverted` for sets of switched-off items.
    func binding<Member: Hashable>(
        _ member: Member,
        in keyPath: WritableKeyPath<AppSettings, Set<Member>>,
        inverted: Bool = false
    ) -> Binding<Bool> {
        Binding(
            get: { self.settings[keyPath: keyPath].contains(member) != inverted },
            set: { isOn in
                self.update { settings in
                    if isOn != inverted {
                        settings[keyPath: keyPath].insert(member)
                    } else {
                        settings[keyPath: keyPath].remove(member)
                    }
                }
            }
        )
    }

    // MARK: - Providers

    /// Chats fall back to the first provider when none was chosen (or it was deleted).
    var defaultProvider: Provider? {
        providers.first { $0.id == settings.defaultProviderId } ?? providers.first
    }

    func saveProvider(_ provider: Provider, apiKey: String) {
        let isFirst = providers.isEmpty
        perform {
            var provider = provider
            provider.updatedAt = Date()
            try database.saveProvider(provider, apiKey: apiKey)
            if isFirst { update { $0.defaultProviderId = provider.id } }
        }
    }

    func deleteProvider(_ provider: Provider) {
        perform {
            try database.deleteProvider(id: provider.id)
            if settings.defaultProviderId == provider.id {
                update { $0.defaultProviderId = providers.first { $0.id != provider.id }?.id }
            }
        }
    }

    func makeDefault(_ provider: Provider) {
        update { $0.defaultProviderId = provider.id }
    }

    func apiKey(for provider: Provider) -> String {
        database.apiKey(providerId: provider.id)
    }

    // MARK: - Presets

    var defaultPreset: Preset? {
        presets.first { $0.id == settings.defaultPresetId }
    }

    func savePreset(_ preset: Preset) {
        var preset = preset
        preset.updatedAt = Date()
        perform { try database.savePreset(preset) }
    }

    func deletePreset(_ preset: Preset) {
        perform { try database.deletePreset(id: preset.id) }
        if settings.defaultPresetId == preset.id {
            update { $0.defaultPresetId = nil }
        }
    }

    func setDefaultPreset(_ preset: Preset?) {
        update { $0.defaultPresetId = preset?.id }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
