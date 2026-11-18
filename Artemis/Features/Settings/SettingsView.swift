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
                Section(header: Text("Providers")) {
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
                                if provider.id == settings.defaultProviderId {
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
                    }
                    .onDelete(perform: deleteProvider)

                    Button {
                        showingAddProvider = true
                    } label: {
                        Label("Add Provider", systemImage: "plus")
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

    @State private var name: String
    @State private var baseUrl: String
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
        self._name = State(initialValue: provider?.name ?? "")
        self._baseUrl = State(initialValue: provider?.baseUrl ?? "https://api.openai.com/v1")
        self._apiKey = State(initialValue: apiKey)
        self._models = State(initialValue: provider?.models ?? [])
        self._modelCapabilities = State(initialValue: provider?.modelCapabilities ?? [:])
        self._defaultModel = State(initialValue: provider?.defaultModel ?? "")
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Provider Info") {
                    TextField("Name (e.g. OpenAI, OpenRouter)", text: $name)
                    TextField("Base URL", text: $baseUrl)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                    SecureField("API Key", text: $apiKey)
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
                            name: name.isEmpty ? "Provider" : name,
                            baseUrl: baseUrl,
                            models: models,
                            defaultModel: defaultModel.isEmpty ? (models.first ?? "") : defaultModel,
                            modelCapabilities: modelCapabilities.filter { models.contains($0.key) },
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
                let fetched = try await client.fetchModels()
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
