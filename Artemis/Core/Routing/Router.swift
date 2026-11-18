import Foundation
import FoundationModels
import NaturalLanguage
import UniformTypeIdentifiers
import os

/// What the router knows about a turn.
public struct RouteContext: Sendable {
    /// The user message being answered (attachment bytes not required).
    public var message: Message
    /// A couple of preceding messages, so follow-ups ("and in Paris?") classify correctly.
    public var recentHistory: [Message]
    public var mode: RoutingMode
    public var onDeviceUsable: Bool
    public var hasCloud: Bool
    /// A non-text file the on-device model can't read (filled in by `Router`).
    public var hasUnsupportedAttachment: Bool
    /// What the chat's cloud model accepts; `nil` when there's no cloud model.
    public var cloudCapabilities: ProviderCapabilities?
    /// On-device tools switched on in the settings.
    public var availableTools: Set<ToolGroup>

    public init(
        message: Message,
        recentHistory: [Message],
        mode: RoutingMode,
        onDeviceUsable: Bool,
        hasCloud: Bool,
        hasUnsupportedAttachment: Bool = false,
        cloudCapabilities: ProviderCapabilities? = nil,
        availableTools: Set<ToolGroup> = []
    ) {
        self.message = message
        self.recentHistory = recentHistory
        self.mode = mode
        self.onDeviceUsable = onDeviceUsable
        self.hasCloud = hasCloud
        self.hasUnsupportedAttachment = hasUnsupportedAttachment
        self.cloudCapabilities = cloudCapabilities
        self.availableTools = availableTools
    }
}

/// Picks the backend for a turn: explicit modes win, then cheap deterministic rules,
/// then an on-device classifier for everything the rules can't decide.
public struct Router: Sendable {
    public init() {}

    @concurrent
    public func route(_ context: RouteContext) async -> RouteDecision {
        var context = context
        context.hasUnsupportedAttachment = await hasUnsupportedAttachment(context.message)
        let rules = RoutingRules(
            supportsLanguage: { SystemLanguageModel.default.supportsLocale(Locale(languageCode: $0)) },
            onDeviceContextSize: SystemLanguageModel.default.contextSize
        )
        var decision: RouteDecision
        if let ruled = rules.evaluate(context) {
            decision = ruled
            // A request about the user's own data in, say, Russian still needs the on-device tools:
            // the cloud model can't see that data.
            if ruled.reason == .unsupportedLanguage, !context.availableTools.isEmpty {
                let classified = await RequestClassifier.classify(context)
                if !classified.reason.toolGroups.isEmpty { decision = classified }
            }
        } else {
            decision = await RequestClassifier.classify(context)
        }
        // Without a cloud model the on-device model answers, but the reason is kept so the
        // reply can say a cloud model would do better.
        if context.mode == .auto, decision.backend == .cloud, !context.hasCloud {
            return .onDevice(decision.reason)
        }
        // The cloud model would reject this message's image or file but the on-device model reads it.
        if context.mode == .auto, decision.backend == .cloud, context.onDeviceUsable, !context.hasUnsupportedAttachment,
           let cloud = context.cloudCapabilities, !RoutingRules.accepts(context.message, cloud) {
            return .onDevice(.cloudCantReadAttachment)
        }
        return decision
    }

    /// Images and text files always work; other files depend on what the model accepts.
    private func hasUnsupportedAttachment(_ message: Message) async -> Bool {
        for attachment in message.attachments where attachment.kind == .document && !RoutingRules.isTextDocument(attachment) {
            let type = UTType(mimeType: attachment.mime) ?? .data
            let supported = (try? await SystemLanguageModel.default.supportsDataAttachmentType(type)) ?? false
            if !supported { return true }
        }
        return false
    }
}

// MARK: - Rules

/// Deterministic routing. Returns `nil` when the request has to be classified.
///
/// Languages outside `supportsLocale` go to the cloud: the model may answer them, but noticeably
/// worse (Apple doesn't support e.g. Russian or Polish on-device).
public struct RoutingRules: Sendable {
    /// Whether the on-device model officially supports a language.
    public var supportsLanguage: @Sendable (Locale.LanguageCode) -> Bool
    public var onDeviceContextSize: Int

    public init(supportsLanguage: @escaping @Sendable (Locale.LanguageCode) -> Bool, onDeviceContextSize: Int) {
        self.supportsLanguage = supportsLanguage
        self.onDeviceContextSize = onDeviceContextSize
    }

    public func evaluate(_ context: RouteContext) -> RouteDecision? {
        switch context.mode {
        case .onDevice:
            return .onDevice(.userSelectedOnDevice)
        case .cloud:
            return .cloud(.userSelectedCloud)
        case .auto:
            break
        }

        guard context.onDeviceUsable else { return .cloud(.onDeviceUnavailable) }

        let message = context.message
        if context.hasUnsupportedAttachment {
            return .cloud(.unsupportedAttachment)
        }
        if let language = Self.dominantLanguage(of: message.content), !supportsLanguage(language) {
            return .cloud(.unsupportedLanguage)
        }
        if estimatedTokens(of: message) > onDeviceContextSize / 2 {
            return .cloud(.longInput)
        }
        if message.attachments.isEmpty && Self.isSmallTalk(message.content) {
            return .onDevice(.smallTalk)
        }
        return nil
    }

