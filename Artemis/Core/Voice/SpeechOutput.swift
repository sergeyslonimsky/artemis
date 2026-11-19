@preconcurrency import AVFoundation
import Synchronization

/// Reads replies aloud sentence by sentence, so speech starts while the reply is still streaming.
@MainActor
final class SpeechOutput {
    private let synthesizer = AVSpeechSynthesizer()
    private let audio: VoiceAudio
    private var queue: [String] = []
    private var worker: Task<Void, Never>?
    /// Language of the last sentence long enough to tell, for short ones in between.
    private var lastLanguage: String?
    private var voices: [String: AVSpeechSynthesisVoice] = [:]
    /// Resumes the sentence being synthesized; `stop()` uses it, as a stopped synthesizer
    /// doesn't always deliver its final buffer.
    private var current: SynthesisCompletion?

    init(audio: VoiceAudio) {
        self.audio = audio
    }

    /// Whether anything is queued, being synthesized or still playing.
    var isBusy: Bool {
        !queue.isEmpty || worker != nil || audio.isPlaying
    }

    func enqueue(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains(where: \.isLetter) || text.contains(where: \.isNumber) else { return }
        queue.append(text)
        if worker == nil {
            worker = Task { await drain() }
        }
    }

    /// Stops speaking at once and forgets what was queued.
    func stop() {
        queue.removeAll()
        worker?.cancel()
        worker = nil
        synthesizer.stopSpeaking(at: .immediate)
        current?.finish()
        current = nil
        audio.stopPlayback()
    }

    private func drain() async {
        while !queue.isEmpty, !Task.isCancelled {
            let sentence = queue.removeFirst()
            await synthesize(sentence)
        }
        if !Task.isCancelled { worker = nil }
    }

    /// Buffers are played as they arrive; returns when the sentence is fully synthesized.
    private func synthesize(_ text: String) async {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice(for: text)
        let audio = self.audio
        let completion = SynthesisCompletion()
        current = completion
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            completion.set(continuation)
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    completion.finish()
                    return
                }
                if !completion.isFinished { audio.play(pcm) }
            }
        }
        if current === completion { current = nil }
    }

    // MARK: - Voices

    /// The best installed voice for the sentence's language (Premium > Enhanced > default).
    private func voice(for text: String) -> AVSpeechSynthesisVoice? {
        let language: String
        if let detected = Locale.Language(detectedIn: text, minimumLength: 12)?.languageCode?.identifier {
            language = detected
            lastLanguage = detected
        } else {
            language = lastLanguage ?? Locale.current.language.languageCode?.identifier ?? "en"
        }
        if let cached = voices[language] { return cached }

        let best = Self.bestVoice(for: language) ?? AVSpeechSynthesisVoice(language: language)
        voices[language] = best
        return best
    }

    /// Installed voices that can read replies: no novelty or Personal Voice.
    static func installedVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { voice in
            !voice.voiceTraits.contains(.isNoveltyVoice) && !voice.voiceTraits.contains(.isPersonalVoice)
        }
    }

    /// The voice replies in `language` are read with: Premium > Enhanced > default.
    static func bestVoice(for language: String) -> AVSpeechSynthesisVoice? {
        let preferredRegion = Locale.current.region?.identifier
        return installedVoices().filter { $0.language.hasPrefix(language) }.max { lhs, rhs in
            if lhs.quality != rhs.quality { return lhs.quality.rawValue < rhs.quality.rawValue }
            // Same quality: the user's region (en-GB for a UK user), then a stable order.
            let lhsRegion = lhs.language.hasSuffix(preferredRegion ?? "-")
            let rhsRegion = rhs.language.hasSuffix(preferredRegion ?? "-")
            if lhsRegion != rhsRegion { return !lhsRegion }
            return lhs.identifier > rhs.identifier
        }
    }

    /// Whether replies in this language will sound natural (an Enhanced or Premium voice is installed).
    static func hasGoodVoice(for language: String) -> Bool {
        AVSpeechSynthesisVoice.speechVoices().contains { $0.language.hasPrefix(language) && $0.quality != .default }
    }
}

/// Turns streamed Markdown into text worth reading aloud.
enum SpeakableText {
    /// The speakable part of `markdown` that ends in a complete sentence. While a reply streams,
    /// only this part is read, so a sentence is never cut in the middle.
    static func completeSentences(in markdown: String) -> String {
        guard let end = lastSentenceEnd(in: markdown) else { return "" }
        return clean(String(markdown[..<end]))
    }

    /// Markdown without code, links, emphasis or list markers.
    static func clean(_ markdown: String) -> String {
        var lines: [String] = []
        var inCode = false
        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if !inCode { lines.append("(code omitted).") }
                inCode.toggle()
                continue
            }
            if inCode || line.hasPrefix("|") || line.allSatisfy({ "-=*_ ".contains($0) }) && !line.isEmpty {
                continue
            }
            var text = line
            text = text.replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"^([-*+]|\d+[.)])\s+"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"^>\s*"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            text = text.replacingOccurrences(of: #"`([^`]*)`"#, with: "$1", options: .regularExpression)
            text = text.replacingOccurrences(of: #"(\*\*|__|\*|_|~~)"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
            guard !text.isEmpty else { continue }
            // A heading or list item without punctuation still ends a spoken phrase.
            if let last = text.last, !".!?…:;,".contains(last) { text += "." }
            lines.append(text)
        }
        return lines.joined(separator: " ")
    }

    /// Index just past the last sentence end that is followed by whitespace, or the last newline.
    private static func lastSentenceEnd(in text: String) -> String.Index? {
        var index = text.endIndex
        while index > text.startIndex {
            let previous = text.index(before: index)
            let character = text[previous]
            if character == "\n" { return previous }
            if ".!?…".contains(character), index < text.endIndex, text[index].isWhitespace {
                return index
            }
            index = previous
        }
        return nil
    }
}

/// Resumes a synthesis continuation exactly once, from whichever thread gets there first.
private final class SynthesisCompletion: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Void, Never>?
        var finished = false
    }

    private let state = Mutex(State())

    var isFinished: Bool { state.withLock { $0.finished } }

    func set(_ continuation: CheckedContinuation<Void, Never>) {
        let resumeNow = state.withLock { state in
            if state.finished { return true }
            state.continuation = continuation
            return false
        }
        if resumeNow { continuation.resume() }
    }

    func finish() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.finished else { return nil }
            state.finished = true
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume()
    }
}
