import SwiftUI

public struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var providers: [Provider] = []
    @State private var presets: [Preset] = []
    @State private var settings: AppSettings = AppSettings()

    @State private var showingAddProvider: Bool = false
    @State private var providerToEdit: Provider?
    @State private var saveError: String?
    @State private var onDeviceStatus = OnDeviceModelStatus.current

    private let database = AppDatabase.shared

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                // Providers Section
                Section {
                    ForEach(providers) { provider in
                        Button {
                            providerToEdit = provider
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(provider.name)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text(provider.baseUrl)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if provider.id == effectiveDefaultId {
                                    Text("Default")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.15))
                                        .foregroundStyle(Color.accentColor)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            if provider.id != effectiveDefaultId {
                                Button {
                                    makeDefault(provider)
                                } label: {
                                    Label("Default", systemImage: "star.fill")
                                }
                                .tint(.accentColor)
                            }
                        }
                        .contextMenu {
                            Button {
                                makeDefault(provider)
                            } label: {
                                Label("Make Default", systemImage: "star")
                            }
                            .disabled(provider.id == effectiveDefaultId)
                            Button {
                                providerToEdit = provider
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                        }
                    }
                    .onDelete(perform: deleteProvider)

                    Button {
                        showingAddProvider = true
                    } label: {
                        Label("Add Provider", systemImage: "plus")
                    }
                } header: {
                    Text("Providers")
                } footer: {
                    if !providers.isEmpty {
                        Text("Swipe right on a provider to make it the default. New chats use it with its default model; chats keep the model they were started with.")
                    }
                }

                // General Preferences
                Section {
                    LabeledContent("Status") {
                        Text(onDeviceStatus.title)
                            .foregroundStyle(onDeviceStatus.isAvailable ? .green : .secondary)
                    }
                    if onDeviceStatus.isAvailable {
                        NavigationLink("Supported languages") {
                            List(OnDeviceModel.supportedLanguageNames, id: \.self) { Text($0) }
                                .navigationTitle("Languages")
                        }
                    }
                    Toggle("Use on-device model", isOn: settingBinding(\.onDeviceEnabled))
                        .disabled(!onDeviceStatus.isAvailable)
                    Toggle("Generate chat titles on-device", isOn: settingBinding(\.onDeviceTitles))
                        .disabled(!onDeviceStatus.isAvailable || !settings.onDeviceEnabled)
                    NavigationLink {
                        toolsSettings
                    } label: {
                        LabeledContent("Device data & actions") {
                            Text(toolsSummary)
                        }
                    }
                    .disabled(!onDeviceStatus.isAvailable || !settings.onDeviceEnabled)
                } header: {
                    Text("On-device model")
                } footer: {
                    Text(onDeviceStatus.detail)
                }

                Section {
                    Picker("Default mode", selection: settingBinding(\.routingMode)) {
                        Text("Auto").tag(RoutingMode.auto)
                        Text("On-device").tag(RoutingMode.onDevice)
                        Text("Cloud").tag(RoutingMode.cloud)
                    }
                    Picker("Cloud in Auto mode", selection: settingBinding(\.cloudPolicy)) {
                        Text("Always ask").tag(CloudPolicy.alwaysAsk)
                        Text("Always allow").tag(CloudPolicy.alwaysAllow)
                        Text("Never").tag(CloudPolicy.deny)
                    }
                } header: {
                    Text("Routing")
                } footer: {
                    Text(cloudPolicyDescription)
                }

                Section(header: Text("General")) {
                    Toggle("Debug Mode (Headers)", isOn: Binding(
                        get: { settings.debugMode },
                        set: {
                            settings.debugMode = $0
                            try? database.saveSettings(settings)
                        }
                    ))
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingAddProvider) {
                ProviderEditView(provider: nil, apiKey: "") { newProvider, apiKey in
                    saveProvider(newProvider, apiKey: apiKey)
                    if providers.isEmpty {
                        settings.defaultProviderId = newProvider.id
                        try? database.saveSettings(settings)
                    }
                    loadData()
                }
            }
            .sheet(item: $providerToEdit) { provider in
                ProviderEditView(provider: provider, apiKey: database.apiKey(providerId: provider.id)) { updated, apiKey in
                    saveProvider(updated, apiKey: apiKey)
                    loadData()
                }
            }
            .onAppear {
                loadData()
            }
            .alert(
                "Couldn't save provider",
                isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    private var cloudPolicyDescription: String {
        let base: String
        switch settings.cloudPolicy {
        case .alwaysAsk:
            base = "Auto mode asks before sending a message to your cloud provider."
        case .alwaysAllow:
            base = "Auto mode sends messages to your cloud provider whenever the on-device model isn't enough."
        case .deny:
            base = "Auto mode never sends messages to the cloud; the on-device model always answers."
        }
        return base + " Choosing Cloud mode or tapping Ask cloud always uses the cloud."
    }

    @State private var artemisAlarms: [AlarmScheduler.Scheduled] = []

    private var toolsSummary: String {
        let count = settings.enabledToolGroups.count
        return count == 0 ? "Off" : count == ToolGroup.allCases.count ? "All" : "\(count) of \(ToolGroup.allCases.count)"
    }

    private var toolsSettings: some View {
        Form {
            Section {
                Toggle("Use device data & actions", isOn: settingBinding(\.personalDataTools))
            } footer: {
                Text("The on-device model can read this data to answer you and draft actions such as events, alarms or messages. Nothing is saved or sent until you confirm it, and the data never leaves this device.")
            }
            Section("Sources") {
                ForEach(ToolGroup.allCases) { group in
                    Toggle(isOn: toolGroupBinding(group)) {
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
            .disabled(!settings.personalDataTools)

            Section {
                if artemisAlarms.isEmpty {
                    Text("None")
                        .foregroundStyle(.secondary)
                }
                ForEach(artemisAlarms) { alarm in
                    LabeledContent {
                        Text(alarm.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                    } label: {
                        Label(alarm.title, systemImage: alarm.isTimer ? "timer" : "alarm")
                    }
                }
                .onDelete { offsets in
                    for index in offsets { AlarmScheduler.cancel(artemisAlarms[index].id) }
                    artemisAlarms = AlarmScheduler.scheduled()
                }
            } header: {
                Text("Alarms set by Artemis")
            } footer: {
                Text("They ring like Clock alarms, even in Silent mode, but iOS doesn't list them in the Clock app. Swipe to delete one.")
            }
        }
        .onAppear { artemisAlarms = AlarmScheduler.scheduled() }
        .navigationTitle("Device data & actions")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toolGroupBinding(_ group: ToolGroup) -> Binding<Bool> {
        Binding(
            get: { !settings.disabledToolGroups.contains(group) },
            set: { isOn in
                if isOn {
                    settings.disabledToolGroups.remove(group)
                } else {
                    settings.disabledToolGroups.insert(group)
                }
                try? database.saveSettings(settings)
            }
        )
    }

    private func settingBinding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: {
                settings[keyPath: keyPath] = $0
                try? database.saveSettings(settings)
            }
        )
    }

    private func loadData() {
        onDeviceStatus = .current
        providers = (try? database.fetchProviders()) ?? []
        presets = (try? database.fetchPresets()) ?? []
        settings = (try? database.fetchSettings()) ?? AppSettings()
    }

    private func saveProvider(_ provider: Provider, apiKey: String) {
        do {
            try database.saveProvider(provider, apiKey: apiKey)
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Chats fall back to the first provider when none was chosen (or it was deleted).
    private var effectiveDefaultId: String? {
        providers.first { $0.id == settings.defaultProviderId }?.id ?? providers.first?.id
    }

    private func makeDefault(_ provider: Provider) {
        settings.defaultProviderId = provider.id
        do {
            try database.saveSettings(settings)
            UISelectionFeedbackGenerator().selectionChanged()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func deleteProvider(at offsets: IndexSet) {
        for index in offsets {
            let provider = providers[index]
            try? database.deleteProvider(id: provider.id)
            if settings.defaultProviderId == provider.id {
                settings.defaultProviderId = providers.first(where: { $0.id != provider.id })?.id
                try? database.saveSettings(settings)
            }
        }
        loadData()
    }
}

// MARK: - Provider Edit Sheet
struct ProviderEditView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var kind: ProviderKind
    @State private var name: String
    @State private var baseUrl: String
    @State private var onlyFreeModels: Bool
    @State private var apiKey: String
    @State private var models: [String]
    @State private var modelCapabilities: [String: [String]]
    @State private var defaultModel: String
    @State private var isTesting: Bool = false
    @State private var testError: String?
    @State private var testSuccess: Bool = false
    @State private var newModel: String = ""

    let existingId: String?
    let existingCreatedAt: Date?
    let onSave: (Provider, String) -> Void

    init(provider: Provider?, apiKey: String, onSave: @escaping (Provider, String) -> Void) {
        self.existingId = provider?.id
        self.existingCreatedAt = provider?.createdAt
        let kind = provider?.kind ?? .openRouter
        self._kind = State(initialValue: kind)
        self._name = State(initialValue: provider?.name ?? kind.displayName)
        self._baseUrl = State(initialValue: provider?.baseUrl ?? kind.defaultBaseURL)
        self._onlyFreeModels = State(initialValue: provider?.onlyFreeModels ?? false)
        self._apiKey = State(initialValue: apiKey)
        self._models = State(initialValue: provider?.models ?? [])
        self._modelCapabilities = State(initialValue: provider?.modelCapabilities ?? [:])
        self._defaultModel = State(initialValue: provider?.defaultModel ?? "")
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Provider", selection: $kind) {
                        ForEach(selectableKinds, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .onChange(of: kind) { previous, current in
                        selectKind(current, replacing: previous)
                    }
                    TextField("Name", text: $name)
                    TextField(kind == .custom ? "Base URL (…/v1)" : "Base URL", text: $baseUrl)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("API Key", text: $apiKey)
                    if kind == .openRouter {
                        Toggle("Only free models", isOn: $onlyFreeModels)
                            .onChange(of: onlyFreeModels) { _, isOn in
                                applyFreeFilter(isOn)
                            }
                    }
                } header: {
                    Text("Provider Info")
                } footer: {
                    if kind == .openRouter {
                        Text("Only free models keeps models whose ID ends in “:free”. They're rate-limited and may log prompts.")
                    } else if kind == .custom {
                        Text("Any OpenAI-compatible endpoint with /chat/completions.")
                    }
                }

                Section {
                    Button {
                        testAndFetchModels()
                    } label: {
                        HStack {
                            Text(isTesting ? "Testing…" : "Test & Fetch Models")
                            if isTesting {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isTesting || baseUrl.isEmpty)

                    if let error = testError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if testSuccess {
                        Text("Connected successfully! Found \(models.count) models.")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                Section {
                    if !models.isEmpty {
                        Picker("Default Model", selection: $defaultModel) {
                            ForEach(models, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                    }
                    ForEach(models, id: \.self) { model in
                        HStack {
                            Text(model)
                                .font(.callout)
                            Spacer()
                            if modelCapabilities[model]?.contains(Provider.toolsCapability) == true {
                                Image(systemName: "globe")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Web search")
                            }
                        }
                    }
                    .onDelete { offsets in
                        for model in offsets.map({ models[$0] }) {
                            modelCapabilities.removeValue(forKey: model)
                        }
                        models.remove(atOffsets: offsets)
                        if !models.contains(defaultModel) {
                            defaultModel = models.first ?? ""
                        }
                    }
                    HStack {
                        TextField("Add model ID", text: $newModel)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit(addModel)
                        Button("Add", action: addModel)
                            .disabled(newModel.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Models")
                } footer: {
                    Text(models.isEmpty
                         ? "Add at least one model: tap Test & Fetch Models, or enter model IDs by hand if the provider can't list them."
                         : "🌐 marks models that can search the web. Swipe to remove models you don't use.")
                }
            }
            .navigationTitle(existingId == nil ? "Add Provider" : "Edit Provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let provider = Provider(
                            id: existingId ?? UUID().uuidString.lowercased(),
                            name: name.isEmpty ? kind.displayName : name,
                            kind: kind,
                            baseUrl: baseUrl,
                            models: models,
                            defaultModel: defaultModel.isEmpty ? (models.first ?? "") : defaultModel,
                            modelCapabilities: modelCapabilities.filter { models.contains($0.key) },
                            onlyFreeModels: kind == .openRouter && onlyFreeModels,
                            createdAt: existingCreatedAt ?? Date()
                        )
                        onSave(provider, apiKey)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    /// The kinds to offer; an existing provider of another kind (e.g. Groq) keeps its own.
    private var selectableKinds: [ProviderKind] {
        ProviderKind.selectable.contains(kind) ? ProviderKind.selectable : ProviderKind.selectable + [kind]
    }

    /// Fills in the new kind's name and endpoint unless the user changed them.
    private func selectKind(_ current: ProviderKind, replacing previous: ProviderKind) {
        if name.isEmpty || name == previous.displayName {
            name = current.displayName
        }
        if baseUrl.isEmpty || baseUrl == previous.defaultBaseURL {
            baseUrl = current.defaultBaseURL
        }
        // Models of another service don't carry over.
        if current != previous {
            models = []
            modelCapabilities = [:]
            defaultModel = ""
            testSuccess = false
            testError = nil
        }
    }

    /// Switching on narrows the list right away; switching off needs the full list again.
    private func applyFreeFilter(_ isOn: Bool) {
        if isOn {
            models = models.filter(Self.isFree)
            modelCapabilities = modelCapabilities.filter { Self.isFree($0.key) }
            if !models.contains(defaultModel) { defaultModel = models.first ?? "" }
        } else if !apiKey.isEmpty || testSuccess {
            testAndFetchModels()
        }
    }

    private static func isFree(_ model: String) -> Bool {
        model.hasSuffix(ProviderKind.freeModelSuffix)
    }

    /// A provider is only usable with at least one model to pick.
    private var canSave: Bool {
        !name.isEmpty && !baseUrl.isEmpty && !models.isEmpty
    }

    private func addModel() {
        let model = newModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return }
        if !models.contains(model) {
            models.append(model)
        }
        if defaultModel.isEmpty {
            defaultModel = model
        }
        newModel = ""
    }

    private func testAndFetchModels() {
        isTesting = true
        testError = nil
        testSuccess = false

        let client = LLMClient(baseUrl: baseUrl, apiKey: apiKey)
        Task {
            do {
                var fetched = try await client.fetchModels()
                if kind == .openRouter && onlyFreeModels {
                    fetched = fetched.filter { Self.isFree($0.id) }
                }
                await MainActor.run {
                    let ids = fetched.map(\.id)
                    self.models = ids
                    self.modelCapabilities = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0.capabilities) })
                    if let first = ids.first, defaultModel.isEmpty || !ids.contains(defaultModel) {
                        self.defaultModel = first
                    }
                    self.testSuccess = true
                    self.isTesting = false
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            } catch {
                await MainActor.run {
                    self.testError = error.localizedDescription
                    self.isTesting = false
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                }
            }
        }
    }
}
