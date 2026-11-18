import AVFoundation
import Speech
import SwiftUI

// MARK: - On-device model

struct OnDeviceSettingsView: View {
    let model: SettingsModel
    @State private var status = OnDeviceModelStatus.current

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    Text(status.title)
                        .foregroundStyle(status.isAvailable ? .green : .secondary)
                }
                if status.isAvailable {
                    NavigationLink("Supported languages") {
                        List(OnDeviceModel.supportedLanguageNames, id: \.self) { Text($0) }
                            .navigationTitle("Languages")
                    }
                }
            } footer: {
                Text(status.detail)
            }

            Section {
                Toggle("Use on-device model", isOn: model.binding(\.onDeviceEnabled))
                    .disabled(!status.isAvailable)
                Toggle("Generate chat titles on-device", isOn: model.binding(\.onDeviceTitles))
                    .disabled(!status.isAvailable || !model.settings.onDeviceEnabled)
            } footer: {
                Text("Apple's model runs on this iPhone: it's private, free and works offline, but it's small. "
                    + "In Auto mode harder requests go to your cloud provider.")
            }
        }
        .navigationTitle("On-device model")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { status = .current }
    }
}

// MARK: - Cloud providers

struct ProvidersSettingsView: View {
    let model: SettingsModel
    @State private var showingAdd = false
    @State private var editing: Provider?

    var body: some View {
        Form {
            Section {
                ForEach(model.providers) { provider in
                    Button {
                        editing = provider
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.name)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(Color.primary)
                                Text("\(provider.kind.displayName) · \(provider.models.count) models")
                                    .font(.caption)
                                    .foregroundStyle(Color.secondary)
                            }
                            Spacer()
                            if provider.id == model.defaultProvider?.id {
                                TagBadge("Default")
                            }
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        if provider.id != model.defaultProvider?.id {
                            Button("Default", systemImage: "star.fill") { model.makeDefault(provider) }
                                .tint(.accentColor)
                        }
                    }
                }
                .onDelete { offsets in
                    offsets.map { model.providers[$0] }.forEach(model.deleteProvider)
                }

                Button("Add Provider", systemImage: "plus") { showingAdd = true }
            } footer: {
                Text(model.providers.isEmpty
                     ? "Add OpenRouter, OpenAI, Mistral or any OpenAI-compatible endpoint with your own API key. Keys are stored in the Keychain."
                     : "Swipe right on a provider to make it the default. New chats use it with its default model; chats keep the model they were started with.")
            }
        }
        .navigationTitle("Cloud providers")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: model.settings.defaultProviderId)
        .sheet(isPresented: $showingAdd) {
            ProviderEditView(provider: nil, apiKey: "") { provider, apiKey in
                model.saveProvider(provider, apiKey: apiKey)
            }
        }
        .sheet(item: $editing) { provider in
            ProviderEditView(provider: provider, apiKey: model.apiKey(for: provider)) { updated, apiKey in
                model.saveProvider(updated, apiKey: apiKey)
            }
        }
    }
}

// MARK: - Routing

struct RoutingSettingsView: View {
    let model: SettingsModel

    var body: some View {
        Form {
            Section {
                Picker("Default mode", selection: model.binding(\.routingMode)) {
                    ForEach(RoutingMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } footer: {
                Text(modeDescription)
            }

            Section {
                Picker("Cloud in Auto mode", selection: model.binding(\.cloudPolicy)) {
                    ForEach(CloudPolicy.pickerOrder, id: \.self) { Text($0.title).tag($0) }
                }
            } footer: {
                Text(policyDescription)
            }
        }
        .navigationTitle("Routing")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var modeDescription: String {
        switch model.settings.routingMode {
        case .auto: "New chats answer on-device and use the cloud only when the on-device model isn't enough."
        case .onDevice: "New chats stay on this device."
        case .cloud: "New chats send every message to the cloud model."
        }
    }

    private var policyDescription: String {
        let base = switch model.settings.cloudPolicy {
        case .alwaysAsk: "Auto mode asks once per chat before sending messages to your cloud provider."
        case .alwaysAllow: "Auto mode sends messages to your cloud provider whenever the on-device model isn't enough."
        case .deny: "Auto mode never sends messages to the cloud; the on-device model always answers."
        }
        return base + " Choosing Cloud mode or tapping Ask cloud always uses the cloud."
    }
}

// MARK: - Instructions

struct InstructionsSettingsView: View {
    let model: SettingsModel
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        Form {
            Section {
                TextField("For example: answer briefly; I'm a software engineer.", text: $text, axis: .vertical)
                    .lineLimit(6...20)
                    .focused($isFocused)
            } footer: {
                Text("Added to every chat, on-device and in the cloud. A preset's own instructions replace these.")
            }
        }
        .navigationTitle("Instructions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .keyboard) {
                HStack {
                    Spacer()
                    Button("Done") { isFocused = false }
                }
            }
        }
        .onAppear { text = model.settings.systemPrompt }
        .onDisappear { save() }
        .onChange(of: isFocused) { _, focused in
            if !focused { save() }
        }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != model.settings.systemPrompt else { return }
        model.update { $0.systemPrompt = trimmed }
    }
}

// MARK: - Presets

struct PresetsSettingsView: View {
    let model: SettingsModel
    @State private var editing: Preset?
    @State private var showingAdd = false

