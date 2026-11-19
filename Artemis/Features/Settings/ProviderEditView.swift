import SwiftUI

/// Adds or edits a cloud provider: endpoint, API key and the models to offer.
struct ProviderEditView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Provider
    @State private var apiKey: String
    @State private var newModel = ""
    @State private var test = TestState.idle
    /// Changing it starts a connection test; `.task(id:)` cancels it when the sheet closes.
    @State private var testRequest: UUID?

    private let isNew: Bool
    /// Names used by the other providers, as `Provider.nameKey`.
    private let takenNames: Set<String>
    let onSave: (Provider, String) -> Void

    private enum TestState: Equatable {
        case idle
        case testing
        case succeeded
        case failed(String)
    }

    init(provider: Provider?, apiKey: String, others: [Provider], onSave: @escaping (Provider, String) -> Void) {
        let kind = provider?.kind ?? .openRouter
        isNew = provider == nil
        takenNames = Set(others.map { Provider.nameKey($0.name) })
        _draft = State(initialValue: provider ?? Provider(name: kind.displayName, kind: kind, baseUrl: kind.defaultBaseURL))
        _apiKey = State(initialValue: apiKey)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                providerSection
                testSection
                modelsSection
            }
            .navigationTitle(isNew ? "Add Provider" : "Edit Provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!canSave)
                }
            }
            .task(id: testRequest) {
                guard testRequest != nil else { return }
                await testAndFetchModels()
            }
            .sensoryFeedback(trigger: test) { _, new in
                switch new {
                case .succeeded: .success
                case .failed: .error
                default: nil
                }
            }
        }
    }

    // MARK: - Sections

    private var providerSection: some View {
        Section {
            Picker("Provider", selection: $draft.kind) {
                ForEach(selectableKinds, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .onChange(of: draft.kind) { previous, current in
                selectKind(current, replacing: previous)
            }
            TextField("Name", text: $draft.name)
            TextField(draft.kind == .custom ? "Base URL (…/v1)" : "Base URL", text: $draft.baseUrl)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            SecureField("API Key", text: $apiKey)
            if draft.kind == .openRouter {
                Toggle("Only free models", isOn: $draft.onlyFreeModels)
                    .onChange(of: draft.onlyFreeModels) { _, isOn in
                        applyFreeFilter(isOn)
                    }
            }
        } header: {
            Text("Provider Info")
        } footer: {
            if isNameTaken {
                Text("A provider named “\(resolvedName)” already exists. Choose another name.")
                    .foregroundStyle(.red)
            } else {
                kindFooter
            }
        }
    }

    @ViewBuilder
    private var kindFooter: some View {
        switch draft.kind {
        case .openRouter:
            Text("Only free models keeps models whose ID ends in “:free”. They're rate-limited and may log prompts.")
        case .custom:
            Text("Any OpenAI-compatible endpoint with /chat/completions.")
        default:
            EmptyView()
        }
    }

    private var testSection: some View {
        Section {
            Button {
                testRequest = UUID()
            } label: {
                LabeledContent(test == .testing ? "Testing…" : "Test & Fetch Models") {
                    if test == .testing { ProgressView() }
                }
            }
            .disabled(test == .testing || draft.baseUrl.isEmpty)

            switch test {
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            case .succeeded:
                Text("Connected successfully! Found \(draft.models.count) models.")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .idle, .testing:
                EmptyView()
            }
        }
    }

    private var modelsSection: some View {
        Section {
            if !draft.models.isEmpty {
                Picker("Default Model", selection: $draft.defaultModel) {
                    ForEach(draft.models, id: \.self) { Text($0).tag($0) }
                }
            }
            ForEach(draft.models, id: \.self) { model in
                LabeledContent {
                    if draft.supportsWebSearch(model: model) {
                        Image(systemName: "globe")
                            .font(.caption)
                            .accessibilityLabel("Web search")
                    }
                } label: {
                    Text(model).font(.callout)
                }
            }
            .onDelete { offsets in
                let removed = offsets.map { draft.models[$0] }
                draft.models.remove(atOffsets: offsets)
                removed.forEach { draft.modelCapabilities.removeValue(forKey: $0) }
                keepDefaultModelValid()
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
            if draft.models.isEmpty {
                Text("Add at least one model: tap Test & Fetch Models, or enter model IDs by hand if the provider can't list them.")
            } else {
                Text("\(Image(systemName: "globe")) marks models that can search the web. Swipe to remove models you don't use.")
            }
        }
    }

    // MARK: - Editing

    /// The kinds to offer; an existing provider of another kind (e.g. Groq) keeps its own.
    private var selectableKinds: [ProviderKind] {
        ProviderKind.selectable.contains(draft.kind) ? ProviderKind.selectable : ProviderKind.selectable + [draft.kind]
    }

    /// Fills in the new kind's name and endpoint unless the user changed them.
    private func selectKind(_ current: ProviderKind, replacing previous: ProviderKind) {
        guard current != previous else { return }
        if draft.name.isEmpty || draft.name == previous.displayName {
            draft.name = current.displayName
        }
        if draft.baseUrl.isEmpty || draft.baseUrl == previous.defaultBaseURL {
            draft.baseUrl = current.defaultBaseURL
        }
        // Models of another service don't carry over.
        draft.models = []
        draft.modelCapabilities = [:]
        draft.defaultModel = ""
        test = .idle
    }

    /// Switching on narrows the list right away; switching off needs the full list again.
    private func applyFreeFilter(_ isOn: Bool) {
        if isOn {
            draft.models = draft.models.filter(Self.isFree)
            draft.modelCapabilities = draft.modelCapabilities.filter { Self.isFree($0.key) }
            keepDefaultModelValid()
        } else if !apiKey.isEmpty || test == .succeeded {
            testRequest = UUID()
        }
    }

    private static func isFree(_ model: String) -> Bool {
        model.hasSuffix(ProviderKind.freeModelSuffix)
    }

    private func keepDefaultModelValid() {
        if !draft.models.contains(draft.defaultModel) {
            draft.defaultModel = draft.models.first ?? ""
        }
    }

    private func addModel() {
        let model = newModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return }
        if !draft.models.contains(model) {
            draft.models.append(model)
        }
        if draft.defaultModel.isEmpty {
            draft.defaultModel = model
        }
        newModel = ""
    }

    /// The name the provider is saved under: the kind's name when left blank.
    private var resolvedName: String {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? draft.kind.displayName : name
    }

    private var isNameTaken: Bool {
        takenNames.contains(Provider.nameKey(resolvedName))
    }

    /// A provider is only usable with at least one model to pick, and its name tells it apart.
    private var canSave: Bool {
        !draft.baseUrl.isEmpty && !draft.models.isEmpty && !isNameTaken
    }

    private func save() {
        var provider = draft
        provider.name = resolvedName
        if provider.defaultModel.isEmpty {
            provider.defaultModel = provider.models.first ?? ""
        }
        provider.modelCapabilities = provider.modelCapabilities.filter { provider.models.contains($0.key) }
        provider.onlyFreeModels = provider.kind == .openRouter && provider.onlyFreeModels
        onSave(provider, apiKey)
        dismiss()
    }

    private func testAndFetchModels() async {
        test = .testing
        do {
            var fetched = try await LLMClient(baseUrl: draft.baseUrl, apiKey: apiKey).fetchModels()
            if draft.kind == .openRouter && draft.onlyFreeModels {
                fetched = fetched.filter { Self.isFree($0.id) }
            }
            draft.models = fetched.map(\.id)
            draft.modelCapabilities = Dictionary(fetched.map { ($0.id, $0.capabilities) }, uniquingKeysWith: { first, _ in first })
            keepDefaultModelValid()
            test = .succeeded
        } catch {
            if Task.isCancelled {
                test = .idle
                return
            }
            test = .failed(error.localizedDescription)
        }
    }
}
