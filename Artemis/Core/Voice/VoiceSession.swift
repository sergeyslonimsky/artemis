@preconcurrency import AVFoundation
import Foundation
import Speech
import UIKit
import os

/// A spoken conversation in a chat: listen until the user pauses, send the words as a message,
/// read the reply aloud as it streams, and stop talking as soon as the user speaks again.
/// Every turn is stored in the chat like a typed one.
struct PendingDraft: Equatable {
    let messageId: String
    let draft: ActionDraft
}

@MainActor
@Observable
final class VoiceSession: Identifiable {
    enum State: Equatable {
        case preparing(String)
        case listening
        case thinking
        case speaking
        /// The turn needs the cloud and the user has to allow it.
        case needsConsent
        case failed(String)
    }

    private(set) var state: State = .preparing("Starting…")
    /// What the user is saying right now.
    private(set) var transcript = ""
    /// The part of the reply read aloud so far.
    private(set) var spokenReply = ""
    /// Loudness of the user (listening) or of the reply (speaking), 0…1.
    private(set) var level: Float = 0
    private(set) var locale: Locale
    private(set) var consent: Message?
    /// The reply's action waiting for a "yes" (or a tap).
    private(set) var pendingDraft: PendingDraft?
    var isMuted = false {
        didSet { audio.isMuted = isMuted }
    }

    let chatId: String
    /// Sends the user's words as a message (creating the chat if needed).
    private let send: (String) throws -> Void
    /// Answers a consent prompt.
    private let answerConsent: (Message, Bool) -> Void

    @ObservationIgnored private let audio = VoiceAudio()
    @ObservationIgnored private lazy var speech = SpeechOutput(audio: audio)
    @ObservationIgnored private let chatService = ChatService.shared
    @ObservationIgnored private let database = AppDatabase.shared
    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    // Utterance tracking
    @ObservationIgnored private var finalized = ""
    @ObservationIgnored private var volatile = ""
    @ObservationIgnored private var lastHeardAt = Date.distantPast
    @ObservationIgnored private var lastLoudAt = Date.distantPast
    /// Recognizer time where the current utterance starts; earlier results belong to a sent one.
    /// Measured on the recognizer's own timeline (the end of the latest result), never on the
    /// microphone's: the two drift apart, and a cutoff ahead of the recognizer drops every result.
    @ObservationIgnored private var cutoff: Double = 0
    @ObservationIgnored private var latestResultEnd: Double = 0
    @ObservationIgnored private var resultCount = 0
    @ObservationIgnored private var lastResultAt = Date()
    @ObservationIgnored private var lastDiagnosticsAt = Date()
    @ObservationIgnored private var recoveries = 0
    @ObservationIgnored private var transcriber: SpeechTranscriber?

    // Reply tracking
    @ObservationIgnored private var runToken: UUID?
    @ObservationIgnored private var replyMessageId: String?
    @ObservationIgnored private var spokenCount = 0

    private static let postPlaybackGate: TimeInterval = 0.7
    /// Silence after speech that ends the user's turn.
    private static let endOfTurnSilence: TimeInterval = 1.2
    /// Above this the microphone hears speech, not room noise.
    private static let speechLevel: Float = 0.45
    private static let localeKey = "voiceLocale"
    private static let logger = Logger(subsystem: "com.artemis.ios", category: "VoiceSession")
    /// The previous session's teardown; a new session waits for it, so two sessions never hold
    /// the microphone and the recognizer at once.
    private static var teardown: Task<Void, Never>?

    init(chatId: String, send: @escaping (String) throws -> Void, answerConsent: @escaping (Message, Bool) -> Void) {
        self.chatId = chatId
        self.send = send
        self.answerConsent = answerConsent
        let saved = UserDefaults.standard.string(forKey: Self.localeKey)
        self.locale = saved.map(Locale.init(identifier:)) ?? Locale.current
    }

    // MARK: - Lifecycle

    func start() async {
        chatService.setVoiceMode(true, chatId: chatId)
        UIApplication.shared.isIdleTimerDisabled = true
        await Self.teardown?.value
        guard await AVAudioApplication.requestRecordPermission() else {
            state = .failed("Artemis needs the microphone. You can allow it in Settings › Apps › Artemis.")
            return
        }
        await startRecognition()
    }

