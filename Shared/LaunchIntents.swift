import AppIntents

// Compiled into the app and the controls extension: a control's intent has to exist in both.
// The intents only carry their parameters: the app's scene receives them through
// `onAppIntentExecution`, which also brings it to the foreground.

struct AskArtemisIntent: TargetContentProvidingIntent {
    static let title: LocalizedStringResource = "Ask Artemis"
    static let description = IntentDescription("Starts a new chat with your question.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Question", inputOptions: String.IntentInputOptions(multiline: true), requestValueDialog: "What would you like to ask?")
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Artemis \(\.$question)")
    }
}

struct NewChatIntent: TargetContentProvidingIntent {
    static let title: LocalizedStringResource = "New Chat"
    static let description = IntentDescription("Opens Artemis on a new chat, ready to type.")
    static let supportedModes: IntentModes = .foreground(.immediate)
}

struct VoiceModeIntent: TargetContentProvidingIntent {
    static let title: LocalizedStringResource = "Talk to Artemis"
    static let description = IntentDescription("Starts a new chat in voice mode.")
    static let supportedModes: IntentModes = .foreground(.immediate)
}
