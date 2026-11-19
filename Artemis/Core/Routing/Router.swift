import Foundation
import FoundationModels
import UniformTypeIdentifiers
import os

/// What the router knows about a turn.
struct RouteContext: Sendable {
    /// The user message being answered (attachment bytes not required).
    var message: Message
    /// A couple of preceding messages, so follow-ups ("and in Paris?") classify correctly.
    var recentHistory: [Message]
    var mode: RoutingMode
    var onDeviceUsable: Bool
    var hasCloud: Bool
    /// A non-text file the on-device model can't read (filled in by `Router`).
    var hasUnsupportedAttachment: Bool
    /// What the chat's cloud model accepts; `nil` when there's no cloud model.
    var cloudCapabilities: ProviderCapabilities?
    /// On-device tools switched on in the settings.
    var availableTools: Set<ToolGroup>

    init(
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
struct Router: Sendable {
    init() {}

    @concurrent
    func route(_ context: RouteContext) async -> RouteDecision {
        var context = context
        context.hasUnsupportedAttachment = await hasUnsupportedAttachment(context.message)
        let rules = RoutingRules(
            supportsLanguage: { OnDeviceModel.speaks(Locale.Language(languageCode: $0)) },
            onDeviceContextSize: SystemLanguageModel.default.contextSize
        )
        var decision: RouteDecision
        if let ruled = rules.evaluate(context) {
            decision = ruled
            if ruled.reason == .unsupportedLanguage {
                decision = await reconsiderLanguage(context, ruled: ruled)
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

    /// A language the on-device model doesn't support. When it is installed for translation, the
    /// on-device backend translates the turn, so the request is classified like an English one.
    /// Otherwise only a request about the user's own data stays: the cloud model can't see that data.
    private func reconsiderLanguage(_ context: RouteContext, ruled: RouteDecision) async -> RouteDecision {
        if let translator = await OnDeviceTranslator.forText(context.message.content),
           let english = try? await translator.toEnglish(context.message.content) {
            var translated = context
            translated.message.content = english
            return await RequestClassifier.classify(translated)
        }
        guard !context.availableTools.isEmpty else { return ruled }
        let classified = await RequestClassifier.classify(context)
        return classified.reason.toolGroups.isEmpty ? ruled : classified
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
struct RoutingRules: Sendable {
    /// Whether the on-device model officially supports a language.
    var supportsLanguage: @Sendable (Locale.LanguageCode) -> Bool
    var onDeviceContextSize: Int

    init(supportsLanguage: @escaping @Sendable (Locale.LanguageCode) -> Bool, onDeviceContextSize: Int) {
        self.supportsLanguage = supportsLanguage
        self.onDeviceContextSize = onDeviceContextSize
    }

    func evaluate(_ context: RouteContext) -> RouteDecision? {
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
        Locale.Language(detectedIn: text, minimumLength: 20)?.languageCode
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
}

// MARK: - Classifier

/// Request categories the on-device model can tell apart reliably.
@Generable
enum RequestCategory {
    case smallTalk
    case simpleQuestion
    case writing
    case translation
    case deviceAction
    case personalData
    case contacts
    case alarm
    case weather
    case places
    case travel
    case leaveAlarm
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
        - writing: rewrite, summarize, fix grammar, or draft a short text the user provides context for.
        - translation: translate text into another language.
        - personalData: about the user's own schedule, calendar events, meetings, plans or reminders/to-dos, \
        including adding an event or a reminder.
        - contacts: about a person in the user's contacts (phone, email, birthday, address), or calling, \
        texting or emailing someone.
        - alarm: set an alarm or a timer.
        - weather: the weather or forecast, here or in a named place.
        - places: the user's current location, or finding places such as shops or restaurants nearby or in a named place.
        - travel: how long it takes to get somewhere, directions, or when to leave to arrive on time.
        - leaveAlarm: an alarm or a reminder to leave in time to get somewhere.
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
        "how do I boil an egg" -> simpleQuestion
        "make this email sound more polite: ..." -> writing
        "translate \"see you tomorrow\" into Spanish" -> translation
        "what do I have tomorrow" -> personalData
        "remind me to buy milk at 6pm" -> personalData
        "remind me to call mom tomorrow" -> personalData
        "when is Anna's birthday" -> contacts
        "text Mike that I'm running late" -> contacts
        "call mom" -> contacts
        "wake me up at 7" -> alarm
        "set a timer for 10 minutes" -> alarm
        "what's the weather in Paris tomorrow" -> weather
        "do I need an umbrella today" -> weather
        "where am I" -> places
        "find a pharmacy nearby" -> places
        "how long does it take to drive to work" -> travel
        "how long from home to the office by bus" -> travel
        "when should I leave for my 3pm meeting" -> travel
        "set an alarm so I leave in time for my 3pm meeting" -> leaveAlarm
        "how did I sleep this week" -> health
        "how many steps did I walk yesterday" -> health
        "turn on dark mode" -> deviceAction
        "what is 17% of 2,340" -> math
        "who won the match yesterday" -> freshInformation
        "if a train leaves at 3pm at 80 km/h and another at 4pm at 100 km/h, when does the second catch up" -> complexReasoning
        "what's in this photo (the user attached an image)" -> simpleQuestion
        "translate the text in this picture to English (the user attached an image)" -> translation
        "summarize this document (the user attached a file)" -> writing
        "write a Swift function that parses ISO dates" -> code
        "write a script that renames my photos by date" -> code
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
        func tool(_ group: ToolGroup) -> RouteDecision {
            availableTools.contains(group) ? .onDevice(group.routeReason) : group.fallback
        }
        return switch category {
        case .smallTalk: .onDevice(.smallTalk)
        case .simpleQuestion: .onDevice(.simple)
        case .deviceAction: .onDevice(.deviceAction)
        case .personalData: tool(.schedule)
        case .contacts: tool(.contacts)
        case .alarm: tool(.alarms)
        case .health: tool(.health)
        case .weather: tool(.weather)
        case .places: tool(.places)
        case .travel: availableTools.contains(.places) ? .onDevice(.travel) : .cloud(.freshInformation)
        // Without location the leave time is unknown: a plain alarm is the best on-device answer.
        case .leaveAlarm: availableTools.contains(.places) ? .onDevice(.travelAlarm) : tool(.alarms)
        case .writing: .onDevice(.writing)
        case .translation: .onDevice(.translation)
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

extension ToolGroup {
    /// Why a request for this group's tools is answered on-device.
    var routeReason: RouteReason {
        switch self {
        case .schedule: .personalData
        case .contacts: .contacts
        case .alarms: .alarm
        case .weather: .weather
        case .places: .places
        case .health: .health
        }
    }

    /// Where such a request goes when the group is switched off: weather and places can be
    /// answered from the web; personal data can't, so the on-device model explains that.
    var fallback: RouteDecision {
        switch self {
        case .weather, .places: .cloud(.freshInformation)
        case .schedule, .contacts, .alarms, .health: .onDevice(.deviceAction)
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
enum PolicyOutcome: Equatable, Sendable {
    /// Use the decision as is.
    case proceed(RouteDecision)
    /// The cloud is needed but the user has to approve it first.
    case needsConsent(RouteReason)
    /// The cloud is denied: answer on-device anyway, remembering why the cloud was preferred.
    case keepOnDevice(RouteReason)
}

extension CloudPolicy {
    /// Explicit modes (On-device / Cloud) are the user's own choice and bypass the policy.
    func apply(to decision: RouteDecision, mode: RoutingMode, chatAllowsCloud: Bool) -> PolicyOutcome {
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