    private func startRecognition() async {
        do {
            guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                state = .failed("Speech recognition doesn't support \(Self.name(of: locale)). Choose another language.")
                return
            }
            try await reserve(supported)
            let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                state = .preparing("Downloading speech model…")
                VoiceLog.log("downloading speech model for \(supported.identifier)")
                try await request.downloadAndInstall()
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                state = .failed("Speech recognition isn't available on this device.")
                return
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            try await analyzer.prepareToAnalyze(in: format)
            let input = try audio.start(analyzerFormat: format)
            try await analyzer.start(inputSequence: input)
            self.analyzer = analyzer
            self.transcriber = transcriber
            audio.isMuted = isMuted
            cutoff = 0
            latestResultEnd = 0
            lastResultAt = Date()
            VoiceLog.log("recognition started: \(supported.identifier)")

            tasks.append(Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        self?.handle(result)
                    }
                    VoiceLog.log("recognition results ended")
                } catch {
                    VoiceLog.log("recognition failed: \(error)")
                    if !Task.isCancelled {
                        self?.state = .failed("Speech recognition stopped: \(error.localizedDescription)")
                    }
                }
            })
            tasks.append(Task { [weak self] in
                while !Task.isCancelled {
                    self?.tick()
                    try? await Task.sleep(for: .milliseconds(100))
                }
            })
            state = .listening
        } catch {
            VoiceLog.log("start failed: \(error)")
            state = .failed(error.localizedDescription)
        }
    }

    /// Recognition needs its locale reserved; the system allows only a few at a time, so the
    /// oldest other reservation makes room.
    private func reserve(_ locale: Locale) async throws {
        let reserved = await AssetInventory.reservedLocales
        if reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) { return }
        if reserved.count >= AssetInventory.maximumReservedLocales, let oldest = reserved.first {
            await AssetInventory.release(reservedLocale: oldest)
            VoiceLog.log("released speech locale \(oldest.identifier)")
        }
        try await AssetInventory.reserve(locale: locale)
        VoiceLog.log("reserved speech locale \(locale.identifier)")
    }

    /// Ends the session. A reply still being generated keeps going in the chat, silently.
    func stop() async {
        let previous = Self.teardown
        let work = Task { @MainActor in
            await previous?.value
            await self.stopRecognition()
            self.chatService.setVoiceMode(false, chatId: self.chatId)
            UIApplication.shared.isIdleTimerDisabled = false
        }
        Self.teardown = work
        await work.value
    }

    private func stopRecognition() async {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        speech.stop()
        audio.stop()
        await analyzer?.cancelAndFinishNow()
        analyzer = nil
        transcriber = nil
        VoiceLog.log("recognition stopped after \(resultCount) results")
    }

    func setLocale(_ newLocale: Locale) async {
        guard newLocale.identifier != locale.identifier else { return }
        UserDefaults.standard.set(newLocale.identifier, forKey: Self.localeKey)
        locale = newLocale
        await stopRecognition()
        resetUtterance()
        state = .preparing("Starting…")
        await startRecognition()
    }

    /// Tapping while the assistant talks skips the rest of the reply.
    func interrupt() {
        guard state == .speaking || state == .thinking else { return }
        stopReply()
        // Whatever was heard during the reply was echo or noise.
        resetUtterance()
    }

    /// The user talks over the reply: stop it and keep listening to what they're saying.
    private func stopReply() {
        VoiceLog.log("reply interrupted")
        speech.stop()
        chatService.cancel(chatId: chatId)
        runToken = nil
        state = .listening
    }

    func resolveConsent(allow: Bool) {
        guard let consent else { return }
        self.consent = nil
        speech.stop()
        answerConsent(consent, allow)
        runToken = chatService.runs[chatId]?.token
        state = .thinking
    }

    // MARK: - Listening

    private func handle(_ result: SpeechTranscriber.Result) {
        resultCount += 1
        lastResultAt = Date()
        let start = result.range.start.seconds
        let end = (result.range.start + result.range.duration).seconds
        if end.isFinite { latestResultEnd = max(latestResultEnd, end) }
        guard !start.isFinite || start + 0.05 >= cutoff else { return }
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isFinal {
            if !text.isEmpty { finalized += (finalized.isEmpty ? "" : " ") + text }
            volatile = ""
        } else {
            volatile = text
        }
        transcript = [finalized, volatile].filter { !$0.isEmpty }.joined(separator: " ")
        lastHeardAt = Date()

        if state == .speaking || state == .thinking, isBargeIn(transcript) {
            stopReply()
        }
    }

    /// Echo cancellation leaves a residue, so the reply's own words can come back through the
    /// microphone. Only clearly new speech cuts in: three or more words, mostly not in the reply.
    private func isBargeIn(_ heard: String) -> Bool {
        let words = Self.words(in: heard)
        guard words.count >= 3 else { return false }
        let replyWords = Set(Self.words(in: spokenReply))
        let new = words.filter { !replyWords.contains($0) }
        return Double(new.count) / Double(words.count) >= 0.7
    }

    private static func words(in text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private func tick() {
        let now = Date()
        let input = audio.inputLevel
        if input > Self.speechLevel { lastLoudAt = now }
        level = state == .speaking ? audio.outputLevel : input
        logDiagnostics(now: now, input: input)

        switch state {
        case .listening:
            if !transcript.isEmpty,
               now.timeIntervalSince(lastHeardAt) > Self.endOfTurnSilence,
               now.timeIntervalSince(lastLoudAt) > Self.endOfTurnSilence * 0.7 {
                commit()
            }
        case .thinking, .speaking:
            followRun()
        case .preparing, .needsConsent, .failed:
            break
        }
    }

    private func logDiagnostics(now: Date, input: Float) {
        guard now.timeIntervalSince(lastDiagnosticsAt) >= 5 else { return }
        lastDiagnosticsAt = now
        VoiceLog.log("state \(state), buffers \(audio.bufferCount), mic \(String(format: "%.2f", input)), "
            + "results \(resultCount), last result \(Int(now.timeIntervalSince(lastResultAt)))s ago, "
            + "cutoff \(String(format: "%.1f", cutoff)), latest \(String(format: "%.1f", latestResultEnd))")

        // The user is talking but nothing comes back: restart recognition rather than hang.
        if state == .listening, now.timeIntervalSince(lastLoudAt) < 3, now.timeIntervalSince(lastResultAt) > 8, recoveries < 3 {
            recoveries += 1
            VoiceLog.log("no results while speaking; restarting recognition (\(recoveries))")
            Task {
                await stopRecognition()
                resetUtterance()
                await startRecognition()
            }
        }
    }

    private func commit() {
        let text = transcript
        VoiceLog.log("commit: \(text.count) chars")
        resetUtterance()
        // "Yes" to a drafted action is answered here: the model can't press its own card.
        if pendingDraft != nil, let answer = Self.answer(in: text) {
            resolveDraft(confirm: answer)
            return
        }
        pendingDraft = nil
        // Finalize what the recognizer still holds; those results land before the cutoff and are dropped.
        let analyzer = self.analyzer
        Task { try? await analyzer?.finalize(through: nil) }

        spokenReply = ""
        spokenCount = 0
        replyMessageId = nil
        do {
            try send(text)
            runToken = chatService.runs[chatId]?.token
            state = .thinking
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Confirms or dismisses the pending draft (a spoken answer or a tap).
    func resolveDraft(confirm: Bool) {
        guard let pending = pendingDraft else { return }
        pendingDraft = nil
        spokenReply = ""
        state = .speaking
        Task {
            do {
                try await DraftPerformer.resolve(pending.draft, messageId: pending.messageId, confirm: confirm)
                say(confirm ? DraftPerformer.confirmation(for: pending.draft) : "Okay, cancelled.")
                VoiceLog.log("draft \(pending.draft.kind.rawValue) \(confirm ? "confirmed" : "dismissed") by voice")
            } catch {
                say("Sorry, that didn't work. \(error.localizedDescription)")
                VoiceLog.log("draft failed: \(error)")
            }
        }
    }

    private func say(_ text: String) {
        spokenReply = text
        speech.enqueue(text)
        state = .speaking
    }

    /// A short yes or no, in English or Russian; `nil` for anything else.
    private static func answer(in text: String) -> Bool? {
        let words = Self.words(in: text)
        // "Set it for 11" changes the draft rather than confirming it.
        guard !words.isEmpty, words.count <= 6, !text.contains(where: \.isNumber) else { return nil }
        let yes: Set<String> = ["yes", "yeah", "yep", "yup", "sure", "ok", "okay", "confirm", "confirmed", "confirming",
                                "proceed", "go", "do", "set", "add", "please", "да", "давай", "ок", "окей", "подтверждаю",
                                "конечно", "ставь", "добавь", "хорошо"]
        let no: Set<String> = ["no", "nope", "cancel", "don't", "dont", "dismiss", "stop", "нет", "отмена", "отмени", "не"]
        if words.contains(where: no.contains) { return false }
        if words.contains(where: yes.contains) { return true }
        return nil
    }

    private func resetUtterance() {
        finalized = ""
        volatile = ""
        transcript = ""
        cutoff = latestResultEnd
    }

    // MARK: - Reply

    /// Reads new complete sentences of the streaming reply aloud.
    private func followRun() {
        if runToken == nil || chatService.runs[chatId]?.token != runToken {
            // A consent answer or an escalation started a new run in this chat.
            guard let run = chatService.runs[chatId], run.isActive else { return finishIfQuiet() }
            runToken = run.token
        }
        guard let run = chatService.runs[chatId] else { return }

        if let messageId = run.messageId, messageId != replyMessageId {
            // Escalation replaced the on-device reply: start over with the new one.
            if replyMessageId != nil { speech.stop() }
            replyMessageId = messageId
            spokenCount = 0
            spokenReply = ""
        }

        let speakable = run.isActive ? SpeakableText.completeSentences(in: run.content) : SpeakableText.clean(run.content)
        if speakable.count > spokenCount {
            speech.enqueue(String(speakable.dropFirst(spokenCount)))
            spokenCount = speakable.count
            spokenReply = speakable
            state = .speaking
        }

        guard !run.isActive else { return }
        if let last = lastAssistantMessage(), let draft = last.extras.drafts.last(where: { $0.status == .pending }),
           pendingDraft?.draft.id != draft.id {
            pendingDraft = PendingDraft(messageId: last.id, draft: draft)
        }
        if spokenCount == 0, let last = lastAssistantMessage() {
            switch last.status {
            case .awaitingConsent:
                consent = last
                state = .needsConsent
                speech.enqueue("This needs a cloud model. Allow it on the screen.")
                runToken = nil
                return
            case .failed:
                spokenReply = last.error ?? "Something went wrong."
                speech.enqueue("Sorry, I couldn't answer that.")
                spokenCount = 1
                state = .speaking
            default:
                break
            }
        }
        finishIfQuiet()
    }

    /// Back to listening once the reply has been read out, after a short gate: the speaker's
    /// tail and the canceller's residue would otherwise be heard as the user.
    private func finishIfQuiet() {
        guard !speech.isBusy, state == .speaking || state == .thinking,
              Date().timeIntervalSince(audio.lastPlaybackEnd) > Self.postPlaybackGate else { return }
        runToken = nil
        resetUtterance()
        state = .listening
    }

    private func lastAssistantMessage() -> Message? {
        (try? database.fetchMessages(chatId: chatId))?.last { $0.role == .assistant }
    }

    // MARK: - Languages

    /// The user's languages that speech recognition supports, plus the current one.
    static func suggestedLocales(current: Locale) async -> [Locale] {
        let supported = await SpeechTranscriber.supportedLocales
        var result: [Locale] = []
        for identifier in Locale.preferredLanguages + ["en-US"] {
            let candidate = Locale(identifier: identifier)
            if let match = supported.first(where: { $0.identifier(.bcp47) == candidate.identifier(.bcp47) })
                ?? supported.first(where: { $0.language.languageCode == candidate.language.languageCode }),
               !result.contains(where: { $0.identifier == match.identifier }) {
                result.append(match)
            }
        }
        if !result.contains(where: { $0.language.languageCode == current.language.languageCode }) {
            result.insert(current, at: 0)
        }
        return result
    }

    /// "English (United States)". Built from language and region only: the current locale's
    /// identifier can carry extensions (e.g. `en_US@rg=plzzzz`) that don't localize.
    static func name(of locale: Locale) -> String {
        let code = locale.language.languageCode?.identifier ?? locale.identifier
        let identifier = locale.language.region.map { "\(code)-\($0.identifier)" } ?? code
        return Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}
