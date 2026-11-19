import Foundation
import FoundationModels
import ImageIO
import Synchronization
import UniformTypeIdentifiers
import os

/// Failures of the on-device model, phrased for the user. `ChatService` uses them to decide
/// whether to escalate to the cloud.
enum OnDeviceError: LocalizedError, Sendable, Equatable {
    case unavailable(OnDeviceModelStatus)
    case contextTooLong
    case unsupportedAttachment(String)
    case unsupportedLanguage
    case guardrailViolation
    case refusal
    case rateLimited
    case timeout
    case failed(String)

    var errorDescription: String? {
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
struct AppleOnDeviceBackend: ChatBackend {
    /// Tokens kept free for the reply.
    static let maxResponseTokens = 1024
    /// Images don't go through `tokenCount`; reserve a conservative amount for each.
    static let estimatedTokensPerImage = 600

    /// A small model doesn't know where it runs and borrows capabilities from bigger assistants,
    /// so its limits are stated once, calmly, after what it can do: a long list of "can't"s up
    /// front made it refuse things it handles well (e.g. describing an image).
    static func baseInstructions(now: Date = Date(), tools: Set<ToolGroup> = []) -> String {
        let today = now.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        var missing: [String] = []
        if !tools.contains(.alarms) { missing.append("setting alarms") }
        if !tools.contains(.schedule) { missing.append("adding reminders") }
        if !tools.contains(.contacts) { missing.append("sending messages or making calls") }
        let actions = missing.isEmpty ? "changing settings or controlling other apps" : missing.joined(separator: ", ")
        let internet = tools.contains(.weather) ? "no internet access (except the weather tool)" : "no internet access"
        let base = """
            You are Artemis, a helpful assistant running on the user's iPhone. Today is \(today).

            You can read images and documents the user attaches, answer questions, explain things, \
            write and edit text, translate, and summarize. Answer directly and helpfully, using Markdown \
            when it helps.

            You have \(internet) and can't take actions on the device, such as \(actions). \
            Only when a request truly depends on one of these, say in one short sentence that you can't do \
            that part, then help with everything else. Don't mention other models or services. \
            If you're unsure about a fact, say so briefly.
            """
        guard !tools.isEmpty else { return base }
        return base + "\n\n" + upcomingDates(from: now) + "\n" + PersonalDataTools.instructions(for: tools)
    }

    /// The model can't count weekdays: "on Monday" became the next day. Tools take ISO dates.
    static func upcomingDates(from now: Date) -> String {
        let calendar = Calendar.current
        let days = (1...7).compactMap { calendar.date(byAdding: .day, value: $0, to: now) }.map { day in
            let name = day.formatted(Date.FormatStyle(locale: Locale(identifier: "en_US_POSIX")).weekday(.wide))
            return "\(name) \(day.formatted(.iso8601.year().month().day()))"
        }
        return "Today's date is \(now.formatted(.iso8601.year().month().day())); the next days: \(days.joined(separator: ", "))."
    }

    /// Without this the model took "rescan the receipt" for an action it can't take, though the
    /// receipt's text was right there in the conversation.
    static let imageTextInstructions = """
        Images in this conversation come with the text recognized in them (OCR). When the user asks you \
        to look at, re-read or rescan an image, even one from earlier, answer from that text: it is the \
        image's content, so don't say you can't access or scan it.
        """

    private static let logger = Logger(subsystem: "com.artemis.ios", category: "AppleOnDeviceBackend")

    /// Builds the turn's tools; evals swap in stubs to test the model's choices alone.
    typealias ToolFactory = @Sendable (Set<ToolGroup>, ToolEventSink) -> [any Tool]
    private let makeTools: ToolFactory

    init(makeTools: @escaping ToolFactory = PersonalDataTools.tools) {
        self.makeTools = makeTools
    }

    var descriptor: BackendDescriptor {
        BackendDescriptor(kind: .onDevice)
    }

    func stream(_ turn: ChatTurn) -> AsyncThrowingStream<LLMEvent, Error> {
        .task { continuation in
            do {
                try await Self.generate(turn, makeTools: makeTools, into: continuation)
            } catch {
                throw OnDeviceError.map(error)
            }
        }
    }

    // MARK: - Generation

    private static func generate(
        _ turn: ChatTurn,
        makeTools: ToolFactory,
        into continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
    ) async throws {
        let status = OnDeviceModelStatus.current
        guard status.isAvailable else { throw OnDeviceError.unavailable(status) }

        let model = SystemLanguageModel.default
        guard let last = turn.messages.last, last.role == .user else {
            throw OnDeviceError.failed("There is no message to answer.")
        }

        // A language the model doesn't support is translated on the device both ways, if installed.
        let translation = turn.usesAssistantPersona ? await TranslatedTurn(messages: turn.messages) : nil
        var prompted = last
        if let translation {
            continuation.yield(.toolStarted(.translation))
            prompted.content = try await translation.prompt(last.content)
        }

        let request = try await PromptParts(message: prompted, model: model, includesTime: !turn.toolGroups.isEmpty)
        let responseBudget = min(maxResponseTokens, model.contextSize / 4)
        let reservedTokens = responseBudget + request.images.count * estimatedTokensPerImage
        let instructions = instructions(for: turn, translation: translation?.instructions)
        let history = Array(turn.messages.dropLast())

        // Apple recommends one session per conversation: the model keeps its cache instead of
        // re-reading the history. Reuse it while nothing changed since the last on-device turn.
        var session: LanguageModelSession
        var sink: ToolEventSink
        if let conversationId = turn.conversationId,
           let cached = await OnDeviceSessionCache.shared.take(
               conversationId: conversationId,
               historyIds: history.map(\.id),
               instructions: instructions
           ),
           await fits(cached.session.transcript, promptText: request.text, reservedTokens: reservedTokens, model: model) {
            session = cached.session
            sink = cached.sink
        } else {
            sink = ToolEventSink()
            var tools = makeTools(turn.toolGroups, sink)
            if turn.offersTranslation {
                tools.append(TranslateTool(sink: sink))
            }
            let transcript = try await buildTranscript(
                instructions: instructions,
                history: history,
                imageDetails: ImageTextNote.details(for: history, currentHasImages: last.attachments.contains { $0.kind == .image }),
                translation: translation,
                promptText: request.text,
                reservedTokens: reservedTokens + (tools.isEmpty ? 0 : (try? await model.tokenCount(for: tools)) ?? 400),
                model: model
            )
            session = LanguageModelSession(model: model, tools: tools, transcript: transcript)
        }
        // Drafts of a translated turn wait for their titles to be translated after the reply.
        let heldDrafts = Mutex<[ActionDraft]>([])
        let holdsDrafts = translation != nil
        sink.setHandler { event in
            switch event {
            case .started(let source): continuation.yield(.toolStarted(source))
            case .drafted(let draft):
                if holdsDrafts {
                    heldDrafts.withLock { $0.append(draft) }
                } else {
                    continuation.yield(.actionDraft(draft))
                }
            }
        }
        defer { sink.setHandler(nil) }
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
        var entries: ArraySlice<Transcript.Entry> = []

        do {
            for try await snapshot in session.streamResponse(to: request.prompt, options: options) {
                try Task.checkCancellation()
                entries = snapshot.transcriptEntries

                let newReasoning = reasoningText(in: snapshot.transcriptEntries)
                if let delta = appendedText(from: reasoning, to: newReasoning) {
                    continuation.yield(.reasoning(delta))
                }
                reasoning = newReasoning

                if let delta = appendedText(from: content, to: snapshot.content) {
                    let output = try await translation?.reply(delta) ?? delta
                    if !output.isEmpty {
                        continuation.yield(.content(output))
                    }
                }
                content = snapshot.content
                outputTokens = snapshot.usage.output.totalTokenCount
            }
        } catch {
            // The model failed partway: the reply so far stays, in the user's language. A stopped
            // reply keeps only its finished paragraphs, since nobody reads the stream anymore.
            if let translation, !Task.isCancelled, let rest = try? await translation.finishReply(), !rest.isEmpty {
                continuation.yield(.content(rest))
            }
            throw error
        }

        if let translation {
            let rest = try await translation.finishReply()
            if !rest.isEmpty {
                continuation.yield(.content(rest))
            }
            for draft in heldDrafts.withLock({ $0 }) {
                continuation.yield(.actionDraft(await translation.draft(draft)))
            }
        }

        for call in toolCalls(in: entries) {
            continuation.yield(.toolCall(call))
        }

        if let conversationId = turn.conversationId, let replyId = turn.replyId, !Task.isCancelled {
            await OnDeviceSessionCache.shared.store(
                session,
                sink: sink,
                conversationId: conversationId,
                coveredIds: history.map(\.id) + [last.id, replyId],
                instructions: instructions
            )
        }

        let durationMs = max(1, Int(Date().timeIntervalSince(start) * 1000))
        let tokens = outputTokens.flatMap { $0 > 0 ? $0 : nil }
        continuation.yield(.done(
            tokens: tokens ?? TokenEstimate.tokens(forCharacters: content.count),
            isEstimated: tokens == nil,
            durationMs: durationMs
        ))
    }

    /// - Parameter translation: instructions of a translated turn.
    private static func instructions(for turn: ChatTurn, translation: String? = nil) -> String {
        let custom = Preset.effectiveSystemPrompt(preset: turn.preset, fallback: turn.systemPrompt)
        guard turn.usesAssistantPersona else { return custom ?? "" }
        let hasImages = turn.messages.contains { $0.attachments.contains { $0.kind == .image } }
        let parts = [
            baseInstructions(tools: turn.toolGroups),
            hasImages ? imageTextInstructions : nil,
            turn.offersTranslation ? TranslateTool.instructions : nil,
            translation,
            custom,
        ]
        return parts.compactMap(\.self).joined(separator: "\n\n")
    }

    /// Instructions + as much recent history as fits next to the prompt and the reserved tokens.
    /// A translated turn translates only the messages that fit. Text read in earlier images
    /// shrinks (full → excerpt → label) before a message is dropped.
    private static func buildTranscript(
        instructions: String,
        history: [Message],
        imageDetails: [ImageTextNote.Detail],
        translation: TranslatedTurn?,
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
        let kept = await fitNewestFirst(
            Array(zip(history, imageDetails)),
            room: model.contextSize - used,
            variants: { message, maxDetail in
                var message = message
                if let translation {
                    message.content = await translation.history(message.content)
                }
                return historyTexts(for: message, maxDetail: maxDetail).compactMap { historyEntry(text: $0, role: message.role) }
            },
            cost: { await tokenCount([$0], model: model) }
        )

        if kept.count < history.count {
            logger.debug("Trimmed \(history.count - kept.count) old messages to fit the on-device context")
        }
        return Transcript(entries: [instructionsEntry] + kept)
    }

    /// Whether a reused session still has room for the next prompt and the reply.
    private static func fits(_ transcript: Transcript, promptText: String, reservedTokens: Int, model: SystemLanguageModel) async -> Bool {
        let promptEntry = Transcript.Entry.prompt(Transcript.Prompt(segments: [.text(.init(content: promptText))]))
        let used = await tokenCount(Array(transcript) + [promptEntry], model: model)
        return used + reservedTokens <= model.contextSize
    }

    /// Exact count when the system can provide it (not in the Simulator); otherwise a
    /// conservative estimate of ~3 characters per token.
    private static func tokenCount(_ entries: [Transcript.Entry], model: SystemLanguageModel) async -> Int {
        if let count = try? await model.tokenCount(for: entries) {
            return count
        }
        let characters = entries.reduce(0) { $0 + $1.text.count }
        return characters / 3 + 8
    }

    /// Picks, newest item first, the first of its variants (most detailed first) that still fits
    /// in `room`, and stops at the first item none of whose variants fits. Oldest first.
    static func fitNewestFirst<Item, Variant>(
        _ items: [Item],
        room: Int,
        variants: (Item) async -> [Variant],
        cost: (Variant) async -> Int
    ) async -> [Variant] {
        var room = room
        var kept: [Variant] = []
        next: for item in items.reversed() {
            let variants = await variants(item)
            guard !variants.isEmpty else { continue }
            for variant in variants {
                let size = await cost(variant)
                if size <= room {
                    room -= size
                    kept.append(variant)
                    continue next
                }
            }
            break
        }
        return kept.reversed()
    }

    /// A past turn as text, most detailed first: text read in its images shrinks
    /// (full → excerpt → label) before the turn is dropped. Empty for an empty message.
    static func historyTexts(for message: Message, maxDetail: ImageTextNote.Detail) -> [String] {
        var texts: [String] = []
        for detail in [ImageTextNote.Detail.full, .excerpt, .label] where detail <= maxDetail {
            let text = historyText(for: message, imageDetail: detail)
            if !text.isEmpty, texts.last != text {
                texts.append(text)
            }
        }
        return texts
    }

    /// Images come back as the text OCR read in them; other attachments are only mentioned to save context.
    private static func historyText(for message: Message, imageDetail: ImageTextNote.Detail) -> String {
        var text = message.content
        for attachment in message.attachments {
            if attachment.kind == .image {
                text += "\n" + ImageTextNote.note(for: attachment, detail: imageDetail)
            } else {
                text += "\n[Attached \(attachment.kindLabel.lowercased()): \(attachment.filename)]"
            }
        }
        return text
    }

    private static func historyEntry(text: String, role: MessageRole) -> Transcript.Entry? {
        let segments: [Transcript.Segment] = [.text(.init(content: text))]
        switch role {
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
            return reasoning.segments.text
        }.joined(separator: "\n")
    }

    /// The turn's tool calls with what each returned.
    static func toolCalls(in entries: ArraySlice<Transcript.Entry>) -> [ToolCallRecord] {
        var outputs: [String: String] = [:]
        for case .toolOutput(let output) in entries {
            outputs[output.id] = output.segments.text
        }
        return entries.flatMap { entry -> [ToolCallRecord] in
            guard case .toolCalls(let calls) = entry else { return [] }
            return calls.map { call in
                ToolCallRecord(
                    name: call.toolName,
                    arguments: call.arguments.jsonString,
                    output: String((outputs[call.id] ?? "").prefix(ToolCallRecord.maxOutputLength))
                )
            }
        }
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

// MARK: - Session cache

/// The last on-device session per chat, with the messages its transcript covers. A session is
/// handed out at most once (`take`), so a chat's turns never share one concurrently.
actor OnDeviceSessionCache {
    static let shared = OnDeviceSessionCache()

    struct Entry: Sendable {
        let session: LanguageModelSession
        /// The tools of `session` report through this sink.
        let sink: ToolEventSink
        let coveredIds: [String]
        let instructions: String
    }

    private var entries: [String: Entry] = [:]

    /// The cached session if it covers exactly `historyIds` with the same instructions.
    func take(conversationId: String, historyIds: [String], instructions: String) -> Entry? {
        guard let entry = entries.removeValue(forKey: conversationId),
              entry.coveredIds == historyIds, entry.instructions == instructions else {
            return nil
        }
        return entry
    }

    func store(_ session: LanguageModelSession, sink: ToolEventSink, conversationId: String, coveredIds: [String], instructions: String) {
        entries[conversationId] = Entry(session: session, sink: sink, coveredIds: coveredIds, instructions: instructions)
    }
}

// MARK: - Prompt

/// The message being answered: its text plus attachments in a form the model accepts.
private struct PromptParts {
    let text: String
    let images: [CGImage]
    let prompt: Prompt

    /// - Parameter includesTime: appends the send time, so relative dates ("in an hour",
    ///   "tomorrow at 9") resolve. Kept out of the instructions so cached sessions stay valid.
    init(message: Message, model: SystemLanguageModel, includesTime: Bool = false) async throws {
        var text = message.content
        if includesTime {
            text += "\n\n(Sent \(message.createdAt.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute())), \(TimeZone.current.identifier))"
        }
        var images: [CGImage] = []
        var files: [RawDataAttachment] = []

        for attachment in message.attachments {
            guard let data = attachment.data else { continue }
            if attachment.kind == .image {
                guard let image = AttachmentProcessor.uprightImage(from: data) else {
                    throw OnDeviceError.unsupportedAttachment(attachment.filename)
                }
                images.append(image)
                // `ReplyJob` normally recognized it already; a turn built elsewhere reads it here.
                var attachment = attachment
                if attachment.recognizedText == nil {
                    attachment.recognizedText = try? await ImageTextRecognizer.recognizeText(in: image)
                }
                if let recognized = ImageTextNote.promptText(for: attachment) {
                    text += "\n\n" + recognized
                }
            } else if let body = attachment.text {
                text += "\n\nFile: \(attachment.filename)\n```\n\(body)\n```"
            } else if try await model.supportsDataAttachmentType(attachment.contentType) {
                files.append(RawDataAttachment(contentType: attachment.contentType, content: data))
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

// MARK: - Transcript text

private extension Array where Element == Transcript.Segment {
    /// The text segments joined; images and other segments are skipped.
    var text: String {
        compactMap { segment in
            if case .text(let text) = segment { return text.content }
            return nil
        }.joined()
    }
}

private extension Transcript.Entry {
    /// Text of instructions, prompts and responses; empty for other entries.
    var text: String {
        switch self {
        case .instructions(let value): value.segments.text
        case .prompt(let value): value.segments.text
        case .response(let value): value.segments.text
        default: ""
        }
    }
}
