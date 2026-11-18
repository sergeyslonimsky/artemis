import Foundation
import FoundationModels
import ImageIO
import UniformTypeIdentifiers
import os

/// Failures of the on-device model, phrased for the user. The router (stage 3) uses
/// them to decide whether to escalate to the cloud.
public enum OnDeviceError: LocalizedError, Sendable, Equatable {
    case unavailable(OnDeviceModelStatus)
    case contextTooLong
    case unsupportedAttachment(String)
    case unsupportedLanguage
    case guardrailViolation
    case refusal
    case rateLimited
    case timeout
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let status):
            status.detail
        case .contextTooLong:
            "This conversation is too long for the on-device model."
        case .unsupportedAttachment(let filename):
            "The on-device model can't read \(filename)."
        case .unsupportedLanguage:
            "The on-device model doesn't support this language."
        case .guardrailViolation:
            "The on-device model declined this request because of its safety guidelines."
        case .refusal:
            "The on-device model declined to answer."
        case .rateLimited:
            "The on-device model is busy. Try again in a moment."
        case .timeout:
            "The on-device model took too long to respond."
        case .failed(let message):
            message
        }
    }

    static func map(_ error: any Error) -> any Error {
        if error is OnDeviceError || error is CancellationError { return error }
        guard let error = error as? LanguageModelError else {
            // System-level failures (model assets, inference service) carry opaque codes.
            return OnDeviceError.failed("The on-device model failed (\((error as NSError).domain) \((error as NSError).code)). Try again or switch to a cloud model.")
        }
        switch error {
        case .contextSizeExceeded:
            return OnDeviceError.contextTooLong
        case .guardrailViolation:
            return OnDeviceError.guardrailViolation
        case .refusal:
            return OnDeviceError.refusal
        case .rateLimited:
            return OnDeviceError.rateLimited
        case .timeout:
            return OnDeviceError.timeout
        case .unsupportedLanguageOrLocale:
            return OnDeviceError.unsupportedLanguage
        case .unsupportedCapability, .unsupportedTranscriptContent:
            return OnDeviceError.unsupportedAttachment("this attachment")
        case .unsupportedGenerationGuide:
            return OnDeviceError.failed(error.localizedDescription)
        @unknown default:
            return OnDeviceError.failed(error.localizedDescription)
        }
    }
}

/// Apple's on-device model (Foundation Models). Each turn rebuilds a session from the chat
/// history, trimmed from the oldest end to fit the model's context window.
public struct AppleOnDeviceBackend: ChatBackend {
    /// Tokens kept free for the reply.
    static let maxResponseTokens = 1024
    /// Images don't go through `tokenCount`; reserve a conservative amount for each.
    static let estimatedTokensPerImage = 600

    /// A small model doesn't know where it runs and borrows capabilities from bigger assistants
    /// in its training data, so its limits are spelled out explicitly.
    static func baseInstructions(now: Date = Date()) -> String {
        let today = now.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        return """
            You are Artemis, an assistant that runs entirely offline on the user's iPhone. Today is \(today).

            You CANNOT:
            - access the internet: no browsing, searching, news, weather, prices, or anything after your training data;
            - take actions on the device or in apps: no alarms, timers, reminders, calendar events, messages, calls, or settings;
            - remember other conversations.

            When a request needs any of these, say in one sentence that you can't do it here and suggest asking \
            a cloud model instead. Never pretend to have done it.

            Answer accurately and concisely, using Markdown when it helps. If you are unsure about a fact, \
            or can't read an image or handwriting clearly, say so instead of guessing.
            """
    }

    private static let logger = Logger(subsystem: "com.artemis.ios", category: "AppleOnDeviceBackend")

    public init() {}

    public var descriptor: BackendDescriptor {
        BackendDescriptor(kind: .onDevice)
    }

    public func stream(_ turn: ChatTurn) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Self.generate(turn, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Task.isCancelled ? CancellationError() : OnDeviceError.map(error))
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - Generation

