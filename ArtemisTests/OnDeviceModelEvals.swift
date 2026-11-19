import Foundation
import FoundationModels
import Testing
import Translation
@testable import Artemis

/// Runs requests the way the app does — the router (with its translation of other languages),
/// then the on-device backend — and checks the route and which tools the model calls. The tools
/// are stubs with canned outputs: only the model's choices are under test.
///
/// The model isn't deterministic across OS versions, so these are opt-in:
/// `TEST_RUNNER_RUN_MODEL_EVALS=1 xcodebuild test -only-testing:ArtemisTests/OnDeviceModelEvals …`
/// Every case prints its route, calls and reply; a failed expectation names the case.
@Suite("On-device model evals", .serialized, .enabled(if: modelEvalsEnabled))
struct OnDeviceModelEvals {
    struct Case: CustomTestStringConvertible, Sendable {
        var prompt: String
        /// Earlier turns, user and assistant alternating.
        var history: [String] = []
        /// Routes that give the model the tools it needs; a cloud route ends the case.
        var routes: Set<RouteReason>
        /// Tools that must be called, with argument fragments their JSON must contain (case-insensitive).
        var calls: [String: [String]] = [:]
        /// Tools that must not be called; `["*"]` for none at all.
        var forbidden: [String] = []

        var testDescription: String { prompt }
    }

    static let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        .formatted(.iso8601.year().month().day())

