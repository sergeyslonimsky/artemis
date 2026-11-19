import SwiftUI

/// Settings root: one row per area, each opening its own page.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model = SettingsModel()
    @State private var onDeviceStatus = OnDeviceModelStatus.current
    @AppStorage(VoicePreferences.localeKey) private var voiceLocale = Locale.current.identifier

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        OnDeviceSettingsView(model: model)
                    } label: {
                        row("On-device model", icon: "lock.iphone", color: .green, value: onDeviceSummary)
                    }
                    NavigationLink {
                        ProvidersSettingsView(model: model)
                    } label: {
                        row("Cloud providers", icon: "cloud", color: .blue, value: model.defaultProvider?.name ?? "None")
                    }
                    NavigationLink {
                        RoutingSettingsView(model: model)
                    } label: {
                        row("Routing", icon: "arrow.triangle.branch", color: .orange, value: model.settings.routingMode.title)
                    }
                } header: {
                    Text("Models")
                }

                Section {
                    NavigationLink {
                        InstructionsSettingsView(model: model)
                    } label: {
                        row("Instructions", icon: "text.quote", color: .purple,
                            value: model.settings.systemPrompt.isEmpty ? "None" : "On")
                    }
                    NavigationLink {
                        PresetsSettingsView(model: model)
                    } label: {
                        row("Presets", icon: "slider.horizontal.3", color: .indigo,
                            value: model.defaultPreset?.title ?? (model.presets.isEmpty ? "None" : "\(model.presets.count)"))
                    }
                } header: {
                    Text("Assistant")
                }

                Section {
                    NavigationLink {
                        DeviceDataSettingsView(model: model)
                    } label: {
                        row("Device data & actions", icon: "hand.raised", color: .teal, value: toolsSummary)
                    }
                    .disabled(!onDeviceStatus.isAvailable || !model.settings.onDeviceEnabled)
                    NavigationLink {
                        VoiceSettingsView()
                    } label: {
                        row("Voice & dictation", icon: "waveform", color: .pink, value: Locale(identifier: voiceLocale).displayName)
                    }
                } header: {
                    Text("Device")
                } footer: {
                    Text(versionText)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { onDeviceStatus = .current }
            .errorAlert("Something went wrong", message: $model.errorMessage)
        }
        .task { await model.observeSettings() }
        .task { await model.observeProviders() }
        .task { await model.observePresets() }
    }

    private func row(_ title: String, icon: String, color: Color, value: String) -> some View {
        LabeledContent {
            Text(value)
                .lineLimit(1)
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: icon)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(color.gradient, in: .rect(cornerRadius: 7, style: .continuous))
            }
        }
    }

    private var onDeviceSummary: String {
        guard onDeviceStatus.isAvailable else { return "Unavailable" }
        return model.settings.onDeviceEnabled ? "On" : "Off"
    }

    private var toolsSummary: String {
        let count = model.settings.enabledToolGroups.count
        return count == 0 ? "Off" : count == ToolGroup.allCases.count ? "All" : "\(count) of \(ToolGroup.allCases.count)"
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Artemis \(version) (\(build))"
    }
}