    private static func generate(_ turn: ChatTurn, into continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation) async throws {
        let status = OnDeviceModelStatus.current
        guard status.isAvailable else { throw OnDeviceError.unavailable(status) }

        let model = SystemLanguageModel.default
        guard let last = turn.messages.last, last.role == .user else {
            throw OnDeviceError.failed("There is no message to answer.")
        }

        let request = try await PromptParts(message: last, model: model)
        let responseBudget = min(maxResponseTokens, model.contextSize / 4)
        let transcript = try await buildTranscript(
            instructions: instructions(for: turn),
            history: Array(turn.messages.dropLast()),
            promptText: request.text,
            reservedTokens: responseBudget + request.images.count * estimatedTokensPerImage,
            model: model
        )

        let session = LanguageModelSession(model: model, transcript: transcript)
        let options = GenerationOptions(
            temperature: turn.preset?.temperature,
            maximumResponseTokens: responseBudget
        )

        // Measured from the request: short replies often arrive in a single snapshot,
        // so time-to-last-token alone would report absurd speeds.
        let start = Date()
        var content = ""
        var reasoning = ""
        var outputTokens: Int?

        for try await snapshot in session.streamResponse(to: request.prompt, options: options) {
            try Task.checkCancellation()

            let newReasoning = reasoningText(in: snapshot.transcriptEntries)
            if let delta = appendedText(from: reasoning, to: newReasoning) {
                continuation.yield(.reasoning(delta))
            }
            reasoning = newReasoning

            if let delta = appendedText(from: content, to: snapshot.content) {
                continuation.yield(.content(delta))
            }
            content = snapshot.content
            outputTokens = snapshot.usage.output.totalTokenCount
        }

        let durationMs = max(1, Int(Date().timeIntervalSince(start) * 1000))
        let tokens = outputTokens.flatMap { $0 > 0 ? $0 : nil }
        continuation.yield(.done(
            tokens: tokens ?? max(1, content.count / 4),
            isEstimated: tokens == nil,
            durationMs: durationMs
        ))
    }

    private static func instructions(for turn: ChatTurn) -> String {
        let custom = turn.preset?.systemPrompt.isEmpty == false ? turn.preset?.systemPrompt : turn.systemPrompt
        guard turn.usesAssistantPersona else { return custom ?? "" }
        guard let custom, !custom.isEmpty else { return baseInstructions() }
        return baseInstructions() + "\n\n" + custom
    }

    /// Instructions + as much recent history as fits next to the prompt and the reserved tokens.
    private static func buildTranscript(
        instructions: String,
        history: [Message],
        promptText: String,
        reservedTokens: Int,
        model: SystemLanguageModel
    ) async throws -> Transcript {
        let instructionsEntry = Transcript.Entry.instructions(
            Transcript.Instructions(segments: [.text(.init(content: instructions))], toolDefinitions: [])
        )
        let promptEntry = Transcript.Entry.prompt(
            Transcript.Prompt(segments: [.text(.init(content: promptText))])
        )

        var used = await tokenCount([instructionsEntry, promptEntry], model: model) + reservedTokens
        guard used <= model.contextSize else { throw OnDeviceError.contextTooLong }

        // Walk back from the newest message and stop at the first one that doesn't fit.
        var kept: [Transcript.Entry] = []
        for message in history.reversed() {
            guard let entry = historyEntry(for: message) else { continue }
            let cost = await tokenCount([entry], model: model)
            guard used + cost <= model.contextSize else { break }
            used += cost
            kept.append(entry)
        }

        if kept.count < history.count {
            logger.debug("Trimmed \(history.count - kept.count) old messages to fit the on-device context")
        }
        return Transcript(entries: [instructionsEntry] + kept.reversed())
    }