    static let cases: [Case] = [
        // Chat without tools.
        Case(prompt: "Hi there!", routes: [.smallTalk], forbidden: ["*"]),
        Case(prompt: "Thanks, that helps", routes: [.smallTalk], forbidden: ["*"]),
        Case(prompt: "How many legs does a spider have?", routes: [.simple], forbidden: ["*"]),
        Case(prompt: "How do I boil an egg so the yolk stays soft?", routes: [.simple], forbidden: ["*"]),
        Case(prompt: "Make this sound more polite: send me the report now", routes: [.writing], forbidden: ["*"]),
        Case(prompt: "Translate \"good morning, how are you?\" into German", routes: [.translation], calls: ["translate": ["german"]]),
        Case(prompt: "Turn on dark mode", routes: [.deviceAction], forbidden: ["*"]),

        // Cloud: the on-device model isn't asked.
        Case(prompt: "What is 17% of 2,340?", routes: [.math]),
        Case(prompt: "Who won the Champions League final yesterday?", routes: [.freshInformation]),
        Case(prompt: "Write a Python script that renames all files in a folder to lowercase", routes: [.code]),
        Case(prompt: "Explain the causes of World War I in detail", routes: [.longForm]),

        // Calendar and reminders.
        Case(prompt: "What do I have tomorrow?", routes: [.personalData], calls: ["getCalendarEvents": [tomorrow]]),
        Case(prompt: "Am I free on Friday afternoon?", routes: [.personalData], calls: ["getCalendarEvents": []],
             forbidden: ["draftEventOrReminder"]),
        Case(prompt: "What's my next meeting?", routes: [.personalData], calls: ["getCalendarEvents": []]),
        Case(prompt: "Add a dentist appointment on Monday at 10am", routes: [.personalData],
             calls: ["draftEventOrReminder": ["dentist", "10:00"]]),
        Case(prompt: "Remind me to call mom tomorrow at 9", routes: [.personalData],
             calls: ["draftEventOrReminder": ["mom", "09:00", "reminder"]], forbidden: ["draftContactAction"]),
        Case(prompt: "What's on my to-do list?", routes: [.personalData], calls: ["getReminders": []]),

        // Contacts.
        Case(prompt: "What's Anna's phone number?", routes: [.contacts], calls: ["findContact": ["anna"]]),
        Case(prompt: "Text Mike that I'm running late", routes: [.contacts], calls: ["draftContactAction": ["mike", "late"]]),
        Case(prompt: "Call mom", routes: [.contacts], calls: ["draftContactAction": ["mom", "call"]]),
        Case(prompt: "When is Anna's birthday?", routes: [.contacts], calls: ["findContact": ["anna"]]),

        // Alarms and timers.
        Case(prompt: "Wake me up at 7", routes: [.alarm], calls: ["draftAlarm": ["07:00"]], forbidden: ["getTravelTime"]),
        Case(prompt: "Set an alarm for 6:30 tomorrow", routes: [.alarm], calls: ["draftAlarm": ["\(tomorrow)T06:30"]]),
        Case(prompt: "Set a timer for 10 minutes", routes: [.alarm], calls: ["draftAlarm": ["timer", "10"]]),
        Case(prompt: "What alarms do I have?", routes: [.alarm], calls: ["getAlarms": []], forbidden: ["draftAlarm"]),

        // Weather.
        Case(prompt: "Do I need an umbrella today?", routes: [.weather], calls: ["getWeather": []]),
        Case(prompt: "What's the weather in Paris tomorrow?", routes: [.weather], calls: ["getWeather": ["paris"]]),
        Case(prompt: "Should I take a jacket today?", routes: [.weather], calls: ["getWeather": []]),
        Case(prompt: "Will it be warmer at the weekend?", routes: [.weather], calls: ["getWeather": []]),

        // Places.
        Case(prompt: "Where am I?", routes: [.places], calls: ["getCurrentLocation": []], forbidden: ["getTravelTime"]),
        Case(prompt: "Find a pharmacy nearby", routes: [.places], calls: ["searchPlaces": ["pharmacy"]]),
        Case(prompt: "I'm hungry, any ideas for food nearby?", routes: [.places], calls: ["searchPlaces": []]),
        Case(prompt: "Is there a good coffee place near work?", routes: [.places], calls: ["searchPlaces": ["coffee", "work"]]),

        // Travel: no alarm unless asked, no invented arrival time.
        Case(prompt: "How long does it take to get from home to work by public transport?", routes: [.travel],
             calls: ["getTravelTime": ["work", "transit", "\"arriveBy\": \"\""]], forbidden: ["draftAlarm"]),
        Case(prompt: "Could you check how long to reach from home to work today? On public transport", routes: [.travel],
             calls: ["getTravelTime": ["work", "transit", "\"arriveBy\": \"\""]], forbidden: ["draftAlarm"]),
        Case(prompt: "How long does it take to drive to work?", routes: [.travel],
             calls: ["getTravelTime": ["work", "driving", "\"arriveBy\": \"\""]], forbidden: ["draftAlarm"]),
        Case(prompt: "How long is my commute?", routes: [.travel], calls: ["getTravelTime": ["work"]], forbidden: ["draftAlarm"]),
        // Places also have getTravelTime.
        Case(prompt: "How long is the walk from home to the gym?", routes: [.travel, .places],
             calls: ["getTravelTime": ["gym", "walking"]], forbidden: ["draftAlarm"]),
        Case(prompt: "How far is the airport?", routes: [.travel, .places], calls: ["getTravelTime": ["airport"]]),
        Case(prompt: "When should I leave for my next meeting?", routes: [.travel],
             calls: ["getTravelTime": ["nextEvent"]], forbidden: ["draftAlarm"]),
        Case(prompt: "I need to be at the airport by 18:00, when do I leave?", routes: [.travel],
             calls: ["getTravelTime": ["airport", "18:00"]], forbidden: ["draftAlarm"]),
        Case(prompt: "Set an alarm so I leave in time to get to work by 9am", routes: [.travelAlarm],
             calls: ["getTravelTime": ["work"], "draftAlarm": []]),

        // Health.
        Case(prompt: "How did I sleep last night?", routes: [.health], calls: ["getHealthData": ["sleep"]]),
        Case(prompt: "How many steps have I done today?", routes: [.health], calls: ["getHealthData": ["steps"]]),
        Case(prompt: "What was my resting heart rate this week?", routes: [.health], calls: ["getHealthData": ["heart"]]),

        // Follow-ups.
        Case(prompt: "And in London?",
             history: ["What's the weather in Paris tomorrow?", "Tomorrow in Paris: 12°C and cloudy."],
             routes: [.weather], calls: ["getWeather": ["london"]]),
        Case(prompt: "How long does it take to get to the training?",
             history: ["What do I have tomorrow?", "Tomorrow: Standup at 10:00, and Trening Cross at 17:30 at CrossFit Praga."],
             routes: [.travel, .places], calls: ["getTravelTime": []], forbidden: ["draftAlarm"]),
        Case(prompt: "Ok, set an alarm for 8:20 then",
             history: ["How long to get to work by bus?", "About 35 minutes by public transport."],
             routes: [.alarm, .travelAlarm], calls: ["draftAlarm": ["08:20"]]),
        Case(prompt: "At 6pm",
             history: ["Remind me to buy milk", "When would you like to be reminded?"],
             routes: [.personalData], calls: ["draftEventOrReminder": ["milk", "18:00"]]),

        // Russian: translated to English on the device, both ways.
        Case(prompt: "Привет! Как дела?", routes: [.smallTalk], forbidden: ["*"]),
        Case(prompt: "Сколько ехать от дома до работы на общественном транспорте?", routes: [.travel],
             calls: ["getTravelTime": ["work", "transit"]], forbidden: ["draftAlarm"]),
        Case(prompt: "Поставь будильник, чтобы я успел на работу к 9", routes: [.travelAlarm],
             calls: ["getTravelTime": ["work"], "draftAlarm": []]),
        Case(prompt: "Разбуди меня в 7 утра", routes: [.alarm], calls: ["draftAlarm": ["07:00"]]),
        Case(prompt: "Поставь таймер на 15 минут", routes: [.alarm], calls: ["draftAlarm": ["timer", "15"]]),
        Case(prompt: "Какая погода будет завтра?", routes: [.weather], calls: ["getWeather": []]),
        Case(prompt: "Нужен ли сегодня зонт?", routes: [.weather], calls: ["getWeather": []]),
        Case(prompt: "Что у меня завтра в календаре?", routes: [.personalData], calls: ["getCalendarEvents": [tomorrow]]),
        Case(prompt: "Напомни купить молоко в 18:00", routes: [.personalData], calls: ["draftEventOrReminder": ["milk", "18:00"]]),
        Case(prompt: "Где ближайшая аптека?", routes: [.places], calls: ["searchPlaces": ["pharmac"]]),
        Case(prompt: "Сколько шагов я прошёл сегодня?", routes: [.health], calls: ["getHealthData": ["steps"]]),
        Case(prompt: "Напиши Мише, что я опаздываю", routes: [.contacts], calls: ["draftContactAction": ["late"]]),
        Case(prompt: "Сколько будет 15% от 2400?", routes: [.math]),
    ]