    var body: some View {
        Form {
            Section {
                ForEach(model.presets) { preset in
                    Button {
                        editing = preset
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.title)
                                    .foregroundStyle(Color.primary)
                                if !preset.systemPrompt.isEmpty {
                                    Text(preset.systemPrompt)
                                        .font(.caption)
                                        .foregroundStyle(Color.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            if preset.id == model.defaultPreset?.id {
                                TagBadge("Default")
                            }
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        let isDefault = preset.id == model.defaultPreset?.id
                        Button(isDefault ? "No Default" : "Default", systemImage: isDefault ? "star.slash" : "star.fill") {
                            model.setDefaultPreset(isDefault ? nil : preset)
                        }
                        .tint(.accentColor)
                    }
                }
                .onDelete { offsets in
                    offsets.map { model.presets[$0] }.forEach(model.deletePreset)
                }

                Button("New Preset", systemImage: "plus") { showingAdd = true }
            } footer: {
                Text("A preset is a reusable set of instructions and settings, like “Translator” or “Code reviewer”. "
                    + "Swipe right to make one the default for new chats; switch presets per chat from the model menu.")
            }
        }
        .navigationTitle("Presets")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: model.settings.defaultPresetId)
        .sheet(isPresented: $showingAdd) {
            PresetEditView(preset: nil, onSave: model.savePreset)
        }
        .sheet(item: $editing) { preset in
            PresetEditView(preset: preset, onSave: model.savePreset)
        }
    }
}

struct PresetEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var preset: Preset
    @State private var customTemperature: Bool
    private let isNew: Bool
    let onSave: (Preset) -> Void

    init(preset: Preset?, onSave: @escaping (Preset) -> Void) {
        self.isNew = preset == nil
        self._preset = State(initialValue: preset ?? Preset(title: ""))
        self._customTemperature = State(initialValue: preset?.temperature != nil)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $preset.title)
                }
                Section {
                    TextField("How should the assistant behave?", text: $preset.systemPrompt, axis: .vertical)
                        .lineLimit(5...16)
                } header: {
                    Text("Instructions")
                } footer: {
                    Text("Replace your general instructions while this preset is selected.")
                }
                Section {
                    Toggle("Custom temperature", isOn: $customTemperature.animation())
                    if customTemperature {
                        LabeledContent("Temperature") {
                            Text((preset.temperature ?? 0.7).formatted(.number.precision(.fractionLength(1))))
                                .monospacedDigit()
                        }
                        Slider(
                            value: Binding(get: { preset.temperature ?? 0.7 }, set: { preset.temperature = $0 }),
                            in: 0...2,
                            step: 0.1
                        )
                    }
                } footer: {
                    Text("Lower is more focused and predictable, higher is more varied.")
                }
            }
            .navigationTitle(isNew ? "New Preset" : "Edit Preset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var saved = preset
                        saved.title = saved.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        saved.systemPrompt = saved.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                        saved.temperature = customTemperature ? (saved.temperature ?? 0.7) : nil
                        onSave(saved)
                        dismiss()
                    }
                    .disabled(preset.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - Device data & actions

struct DeviceDataSettingsView: View {
    let model: SettingsModel
    @State private var alarms: [AlarmScheduler.Scheduled] = []

    var body: some View {
        Form {
            Section {
                Toggle("Use device data & actions", isOn: model.binding(\.personalDataTools))
            } footer: {
                Text("The on-device model can read this data to answer you and draft actions such as events, alarms or messages. "
                    + "Nothing is saved or sent until you confirm it, and the data never leaves this device.")
            }
            Section("Sources") {
                ForEach(ToolGroup.allCases) { group in
                    Toggle(isOn: model.binding(group, in: \.disabledToolGroups, inverted: true)) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.title)
                                Text(group.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: group.systemImage)
                        }
                    }
                }
            }
            .disabled(!model.settings.personalDataTools)

            Section {
                if alarms.isEmpty {
                    Text("None")
                        .foregroundStyle(.secondary)
                }
                ForEach(alarms) { alarm in
                    LabeledContent {
                        Text(alarm.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                    } label: {
                        Label(alarm.title, systemImage: alarm.isTimer ? "timer" : "alarm")
                    }
                }
                .onDelete { offsets in
                    for index in offsets { AlarmScheduler.cancel(alarms[index].id) }
                    alarms = AlarmScheduler.scheduled()
                }
            } header: {
                Text("Alarms set by Artemis")
            } footer: {
                Text("They ring like Clock alarms, even in Silent mode, but iOS doesn't list them in the Clock app. Swipe to delete one.")
            }
        }
        .onAppear { alarms = AlarmScheduler.scheduled() }
        .navigationTitle("Device data & actions")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Voice & dictation

struct VoiceSettingsView: View {
    @AppStorage(VoicePreferences.localeKey) private var selected = Locale.current.identifier

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    SpokenLanguageView(selected: $selected)
                } label: {
                    LabeledContent("Spoken language", value: Locale(identifier: selected).displayName)
                }
            } footer: {
                Text("Used to recognize your speech in voice mode and dictation, on this device. A language is downloaded the first time you use it.")
            }

            Section {
                LabeledContent(spokenLanguageName, value: replyVoice.map(VoiceLabel.title) ?? "None installed")
                NavigationLink("Installed voices") { InstalledVoicesView() }
            } header: {
                Text("Voices")
            } footer: {
                Text("Replies are read with the best voice installed for their language. For natural speech, download an Enhanced or Premium voice in Settings › Accessibility › Read & Speak › Voices.")
            }
        }
        .navigationTitle("Voice & dictation")
        .navigationBarTitleDisplayMode(.inline)
        // Voices may have been downloaded in Settings while the app was in the background.
        .onAppear { refreshVoice() }
        .onChange(of: selected) { refreshVoice() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            refreshVoice()
        }
    }

    @State private var replyVoice: AVSpeechSynthesisVoice?

    private var spokenLanguageCode: String {
        Locale(identifier: selected).language.languageCode?.identifier ?? "en"
    }

    private var spokenLanguageName: String {
        Locale.current.localizedString(forLanguageCode: spokenLanguageCode) ?? spokenLanguageCode
    }

    private func refreshVoice() {
        replyVoice = SpeechOutput.bestVoice(for: spokenLanguageCode)
    }
}

