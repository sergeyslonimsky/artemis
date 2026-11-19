@preconcurrency import AVFoundation
import Speech
import os

/// Microphone in, speech out, through one engine with voice processing on: the echo canceller
/// only knows about audio this engine plays, so spoken replies go through it too. That keeps the
/// recognizer from hearing the assistant and lets the user interrupt it by talking.
///
/// Audio callbacks run on real-time threads, so this class is not tied to an actor; shared state
/// is behind a lock.
final class VoiceAudio: @unchecked Sendable {
    /// Mono float at a common TTS rate; synthesized buffers are converted to it.
    private static let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)!

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private static let logger = Logger(subsystem: "com.artemis.ios", category: "VoiceAudio")

    // Guarded by `lock`.
    private var inputConverter: AnalyzerInputConverter?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var muted = false
    private var inputLevelValue: Float = 0
    private var outputLevelValue: Float = 0
    private var capturedSeconds: Double = 0
    private var pendingBuffers = 0
    private var playbackConverters: [String: AVAudioConverter] = [:]
    private var capturedBuffers = 0
    private var playbackEndedAt = Date.distantPast
    private var configurationObserver: (any NSObjectProtocol)?

    /// Microphone loudness, 0…1.
    var inputLevel: Float { lock.withLock { inputLevelValue } }
    /// Loudness of what is being played, 0…1.
    var outputLevel: Float { lock.withLock { outputLevelValue } }
    /// Seconds of microphone audio fed to the recognizer so far (its timeline).
    var capturedTime: Double { lock.withLock { capturedSeconds } }
    var isPlaying: Bool { lock.withLock { pendingBuffers > 0 } }
    /// Microphone buffers received since start (diagnostics).
    var bufferCount: Int { lock.withLock { capturedBuffers } }
    /// When the last queued speech finished playing.
    var lastPlaybackEnd: Date { lock.withLock { playbackEndedAt } }

    var isMuted: Bool {
        get { lock.withLock { muted } }
        set { lock.withLock { muted = newValue } }
    }

    /// Whether this engine also speaks (voice mode) or only listens (dictation).
    private var isConversation = true

    /// Starts capture; the stream yields microphone audio in `analyzerFormat`.
    /// - Parameter conversation: `true` adds playback with echo cancellation; dictation only listens.
    func start(analyzerFormat: AVAudioFormat, conversation: Bool = true) throws -> AsyncStream<AnalyzerInput> {
        isConversation = conversation
        let session = AVAudioSession.sharedInstance()
        let input = engine.inputNode
        if conversation {
            // `.voiceChat` is the mode voice processing is tuned for; with `.default` its echo
            // cancellation runs but barely cancels speaker playback.
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)

            // The playback graph must exist before voice processing is enabled: the echo canceller
            // takes its reference from the output bus, and an empty one leaves nothing to subtract.
            engine.attach(player)
            try engine.connectNode(player, to: engine.mainMixerNode, format: Self.playbackFormat)

            try input.setVoiceProcessingEnabled(true)
            // Other apps' audio shouldn't be ducked more than needed while we listen.
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: true, duckingLevel: .min)
        } else {
            try session.setCategory(.record, mode: .default, options: [.allowBluetoothHFP])
            try session.setActive(true)
        }

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        lock.withLock {
            self.inputConverter = AnalyzerInputConverter(analyzerFormat: analyzerFormat)
            self.continuation = continuation
            self.capturedSeconds = 0
            self.capturedBuffers = 0
        }

        try installTaps()
        engine.prepare()
        try engine.start()
        if conversation { try player.playAudio() }
        VoiceLog.log("audio started: input \(input.outputFormat(forBus: 0)), analyzer \(analyzerFormat), route \(Self.routeDescription)")

        // A route change (headphones, Bluetooth, a call) stops the engine; without a restart the
        // microphone goes silent and the session listens forever.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.restartAfterConfigurationChange()
        }
        return stream
    }

    func stop() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        if isConversation {
            player.stop()
            player.removeTap(onBus: 0)
            // Voice processing is reset before the engine stops; left enabled, it can keep the next
            // session's microphone silent.
            try? engine.inputNode.setVoiceProcessingEnabled(false)
        }
        engine.stop()
        if isConversation { engine.detach(player) }
        VoiceLog.log("audio stopped after \(bufferCount) buffers")
        lock.withLock {
            continuation?.finish()
            continuation = nil
            inputConverter = nil
            pendingBuffers = 0
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func installTaps() throws {
        let input = engine.inputNode
        try input.installAudioTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            self?.capture(buffer)
        }
        guard isConversation else { return }
        try player.installAudioTap(onBus: 0, bufferSize: 1024, format: Self.playbackFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let level = Self.level(of: buffer)
            self.lock.withLock { self.outputLevelValue = self.pendingBuffers > 0 ? level : 0 }
        }
    }

    private func restartAfterConfigurationChange() {
        VoiceLog.log("audio configuration changed (running: \(engine.isRunning)), route \(Self.routeDescription)")
        engine.inputNode.removeTap(onBus: 0)
        if isConversation { player.removeTap(onBus: 0) }
        do {
            try installTaps()
            engine.prepare()
            try engine.start()
            if isConversation { try player.playAudio() }
            VoiceLog.log("audio restarted: input \(engine.inputNode.outputFormat(forBus: 0))")
        } catch {
            VoiceLog.log("audio restart failed: \(error.localizedDescription)")
        }
    }

    private static var routeDescription: String {
        let route = AVAudioSession.sharedInstance().currentRoute
        let inputs = route.inputs.map(\.portType.rawValue).joined(separator: ",")
        let outputs = route.outputs.map(\.portType.rawValue).joined(separator: ",")
        return "in[\(inputs)] out[\(outputs)]"
    }

    // MARK: - Capture

    private func capture(_ tapBuffer: AVReadOnlyAudioPCMBuffer) {
        let level = Self.level(of: tapBuffer)
        let seconds = Double(tapBuffer.frameLength) / tapBuffer.format.sampleRate
        // Tap buffers are read-only; muting and the analyzer converter need one of our own.
        let buffer = AVAudioPCMBuffer(copying: tapBuffer)
        lock.withLock {
            // While muted, silence keeps the recognizer's timeline moving.
            if muted { Self.silence(buffer) }
            inputLevelValue = muted ? 0 : level
            capturedSeconds += seconds
            capturedBuffers += 1
            guard let inputConverter, let continuation else { return }
            do {
                for input in try inputConverter.convert(buffer, at: nil) {
                    continuation.yield(input)
                }
            } catch {
                Self.logger.error("Audio conversion failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Playback

    /// Queues synthesized speech; `onPlayed` runs when this buffer has been heard.
    func play(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, let converted = convertForPlayback(buffer) else { return }
        lock.withLock { pendingBuffers += 1 }
        player.scheduleBuffer(converted, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.lock.withLock {
                self.pendingBuffers = max(0, self.pendingBuffers - 1)
                if self.pendingBuffers == 0 {
                    self.outputLevelValue = 0
                    self.playbackEndedAt = Date()
                }
            }
        }
        if !player.isPlaying { try? player.playAudio() }
    }

    /// Drops everything queued (the user interrupted).
    func stopPlayback() {
        player.stop()
        lock.withLock {
            pendingBuffers = 0
            outputLevelValue = 0
        }
        try? player.playAudio()
    }

    private func convertForPlayback(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let target = Self.playbackFormat
        if buffer.format == target { return buffer }
        let key = "\(buffer.format.sampleRate)-\(buffer.format.commonFormat.rawValue)-\(buffer.format.channelCount)-\(buffer.format.isInterleaved)"
        let converter: AVAudioConverter? = lock.withLock {
            if let cached = playbackConverters[key] { return cached }
            let created = AVAudioConverter(from: buffer.format, to: target)
            playbackConverters[key] = created
            return created
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if let error {
            Self.logger.error("Playback conversion failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return output
    }

    // MARK: - Levels

    /// RMS mapped from -50…0 dB to 0…1.
    private static func level(of buffer: AVReadOnlyAudioPCMBuffer) -> Float {
        guard buffer.frameLength > 0, case .float(let samples) = buffer.channelData(0) else { return 0 }
        let count = min(buffer.frameLength, samples.count)
        var sum: Float = 0
        for index in 0..<count { sum += samples[index] * samples[index] }
        let rms = (sum / Float(count)).squareRoot()
        let decibels = 20 * log10(max(rms, 1e-7))
        return min(max((decibels + 50) / 50, 0), 1)
    }

    private static func silence(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        for channel in 0..<Int(buffer.format.channelCount) {
            channels[channel].update(repeating: 0, count: Int(buffer.frameLength))
        }
    }
}