    static let places = [
        SavedPlace(name: "Home", address: "Jana Nowaka-Jeziorańskiego 45, 03-982 Warszawa, Poland"),
        SavedPlace(name: "Work", address: "Towarowa 28, 00-847 Warszawa, Poland"),
        SavedPlace(name: "Gym", address: "Grochowska 207, 04-077 Warszawa, Poland"),
    ]

    /// Plausible tool outputs, so the model can finish its reply.
    static let outputs: [String: String] = [
        "getTravelTime": "The trip takes about 35 minutes, 9 km. Leaving now arrives around 11:05.\n"
            + "Tell the user how long the trip takes.",
        "getCurrentLocation": "The user is at Jana Nowaka-Jeziorańskiego 45, Warsaw, Poland.",
        "searchPlaces": "- Apteka Gemini, Grochowska 200 — 350 m\n- Bistro Praga, Grochowska 180 — 400 m",
        "getCalendarEvents": "- Standup, tomorrow 10:00–10:15\n- Trening Cross, tomorrow 17:30–18:30 at CrossFit Praga",
        "getReminders": "- Pay rent, due Friday\n- Buy a birthday present for Anna",
        "draftEventOrReminder": "The draft is ready. The user confirms it below your reply; it isn't added yet.",
        "findContact": "- Anna Kowalska: mobile +48 600 100 200, birthday March 14",
        "draftContactAction": "The draft is ready. The user confirms it below your reply; nothing is sent yet.",
        "draftAlarm": "The alarm is ready. The user confirms it below your reply; it isn't set yet.",
        "getAlarms": "- Wake up: alarm at tomorrow 07:00",
        "getWeather": "Now: 6°C, light rain. Today: 4–8°C, rain likely (80%). Tomorrow: 3–9°C, cloudy. "
            + "Saturday: 10–14°C, sunny.",
        "getHealthData": "Sleep last night: 7 h 10 min. Steps today: 6,240. Resting heart rate this week: 58 bpm on average.",
    ]

    @Test(arguments: cases)
    func model(_ evalCase: Case) async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.data(forKey: "savedPlaces")
        SavedPlaces.save(Self.places)
        defer { defaults.set(previous, forKey: "savedPlaces") }

        let chatId = "eval"
        let history = evalCase.history.enumerated().map { index, text in
            Message(chatId: chatId, seq: Int64(index), role: index.isMultiple(of: 2) ? .user : .assistant, content: text)
        }
        let message = Message(chatId: chatId, seq: Int64(history.count), role: .user, content: evalCase.prompt)
        let decision = await Router().route(RouteContext(
            message: message,
            recentHistory: history,
            mode: .auto,
            onDeviceUsable: true,
            hasCloud: true,
            availableTools: Set(ToolGroup.allCases)
        ))
        var report = "EVAL \(evalCase.prompt)\n  route: \(decision.backend.rawValue) \(decision.reason.rawValue)\n"
        defer { print(report) }
        #expect(evalCase.routes.contains(decision.reason), "\(evalCase.prompt): routed to \(decision.reason)")
        guard decision.backend == .onDevice else { return }

