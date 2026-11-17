import SwiftUI

public struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var providers: [Provider] = []
    @State private var presets: [Preset] = []
    @State private var settings: AppSettings = AppSettings()

    @State private var showingAddProvider: Bool = false
    @State private var providerToEdit: Provider?

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
                ProviderEditView(provider: nil) { newProvider in
                    try? database.saveProvider(newProvider)
                    if providers.isEmpty {
                        settings.defaultProviderId = newProvider.id
                        try? database.saveSettings(settings)
                    }
                    loadData()
                }
            }
            .sheet(item: $providerToEdit) { provider in
                ProviderEditView(provider: provider) { updated in
                    try? database.saveProvider(updated)
                    loadData()
                }
            }
            .onAppear {
                loadData()
            }
        }
    }

    private func loadData() {
        providers = (try? database.fetchProviders()) ?? []
        presets = (try? database.fetchPresets()) ?? []
        settings = (try? database.fetchSettings()) ?? AppSettings()
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
    @State private var defaultModel: String
    @State private var isTesting: Bool = false
    @State private var testError: String?
    @State private var testSuccess: Bool = false

    let existingId: String?
    let onSave: (Provider) -> Void

    init(provider: Provider?, onSave: @escaping (Provider) -> Void) {
        self.existingId = provider?.id
        self._name = State(initialValue: provider?.name ?? "")
        self._baseUrl = State(initialValue: provider?.baseUrl ?? "https://api.openai.com/v1")
        self._apiKey = State(initialValue: provider?.apiKey ?? "")
        self._models = State(initialValue: provider?.models ?? [])
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

                if !models.isEmpty {
                    Section("Models") {
                        Picker("Default Model", selection: $defaultModel) {
                            ForEach(models, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                    }
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
                            apiKey: apiKey,
                            models: models,
                            defaultModel: defaultModel.isEmpty ? (models.first ?? "") : defaultModel
                        )
                        onSave(provider)
                        dismiss()
                    }
                    .disabled(name.isEmpty || baseUrl.isEmpty)
                }
            }
        }
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
                    self.models = fetched
                    if !fetched.isEmpty && (defaultModel.isEmpty || !fetched.contains(defaultModel)) {
                        self.defaultModel = fetched.first!
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