    /// Text and text files by size; images and binary files at a flat rate (their bytes say nothing
    /// about token cost).
    private func estimatedTokens(of message: Message) -> Int {
        let textBytes = message.attachments.filter(Self.isTextDocument).reduce(0) { $0 + $1.size }
        let otherCount = message.attachments.count { !Self.isTextDocument($0) }
        return (message.content.utf8.count + textBytes) / 3 + otherCount * AppleOnDeviceBackend.estimatedTokensPerImage
    }

    /// `nil` when the text is too short to tell reliably.
    static func dominantLanguage(of text: String) -> Locale.LanguageCode? {
        guard text.count >= 20 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return Locale.LanguageCode(language.rawValue)
    }

    /// Whether a cloud model with `capabilities` can take all of the message's attachments.
    static func accepts(_ message: Message, _ capabilities: ProviderCapabilities) -> Bool {
        message.attachments.allSatisfy { attachment in
            if attachment.kind == .image { return capabilities.supportsImages }
            return isTextDocument(attachment) || capabilities.supportsFileParts
        }
    }

    static func isTextDocument(_ attachment: Artemis.Attachment) -> Bool {
        guard attachment.kind == .document, let type = UTType(mimeType: attachment.mime) else { return false }
        return type.conforms(to: .text) || type.conforms(to: .json)
    }

    /// Greetings and acknowledgements: a few words, no question, no numbers.
    static func isSmallTalk(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        return !words.isEmpty && words.count <= 4 && !trimmed.contains("?")
            && !trimmed.contains(where: \.isNumber) && trimmed.count <= 40
    }
}

// MARK: - Classifier

/// Request categories the on-device model can tell apart reliably.
@Generable
enum RequestCategory {
    case smallTalk
    case simpleQuestion
    case writing
    case deviceAction
    case personalData
    case contacts
    case alarm
    case weather
    case places
    case health
    case math
    case freshInformation
    case complexReasoning
    case code
    case longForm
}

@Generable
struct RouteVerdict {
    @Guide(description: "The single category that best describes the user's latest request")
    var category: RequestCategory
}

enum RequestClassifier {
    static let timeout: Duration = .seconds(4)

    private static let logger = Logger(subsystem: "com.artemis.ios", category: "RequestClassifier")

    static let instructions = """
        Classify the user's latest request into exactly one category:
        - smallTalk: greetings, thanks, chit-chat.
        - simpleQuestion: a short factual or everyday question with a well-known, stable answer.
        - writing: rewrite, summarize, translate between common languages, fix grammar, or draft a short text the user provides context for.
        - personalData: about the user's own schedule, calendar events, meetings, plans or reminders/to-dos, \
        including adding an event or a reminder.
        - contacts: about a person in the user's contacts (phone, email, birthday, address), or calling, \
        texting or emailing someone.
        - alarm: set an alarm or a timer.
        - weather: the weather or forecast, here or in a named place.
        - places: the user's current location, or finding places such as shops or restaurants nearby or in a named place.
        - health: the user's own steps, sleep, heart rate, workouts, weight or other activity and health data.
        - deviceAction: asks to change a device setting or control another app.
        - math: any calculation, unit conversion with numbers, percentages, equations or word problems.
        - freshInformation: needs the internet or current data: news, prices, scores, recent events, a specific website.
        - complexReasoning: multi-step math, logic puzzles, planning, careful analysis or comparison of options.
        - code: writing, explaining or debugging code, or technical configuration.
        - longForm: a long, detailed or expert-level answer such as an essay, report or in-depth explanation.

        Examples:
        "thanks, that helps" -> smallTalk
        "how many legs does a spider have" -> simpleQuestion
        "make this email sound more polite: ..." -> writing
        "what do I have tomorrow" -> personalData
        "remind me to buy milk at 6pm" -> personalData
        "when is Anna's birthday" -> contacts
        "text Mike that I'm running late" -> contacts
        "wake me up at 7" -> alarm
        "set a timer for 10 minutes" -> alarm
        "what's the weather in Warsaw tomorrow" -> weather
        "do I need an umbrella today" -> weather
        "where am I" -> places
        "find a pharmacy nearby" -> places
        "how did I sleep this week" -> health
        "how many steps did I walk yesterday" -> health
        "turn on dark mode" -> deviceAction
        "what is 17% of 2,340" -> math
        "who won the match yesterday" -> freshInformation
        "if a train leaves at 3pm at 80 km/h and another at 4pm at 100 km/h, when does the second catch up" -> complexReasoning
        "what's in this photo (the user attached an image)" -> simpleQuestion
        "translate the text in this picture to English (the user attached an image)" -> writing
        "summarize this document (the user attached a file)" -> writing
        "write a Swift function that parses ISO dates" -> code
        "explain the causes of World War I in detail" -> longForm
        """