    /// Exact count when the system can provide it (not in the Simulator); otherwise a
    /// conservative estimate of ~3 characters per token.
    private static func tokenCount(_ entries: [Transcript.Entry], model: SystemLanguageModel) async -> Int {
        if let count = try? await model.tokenCount(for: entries) {
            return count
        }
        let characters = entries.reduce(0) { total, entry in
            total + textSegments(of: entry).reduce(0) { $0 + $1.count }
        }
        return characters / 3 + 8
    }

    private static func textSegments(of entry: Transcript.Entry) -> [String] {
        let segments: [Transcript.Segment]
        switch entry {
        case .instructions(let value): segments = value.segments
        case .prompt(let value): segments = value.segments
        case .response(let value): segments = value.segments
        default: segments = []
        }
        return segments.compactMap { segment in
            if case .text(let text) = segment { return text.content }
            return nil
        }
    }

    /// Past turns as text. Earlier attachments are only mentioned to save context.
    private static func historyEntry(for message: Message) -> Transcript.Entry? {
        var text = message.content
        for attachment in message.attachments {
            text += "\n[Attached \(attachment.kind == .image ? "image" : "file"): \(attachment.filename)]"
        }
        guard !text.isEmpty else { return nil }
        let segments: [Transcript.Segment] = [.text(.init(content: text))]

        switch message.role {
        case .user:
            return .prompt(Transcript.Prompt(segments: segments))
        case .assistant:
            return .response(Transcript.Response(assetIDs: [], segments: segments))
        case .system:
            return nil
        }
    }

    private static func reasoningText(in entries: ArraySlice<Transcript.Entry>) -> String {
        entries.compactMap { entry -> String? in
            guard case .reasoning(let reasoning) = entry else { return nil }
            return reasoning.segments.compactMap { segment in
                if case .text(let text) = segment { return text.content }
                return nil
            }.joined()
        }.joined(separator: "\n")
    }

    /// The suffix added since the previous snapshot; `nil` if nothing new.
    /// Snapshots of plain text only grow, so a rewrite is logged and skipped.
    private static func appendedText(from previous: String, to current: String) -> String? {
        guard current.count > previous.count else { return nil }
        guard current.hasPrefix(previous) else {
            logger.error("On-device snapshot rewrote earlier text; skipping the divergent part")
            return nil
        }
        return String(current.dropFirst(previous.count))
    }
}

// MARK: - Prompt

/// The message being answered: its text plus attachments in a form the model accepts.
private struct PromptParts {
    let text: String
    let images: [CGImage]
    let prompt: Prompt

    init(message: Message, model: SystemLanguageModel) async throws {
        var text = message.content
        var images: [CGImage] = []
        var files: [RawDataAttachment] = []

        for attachment in message.attachments {
            guard let data = attachment.data else { continue }
            let type = UTType(mimeType: attachment.mime) ?? .data

            if attachment.kind == .image {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw OnDeviceError.unsupportedAttachment(attachment.filename)
                }
                images.append(image)
            } else if type.conforms(to: .text) || type.conforms(to: .json), let body = String(data: data, encoding: .utf8) {
                text += "\n\nFile: \(attachment.filename)\n```\n\(body)\n```"
            } else if try await model.supportsDataAttachmentType(type) {
                files.append(RawDataAttachment(contentType: type, content: data))
            } else {
                throw OnDeviceError.unsupportedAttachment(attachment.filename)
            }
        }

        self.text = text
        self.images = images
        self.prompt = Prompt {
            text
            for image in images {
                FoundationModels.Attachment(image)
            }
            for file in files {
                FoundationModels.Attachment(file)
            }
        }
    }
}

/// Bytes the model accepts natively (e.g. PDF), passed through as-is.
private struct RawDataAttachment: DataAttachmentRepresentable {
    let contentType: UTType
    let content: Data

    init(contentType: UTType, content: Data) {
        self.contentType = contentType
        self.content = content
    }

    init(_ attachment: Transcript.DataAttachment) throws {
        self.init(contentType: attachment.contentType, content: attachment.content)
    }

    var transcriptRepresentation: Transcript.DataAttachment {
        Transcript.DataAttachment(contentType: contentType, content: content)
    }
}
