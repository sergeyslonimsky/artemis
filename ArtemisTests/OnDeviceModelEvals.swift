import Foundation
import FoundationModels
import Testing
@testable import Artemis

/// Runs requests through the real classifier and on-device model to check which tools the model
/// calls. The tools are stubs with canned outputs: only the model's choices are under test.
///
/// The model isn't deterministic across OS versions, so these are opt-in:
/// `TEST_RUNNER_RUN_MODEL_EVALS=1 xcodebuild test -only-testing:ArtemisTests/OnDeviceModelEvals …`
/// Every case runs and prints its calls; a failed expectation names the case.
@Suite("On-device model evals", .serialized, .enabled(if: modelEvalsEnabled))
struct OnDeviceModelEvals {
    struct Case: CustomTestStringConvertible, Sendable {
        var prompt: String
        /// Routes that give the model the tools it needs.
        var routes: Set<RouteReason>
        /// Tools that must be called, with argument fragments their JSON must contain (case-insensitive).
        var calls: [String: [String]] = [:]
        /// Tools that must not be called.
        var forbidden: [String] = []

        var testDescription: String { prompt }
    }

    static let cases: [Case] = [
        // Travel times: no alarm unless asked.
        Case(prompt: "How long does it take to get from home to work by public transport?", routes: [.travel],
             calls: ["getTravelTime": ["home", "work", "transit", "\"arriveBy\": \"\""]], forbidden: ["draftAlarm"]),
        Case(prompt: "Could you check how long to reach from home to work today? On public transport", routes: [.travel],
             calls: ["getTravelTime": ["work", "transit", "\"arriveBy\": \"\""]], forbidden: ["draftAlarm"]),
        Case(prompt: "How long does it take to drive to work?", routes: [.travel],
             calls: ["getTravelTime": ["work", "driving", "\"arriveBy\": \"\""]], forbidden: ["draftAlarm"]),
        // Places also have getTravelTime.
        Case(prompt: "How long is the walk from home to the gym?", routes: [.travel, .places],
             calls: ["getTravelTime": ["gym", "walking"]], forbidden: ["draftAlarm"]),
        Case(prompt: "When should I leave for my next meeting?", routes: [.travel],
             calls: ["getTravelTime": ["nextEvent"]], forbidden: ["draftAlarm"]),
        Case(prompt: "I need to be at the airport by 18:00, when do I leave?", routes: [.travel],
             calls: ["getTravelTime": ["airport", "18:00"]], forbidden: ["draftAlarm"]),
        // Alarms to leave.
        Case(prompt: "Set an alarm so I leave in time to get to work by 9am", routes: [.travelAlarm],
             calls: ["getTravelTime": ["work"], "draftAlarm": []]),
        // Neighbouring categories keep working.
        Case(prompt: "Wake me up at 7", routes: [.alarm], calls: ["draftAlarm": ["07:00"]], forbidden: ["getTravelTime"]),
        Case(prompt: "Set a timer for 10 minutes", routes: [.alarm], calls: ["draftAlarm": ["timer"]]),
        Case(prompt: "Where am I?", routes: [.places], calls: ["getCurrentLocation": []], forbidden: ["getTravelTime"]),
        Case(prompt: "Find a pharmacy nearby", routes: [.places], calls: ["searchPlaces": ["pharmacy"]]),
        Case(prompt: "What do I have tomorrow?", routes: [.personalData], calls: ["getCalendarEvents": []]),
        Case(prompt: "Remind me to buy milk at 6pm", routes: [.personalData], calls: ["draftEventOrReminder": ["milk"]]),
        Case(prompt: "Do I need an umbrella today?", routes: [.weather], calls: ["getWeather": []]),
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
        "searchPlaces": "- Apteka Gemini, Grochowska 200 — 350 m\n- Apteka DOZ, Ostrobramska 75 — 600 m",
        "getCalendarEvents": "- Standup, tomorrow 10:00–10:15\n- Trening Cross, tomorrow 17:30–18:30 at CrossFit Praga",
        "getReminders": "No open reminders.",
        "draftAlarm": "The alarm is ready. The user confirms it below your reply; it isn't set yet.",
        "getAlarms": "No alarms or timers set with Artemis.",
        "draftEventOrReminder": "The reminder is ready. The user confirms it below your reply; it isn't added yet.",
        "getWeather": "Warsaw now: 6°C, light rain. Today: 4–8°C, rain likely (80%).",
    ]

    @Test(arguments: cases)
    func model(_ evalCase: Case) async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.data(forKey: "savedPlaces")
        SavedPlaces.save(Self.places)
        defer { defaults.set(previous, forKey: "savedPlaces") }

        let message = Message(chatId: "eval", role: .user, content: evalCase.prompt)
        let decision = await RequestClassifier.classify(RouteContext(
            message: message,
            recentHistory: [],
            mode: .auto,
            onDeviceUsable: true,
            hasCloud: true,
            availableTools: Set(ToolGroup.allCases)
        ))
        #expect(evalCase.routes.contains(decision.reason), "\(evalCase.prompt): routed to \(decision.reason)")

        let groups = decision.reason.toolGroups
        let tools = PersonalDataTools.tools(for: groups, sink: ToolEventSink()).map { stub($0) }
        let session = LanguageModelSession(tools: tools, instructions: AppleOnDeviceBackend.baseInstructions(tools: groups))
        let response = try await session.respond(to: evalCase.prompt, options: GenerationOptions(samplingMode: .greedy))
        let calls = AppleOnDeviceBackend.toolCalls(in: ArraySlice(session.transcript))

        print("EVAL \(evalCase.prompt)\n  route: \(decision.reason.rawValue)\n"
            + calls.map { "  \($0.name) \($0.arguments)\n" }.joined()
            + "  reply: \(response.content.replacingOccurrences(of: "\n", with: " "))")

        for (name, fragments) in evalCase.calls {
            let matching = calls.filter { $0.name == name }
            #expect(!matching.isEmpty, "\(evalCase.prompt): \(name) wasn't called")
            for fragment in fragments {
                #expect(matching.contains { $0.arguments.localizedCaseInsensitiveContains(fragment) },
                        "\(evalCase.prompt): \(name) arguments lack \"\(fragment)\"")
            }
        }
        for name in evalCase.forbidden {
            #expect(!calls.contains { $0.name == name }, "\(evalCase.prompt): \(name) was called")
        }
    }

    private func stub<Base: Tool>(_ tool: Base) -> any Tool {
        StubTool(base: tool, output: Self.outputs[tool.name] ?? "Done.")
    }
}

private var modelEvalsEnabled: Bool {
    ProcessInfo.processInfo.environment["RUN_MODEL_EVALS"] != nil && SystemLanguageModel.default.isAvailable
}

/// A tool as the model sees it, returning a canned output.
private struct StubTool<Base: Tool>: Tool {
    let base: Base
    let output: String

    var name: String { base.name }
    var description: String { base.description }
    var parameters: GenerationSchema { base.parameters }

    func call(arguments: Base.Arguments) async throws -> String {
        output
    }
}
