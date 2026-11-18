import SwiftUI

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