        var turn = ChatTurn(messages: history + [message])
        turn.toolGroups = decision.reason.toolGroups
        turn.offersTranslation = decision.reason == .translation
        let backend = AppleOnDeviceBackend { groups, sink in
            PersonalDataTools.tools(for: groups, sink: sink).map { Self.stub($0) }
        }
        var reply = ""
        var calls: [ToolCallRecord] = []
        do {
            for try await event in backend.stream(turn) {
                switch event {
                case .content(let delta): reply += delta
                case .toolCall(let call): calls.append(call)
                default: break
                }
            }
        } catch {
            report += "  error: \(error.localizedDescription)\n"
            Issue.record(error, "\(evalCase.prompt)")
            return
        }
        report += calls.map { "  \($0.name) \($0.arguments)\n" }.joined()
            + "  reply: \(reply.replacingOccurrences(of: "\n", with: " "))"

        for (name, fragments) in evalCase.calls {
            let matching = calls.filter { $0.name == name }
            #expect(!matching.isEmpty, "\(evalCase.prompt): \(name) wasn't called")
            for fragment in fragments {
                #expect(matching.contains { $0.arguments.localizedCaseInsensitiveContains(fragment) },
                        "\(evalCase.prompt): \(name) arguments lack \"\(fragment)\"")
            }
        }
        if evalCase.forbidden == ["*"] {
            #expect(calls.isEmpty, "\(evalCase.prompt): tools were called")
        }
        for name in evalCase.forbidden where name != "*" {
            #expect(!calls.contains { $0.name == name }, "\(evalCase.prompt): \(name) was called")
        }
        if evalCase.prompt.contains(where: \.isCyrillic) {
            let isRussian = reply.contains(where: \.isCyrillic)
            #expect(isRussian, "\(evalCase.prompt): the reply isn't in Russian")
        }
    }

    private static func stub<Base: Tool>(_ tool: Base) -> any Tool {
        StubTool(base: tool) { arguments in
            if let trip = arguments as? TravelTimeTool.Arguments { return travelOutput(trip) }
            return outputs[tool.name] ?? "Done."
        }
    }

    /// Like the real tool: a leave time when the user has to arrive by a time.
    private static func travelOutput(_ trip: TravelTimeTool.Arguments) -> String {
        guard let arrival = PersonalDataTools.parseDate(trip.arriveBy), arrival.hasTime else {
            return outputs["getTravelTime"]!
        }
        let leave = arrival.date.addingTimeInterval(-35 * 60)
        return "The trip takes about 35 minutes, 9 km.\nTo arrive by \(arrival.date.formatted(date: .omitted, time: .shortened)), "
            + "leave at \(leave.formatted(date: .omitted, time: .shortened)); with a 5-minute margin, by "
            + "\(leave.addingTimeInterval(-300).formatted(date: .omitted, time: .shortened)).\nTell the user how long the trip takes."
    }

    @Test func findsTranslationLanguagesByName() async {
        let supported = await LanguageAvailability().supportedLanguages
        print("LANGUAGES \(supported.count): \(supported.map { "\($0.minimalIdentifier)=\($0.englishName)" }.joined(separator: ", "))")
        for name in ["German", "Spanish", "Russian", "de"] {
            print("LANGUAGE \(name) → \(String(describing: await TranslateTool.language(named: name)?.minimalIdentifier))")
        }
    }

    /// Apple's en→ru translation of short phrases like those in replies, to tell its mistakes
    /// from the model's.
    @Test func translatesShortRepliesIntoRussian() async throws {
        let translator = try #require(await OnDeviceTranslator.forText("Сколько ехать от дома до работы?"))
        for phrase in [
            "The alarm is ready. Please confirm it below.",
            "Alarm set for 7:00.",
            "The draft is ready.",
            "I'm running late",
            "Pay rent",
            "Buy a birthday present for Anna",
            "It takes about 35 minutes by public transport. Leaving now arrives around 11:05.",
            "Your reminder to buy milk at 6 PM is ready.",
        ] {
            print("TRANSLATE \(phrase) → \(try await translator.fromEnglish(markdown: phrase))")
        }
    }
}

private var modelEvalsEnabled: Bool {
    ProcessInfo.processInfo.environment["RUN_MODEL_EVALS"] != nil && SystemLanguageModel.default.isAvailable
}

private extension Character {
    var isCyrillic: Bool {
        unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }
}

/// A tool as the model sees it, returning a canned output.
private struct StubTool<Base: Tool>: Tool {
    let base: Base
    let output: @Sendable (Base.Arguments) -> String

    var name: String { base.name }
    var description: String { base.description }
    var parameters: GenerationSchema { base.parameters }

    func call(arguments: Base.Arguments) async throws -> String {
        output(arguments)
    }
}
