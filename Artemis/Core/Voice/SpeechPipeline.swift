@preconcurrency import AVFoundation
import Foundation
import Speech

/// The spoken language shared by voice mode and dictation.
enum VoicePreferences {
    /// `UserDefaults` key of the locale identifier; read by `@AppStorage` in the settings.
    static let localeKey = "voiceLocale"

    static var locale: Locale {
        get { UserDefaults.standard.string(forKey: localeKey).map(Locale.init(identifier:)) ?? Locale.current }
        set { UserDefaults.standard.set(newValue.identifier, forKey: localeKey) }
    }

    /// The user turned the microphone off for the app; only the Settings app can turn it back on.
    static var isMicrophoneDenied: Bool {
        AVAudioApplication.shared.recordPermission == .denied
    }

    static let microphoneDeniedMessage = "Artemis needs the microphone. You can allow it in Settings."
}

/// Starts on-device speech recognition from the microphone: reserves the language, downloads
/// its model if needed, and feeds `VoiceAudio` into a `SpeechAnalyzer`.
@MainActor
enum SpeechPipeline {
    enum SetupError: LocalizedError {
        case unavailable

        var errorDescription: String? {
            "Speech recognition isn't available on this device."
        }
    }

    /// - Parameters:
    ///   - conversation: voice mode (echo cancellation and playback) rather than dictation.
    ///   - onDownload: called before the language's model is downloaded, which can take a while.
    ///   - shouldContinue: checked once the model is ready; `false` (the user gave up) cancels.
    /// - Returns: the running analyzer; read results from `module`.
    static func start(
        _ module: some LocaleDependentSpeechModule,
        locale: Locale,
        audio: VoiceAudio,
        conversation: Bool,
        onDownload: () -> Void = {},
        shouldContinue: () -> Bool = { true }
    ) async throws -> SpeechAnalyzer {
        try await reserve(locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            onDownload()
            VoiceLog.log("downloading speech model for \(locale.identifier)")
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()
        guard shouldContinue() else { throw CancellationError() }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw SetupError.unavailable
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        try await analyzer.prepareToAnalyze(in: format)
        let input = try audio.start(analyzerFormat: format, conversation: conversation)
        try await analyzer.start(inputSequence: input)
        return analyzer
    }

    /// Recognition needs its locale reserved; the system allows only a few at a time, so the
    /// oldest other reservation makes room.
    private static func reserve(_ locale: Locale) async throws {
        let reserved = await AssetInventory.reservedLocales
        if reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) { return }
        if reserved.count >= AssetInventory.maximumReservedLocales, let oldest = reserved.first {
            await AssetInventory.release(reservedLocale: oldest)
            VoiceLog.log("released speech locale \(oldest.identifier)")
        }
        try await AssetInventory.reserve(locale: locale)
        VoiceLog.log("reserved speech locale \(locale.identifier)")
    }
}
