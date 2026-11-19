import AppIntents

/// Siri, Spotlight and the Action button offer these without any setup.
struct ArtemisShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskArtemisIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Ask \(.applicationName) a question",
            ],
            shortTitle: "Ask",
            systemImageName: "bubble.left.and.text.bubble.right"
        )
        AppShortcut(
            intent: VoiceModeIntent(),
            phrases: [
                "Talk to \(.applicationName)",
                "Start a voice chat in \(.applicationName)",
            ],
            shortTitle: "Voice Mode",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: NewChatIntent(),
            phrases: [
                "New chat in \(.applicationName)",
                "Start a new \(.applicationName) chat",
            ],
            shortTitle: "New Chat",
            systemImageName: "square.and.pencil"
        )
    }
}