    /// Falls back to the on-device model if classification fails or times out: if the request
    /// is beyond it, its own failure escalates later.
    static func classify(_ context: RouteContext) async -> RouteDecision {
        do {
            let category = try await withTimeout(timeout) {
                try await category(for: context)
            }
            return decision(for: category, availableTools: context.availableTools)
        } catch {
            logger.error("Classification failed: \(error.localizedDescription, privacy: .public)")
            return .onDevice(.simple)
        }
    }

    /// Requests for switched-off tools: weather and places can still be answered from the web;
    /// personal data can't, so the on-device model explains that.
    static func decision(for category: RequestCategory, availableTools: Set<ToolGroup>) -> RouteDecision {
        func tool(_ group: ToolGroup, _ reason: RouteReason, otherwise fallback: RouteDecision) -> RouteDecision {
            availableTools.contains(group) ? .onDevice(reason) : fallback
        }
        return switch category {
        case .smallTalk: .onDevice(.smallTalk)
        case .simpleQuestion: .onDevice(.simple)
        case .writing: .onDevice(.writing)
        case .deviceAction: .onDevice(.deviceAction)
        case .personalData: tool(.schedule, .personalData, otherwise: .onDevice(.deviceAction))
        case .contacts: tool(.contacts, .contacts, otherwise: .onDevice(.deviceAction))
        case .alarm: tool(.alarms, .alarm, otherwise: .onDevice(.deviceAction))
        case .health: tool(.health, .health, otherwise: .onDevice(.deviceAction))
        case .weather: tool(.weather, .weather, otherwise: .cloud(.freshInformation))
        case .places: tool(.places, .places, otherwise: .cloud(.freshInformation))
        case .math: .cloud(.math)
        case .freshInformation: .cloud(.freshInformation)
        case .complexReasoning: .cloud(.complexReasoning)
        case .code: .cloud(.code)
        case .longForm: .cloud(.longForm)
        }
    }

    private static func category(for context: RouteContext) async throws -> RequestCategory {
        var prompt = ""
        let previous = context.recentHistory.suffix(2).filter { !$0.content.isEmpty }
        if !previous.isEmpty {
            prompt += "Earlier in the conversation:\n"
            for message in previous {
                prompt += "\(message.role == .user ? "User" : "Assistant"): \(message.content.prefix(300))\n"
            }
            prompt += "\n"
        }
        prompt += "Latest request: \(context.message.content.prefix(1000))"
        for attachment in context.message.attachments {
            prompt += "\n(The user attached \(attachment.kind == .image ? "an image" : "a file"): \(attachment.filename))"
        }

        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: prompt,
            generating: RouteVerdict.self,
            options: GenerationOptions(samplingMode: .greedy)
        )
        return response.content.category
    }

    static func withTimeout<T: Sendable>(
        _ duration: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw CancellationError()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }
}

// MARK: - Refusal detection

@Generable
struct RefusalVerdict {
    @Guide(description: "true only if the reply declines the request instead of answering it")
    var isRefusal: Bool
}

/// Plain-text refusals ("I can't help with that") don't throw, so Apple suggests a second
/// session that classifies the reply.
enum RefusalDetector {
    /// Refusals are short; long replies are answers, and checking them would only add latency.
    static let maxCheckedLength = 600

    private static let instructions = """
        You check an assistant's reply. Decide whether it declines or refuses the user's request \
        instead of answering it, for example "I can't help with that" or "I don't have access to that \
        information". A reply that answers, even partially or with a caveat, is not a refusal.
        """

    static func isRefusal(_ reply: String) async -> Bool {
        let reply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty, reply.count <= maxCheckedLength else { return false }
        do {
            return try await RequestClassifier.withTimeout(.seconds(3)) {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(
                    to: "Reply:\n\"\"\"\n\(reply)\n\"\"\"",
                    generating: RefusalVerdict.self,
                    options: GenerationOptions(samplingMode: .greedy)
                )
                return response.content.isRefusal
            }
        } catch {
            return false
        }
    }
}

// MARK: - Cloud policy

/// How the cloud policy affects an Auto decision.
public enum PolicyOutcome: Equatable, Sendable {
    /// Use the decision as is.
    case proceed(RouteDecision)
    /// The cloud is needed but the user has to approve it first.
    case needsConsent(RouteReason)
    /// The cloud is denied: answer on-device anyway, remembering why the cloud was preferred.
    case keepOnDevice(RouteReason)
}

extension CloudPolicy {
    /// Explicit modes (On-device / Cloud) are the user's own choice and bypass the policy.
    public func apply(to decision: RouteDecision, mode: RoutingMode, chatAllowsCloud: Bool) -> PolicyOutcome {
        guard mode == .auto, decision.backend == .cloud else { return .proceed(decision) }
        switch self {
        case .alwaysAllow:
            return .proceed(decision)
        case .alwaysAsk:
            return chatAllowsCloud ? .proceed(decision) : .needsConsent(decision.reason)
        case .deny:
            return .keepOnDevice(decision.reason)
        }
    }
}
