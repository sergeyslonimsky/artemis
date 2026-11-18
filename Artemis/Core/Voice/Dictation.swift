@preconcurrency import AVFoundation
import Foundation
import Speech

/// Speech-to-text into the message field: on-device `DictationTranscriber` (punctuation and
/// all), in the same language as voice mode. The text appears as it is recognized; nothing is
/// sent until the user taps Send.
@MainActor
@Observable
final class Dictation {
    enum State: Equatable {
        case idle
        case preparing
        case listening
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Microphone loudness, 0…1, for the button's animation.
    private(set) var level: Float = 0

    var isActive: Bool {
        state == .preparing || state == .listening
    }

    @ObservationIgnored private let audio = VoiceAudio()
    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var finalized = ""
    @ObservationIgnored private var volatile = ""
    /// Receives the text recognized so far in this dictation.
    @ObservationIgnored private var onText: ((String) -> Void)?

    func start(onText: @escaping (String) -> Void) async {
        guard !isActive else { return }
        self.onText = onText
        finalized = ""
        volatile = ""
        state = .preparing
        guard await AVAudioApplication.requestRecordPermission() else {
            state = .failed(VoicePreferences.microphoneDeniedMessage)
            return
        }

        let preferred = VoicePreferences.locale
        do {
            guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: preferred) else {
                state = .failed("Dictation doesn't support \(preferred.displayName).")
                return
            }
            let transcriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
            analyzer = try await SpeechPipeline.start(
                transcriber, locale: locale, audio: audio, conversation: false,
                shouldContinue: { state == .preparing } // stopped while downloading
            )

            tasks.append(Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        self?.handle(String(result.text.characters), isFinal: result.isFinal)
                    }
                } catch {
                    VoiceLog.log("dictation failed: \(error)")
                }
            })
            tasks.append(Task { [weak self] in
                while !Task.isCancelled {
                    if let self { self.level = self.audio.inputLevel }
                    try? await Task.sleep(for: .milliseconds(80))
                }
            })
            state = .listening
            VoiceLog.log("dictation started: \(locale.identifier)")
        } catch is CancellationError {
            await teardown()
        } catch {
            VoiceLog.log("dictation start failed: \(error)")
            state = .failed(error.localizedDescription)
            await teardown()
        }
    }

    /// Stops listening; text still being recognized is finalized first so the tail isn't lost.
    func stop() async {
        guard isActive else { return }
        state = .idle
        audio.stop()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        // The results task ends once the analyzer has delivered the final text.
        if let results = tasks.first {
            _ = try? await RequestClassifier.withTimeout(.seconds(2)) { await results.value }
        }
        await teardown()
        if !volatile.isEmpty {
            finalized = join(finalized, volatile)
            volatile = ""
            onText?(finalized)
        }
        onText = nil
    }

    private func teardown() async {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        audio.stop()
        await analyzer?.cancelAndFinishNow()
        analyzer = nil
        level = 0
    }

    private func handle(_ text: String, isFinal: Bool) {
        if isFinal {
            finalized = join(finalized, text)
            volatile = ""
        } else {
            volatile = text
        }
        onText?(join(finalized, volatile))
    }

    private func join(_ lhs: String, _ rhs: String) -> String {
        let rhs = rhs.trimmingCharacters(in: .whitespaces)
        guard !lhs.isEmpty else { return rhs }
        guard !rhs.isEmpty else { return lhs }
        return lhs + " " + rhs
    }
}
