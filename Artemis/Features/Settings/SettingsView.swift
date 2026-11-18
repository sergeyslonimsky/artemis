import SwiftUI

/// Settings root: one row per area, each opening its own page.
public struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model = SettingsModel()
    @State private var onDeviceStatus = OnDeviceModelStatus.current
    @State private var voiceLanguage = ""

    public init() {}

    public var body: some View {
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
                        row("Routing", icon: "arrow.triangle.branch", color: .orange, value: routingSummary)
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
                        row("Voice & dictation", icon: "waveform", color: .pink, value: voiceLanguage)
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
            .onAppear {
                model.load()
                onDeviceStatus = .current
                voiceLanguage = VoiceSettingsView.currentLanguageName
            }
            .alert(
                "Couldn't save",
                isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
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
                    .background(color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
    }

    private var onDeviceSummary: String {
        guard onDeviceStatus.isAvailable else { return "Unavailable" }
        return model.settings.onDeviceEnabled ? "On" : "Off"
    }

    private var routingSummary: String {
        switch model.settings.routingMode {
        case .auto: "Auto"
        case .onDevice: "On-device"
        case .cloud: "Cloud"
        }
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
