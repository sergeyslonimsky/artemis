import AppIntents
import SwiftUI
import WidgetKit

@main
struct ArtemisControls: WidgetBundle {
    var body: some Widget {
        NewChatControl()
        VoiceModeControl()
    }
}

/// Control Center, the Lock Screen and the Action button: opens a new chat, ready to type.
struct NewChatControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "NewChat") {
            ControlWidgetButton(action: NewChatIntent()) {
                Label("Ask Artemis", systemImage: "bubble.left.and.text.bubble.right")
            }
        }
        .displayName("Ask Artemis")
        .description("Opens a new chat, ready to type.")
    }
}

/// Starts a new chat in voice mode.
struct VoiceModeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "VoiceMode") {
            ControlWidgetButton(action: VoiceModeIntent()) {
                Label("Talk to Artemis", systemImage: "waveform")
            }
        }
        .displayName("Talk to Artemis")
        .description("Starts a new chat in voice mode.")
    }
}
