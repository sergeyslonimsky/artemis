import SwiftUI

/// Mode and cloud model for a chat: search across providers, favorites and recent models first.
struct ModelPickerSheet: View {
    let providers: [Provider]
    let mode: RoutingMode
    let modeDescription: String
    let selection: ModelRef?
    let favorites: [ModelRef]
    let recents: [ModelRef]
    let onModeChange: (RoutingMode) -> Void
    let onSelect: (Provider, String) -> Void
    let onToggleFavorite: (ModelRef) -> Void
    let onDone: () -> Void

    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    Section {
                        Picker("Mode", selection: Binding(get: { mode }, set: onModeChange)) {
                            Text("Auto").tag(RoutingMode.auto)
                            Text("On-device").tag(RoutingMode.onDevice)
                            Text("Cloud").tag(RoutingMode.cloud)
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.clear)
                    } footer: {
                        Text(modeDescription)
                    }
                }

                if providers.isEmpty {
                    Section("Cloud model") {
                        Text("Add a provider in Settings to use cloud models.")
                            .foregroundStyle(.secondary)
                    }
                } else if query.isEmpty {
                    shortcutSection("Favorites", refs: favorites)
                    shortcutSection("Recent", refs: recents.filter { !favorites.contains($0) })
                    ForEach(providers) { provider in
                        Section(provider.name) {
                            ForEach(provider.models, id: \.self) { model in
                                row(provider: provider, model: model)
                            }
                        }
                    }
                } else {
                    let results = searchResults
                    if results.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                    ForEach(results, id: \.provider.id) { result in
                        Section(result.provider.name) {
                            ForEach(result.models, id: \.self) { model in
                                row(provider: result.provider, model: model)
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search models")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func shortcutSection(_ title: String, refs: [ModelRef]) -> some View {
        let rows = refs.compactMap { ref -> (Provider, String)? in
            guard let provider = providers.first(where: { $0.id == ref.providerId }),
                  provider.models.contains(ref.model) else { return nil }
            return (provider, ref.model)
        }
        if !rows.isEmpty {
            Section(title) {
                ForEach(rows, id: \.1) { provider, model in
                    row(provider: provider, model: model, showsProvider: providers.count > 1)
                }
            }
        }
    }

    /// Every word of the query must appear in the model ID (or the provider's name).
    private var searchResults: [(provider: Provider, models: [String])] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return providers.compactMap { provider in
            let models = provider.models.filter { model in
                let haystack = (model + " " + provider.name).lowercased()
                return terms.allSatisfy(haystack.contains)
            }
            return models.isEmpty ? nil : (provider, models)
        }
    }

    // MARK: - Row

    private func row(provider: Provider, model: String, showsProvider: Bool = false) -> some View {
        let ref = ModelRef(providerId: provider.id, model: model)
        let isFavorite = favorites.contains(ref)
        let isSelected = selection == ref
        let name = ModelName(model)

        return Button {
            onSelect(provider, model)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name.title)
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    let subtitle = [showsProvider ? provider.name : nil, name.vendor].compactMap { $0 }.joined(separator: " · ")
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                badges(provider: provider, model: model, isFree: name.isFree)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                onToggleFavorite(ref)
            } label: {
                Label(isFavorite ? "Unfavorite" : "Favorite", systemImage: isFavorite ? "star.slash" : "star")
            }
            .tint(.yellow)
        }
        .contextMenu {
            Button {
                onToggleFavorite(ref)
            } label: {
                Label(isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: isFavorite ? "star.slash" : "star")
            }
            Button {
                UIPasteboard.general.string = model
            } label: {
                Label("Copy Model ID", systemImage: "doc.on.doc")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func badges(provider: Provider, model: String, isFree: Bool) -> some View {
        HStack(spacing: 6) {
            if favorites.contains(ModelRef(providerId: provider.id, model: model)) {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("Favorite")
            }
            if provider.supportsWebSearch(model: model) {
                Image(systemName: "globe")
                    .foregroundStyle(Color.secondary)
                    .accessibilityLabel("Web search")
            }
            if provider.modelCapabilities[model]?.contains(Provider.imageInputCapability) == true {
                Image(systemName: "photo")
                    .foregroundStyle(Color.secondary)
                    .accessibilityLabel("Reads images")
            }
            if isFree {
                Text("free")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.green.opacity(0.15), in: Capsule())
                    .foregroundStyle(.green)
            }
        }
        .font(.caption)
    }
}

/// "anthropic/claude-sonnet-4.5:free" → title "claude-sonnet-4.5", vendor "anthropic", free.
private struct ModelName {
    let title: String
    let vendor: String?
    let isFree: Bool

    init(_ id: String) {
        var rest = id
        isFree = rest.hasSuffix(ProviderKind.freeModelSuffix)
        if isFree { rest.removeLast(ProviderKind.freeModelSuffix.count) }
        if let slash = rest.lastIndex(of: "/") {
            vendor = String(rest[..<slash])
            title = String(rest[rest.index(after: slash)...])
        } else {
            vendor = nil
            title = rest
        }
    }
}