private enum VoiceLabel {
    /// "Ava (Premium)"; default-quality voices are shown by name only, as in Settings.
    static func title(_ voice: AVSpeechSynthesisVoice) -> String {
        quality(voice).map { "\(voice.name) (\($0))" } ?? voice.name
    }

    static func quality(_ voice: AVSpeechSynthesisVoice) -> String? {
        switch voice.quality {
        case .premium: "Premium"
        case .enhanced: "Enhanced"
        default: nil
        }
    }
}

/// Every installed voice, grouped by language; the one replies use is checked.
private struct InstalledVoicesView: View {
    private struct LanguageGroup: Identifiable {
        let code: String
        let name: String
        let voices: [AVSpeechSynthesisVoice]
        let used: AVSpeechSynthesisVoice?
        var id: String { code }
    }

    @State private var groups: [LanguageGroup] = []

    var body: some View {
        List(groups) { group in
            Section(group.name) {
                ForEach(group.voices, id: \.identifier) { voice in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(voice.name)
                            Text(subtitle(for: voice))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if voice.identifier == group.used?.identifier {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        }
        .navigationTitle("Installed voices")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { load() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            load()
        }
    }

    private func subtitle(for voice: AVSpeechSynthesisVoice) -> String {
        let region = Locale.Language(identifier: voice.language).displayName ?? voice.language
        return [region, VoiceLabel.quality(voice)].compactMap(\.self).joined(separator: " · ")
    }

    private func load() {
        let byLanguage = Dictionary(grouping: SpeechOutput.installedVoices()) { voice in
            Locale.Language(identifier: voice.language).languageCode?.identifier ?? voice.language
        }
        groups = byLanguage.map { code, voices in
            LanguageGroup(
                code: code,
                name: Locale.current.localizedString(forLanguageCode: code) ?? code,
                voices: voices.sorted {
                    if $0.quality != $1.quality { return $0.quality.rawValue > $1.quality.rawValue }
                    return $0.name < $1.name
                },
                used: SpeechOutput.bestVoice(for: code)
            )
        }
        .sorted { $0.name < $1.name }
    }
}

private struct SpokenLanguageView: View {
    @Binding var selected: String
    @Environment(\.dismiss) private var dismiss
    @State private var suggested: [Locale] = []
    @State private var others: [Locale] = []

    var body: some View {
        List {
            Section("Suggested") {
                languageRows(suggested)
            }
            if !others.isEmpty {
                Section("Other languages") {
                    languageRows(others)
                }
            }
        }
        .navigationTitle("Spoken language")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            suggested = await VoiceSession.suggestedLocales(current: Locale(identifier: selected))
            let all = await SpeechTranscriber.supportedLocales
            others = all
                .filter { locale in !suggested.contains { $0.identifier == locale.identifier } }
                .sorted { $0.displayName < $1.displayName }
        }
    }

    private func languageRows(_ locales: [Locale]) -> some View {
        ForEach(locales, id: \.identifier) { locale in
            Button {
                selected = locale.identifier
                dismiss()
            } label: {
                HStack {
                    Text(locale.displayName)
                        .foregroundStyle(Color.primary)
                    Spacer()
                    if locale.identifier == selected {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
    }
}
