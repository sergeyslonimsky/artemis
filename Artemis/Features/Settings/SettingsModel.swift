import SwiftUI

/// Settings, providers and presets shared by the settings pages. Every change is saved at once.
@MainActor
@Observable
final class SettingsModel {
    private(set) var settings = AppSettings()
    private(set) var providers: [Provider] = []
    private(set) var presets: [Preset] = []
    var errorMessage: String?

    @ObservationIgnored private let database = AppDatabase.shared

    func load() {
        settings = (try? database.fetchSettings()) ?? AppSettings()
        providers = (try? database.fetchProviders()) ?? []
        presets = (try? database.fetchPresets()) ?? []
    }

    func update(_ change: (inout AppSettings) -> Void) {
        var updated = settings
        change(&updated)
        perform { try database.saveSettings(updated) }
        settings = updated
    }

    func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { value in self.update { $0[keyPath: keyPath] = value } }
        )
    }

    // MARK: - Providers

    /// Chats fall back to the first provider when none was chosen (or it was deleted).
    var defaultProvider: Provider? {
        providers.first { $0.id == settings.defaultProviderId } ?? providers.first
    }

    func saveProvider(_ provider: Provider, apiKey: String) {
        let isFirst = providers.isEmpty
        perform { try database.saveProvider(provider, apiKey: apiKey) }
        if isFirst { update { $0.defaultProviderId = provider.id } }
        load()
    }

    func deleteProvider(_ provider: Provider) {
        perform { try database.deleteProvider(id: provider.id) }
        if settings.defaultProviderId == provider.id {
            update { $0.defaultProviderId = providers.first { $0.id != provider.id }?.id }
        }
        load()
    }

    func makeDefault(_ provider: Provider) {
        update { $0.defaultProviderId = provider.id }
        UISelectionFeedbackGenerator().selectionChanged()
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
        load()
    }

    func deletePreset(_ preset: Preset) {
        perform { try database.deletePreset(id: preset.id) }
        if settings.defaultPresetId == preset.id {
            update { $0.defaultPresetId = nil }
        }
        load()
    }

    func setDefaultPreset(_ preset: Preset?) {
        update { $0.defaultPresetId = preset?.id }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
