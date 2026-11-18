import AlarmKit
import Foundation
import FoundationModels
import SwiftUI

struct DraftAlarmTool: Tool {
    let sink: ToolEventSink

    let name = "draftAlarm"
    let description = "Prepares an alarm at a time, or a countdown timer, for the user to confirm. Does not set it."

    @Generable
    enum AlarmKind {
        case alarm
        case timer
    }

    @Generable
    struct Arguments {
        var kind: AlarmKind
        @Guide(description: "Short label, e.g. \"Wake up\" or \"Pasta\"")
        var label: String
        @Guide(description: "Alarm time as YYYY-MM-DDTHH:MM in local time; empty for timers")
        var time: String
        @Guide(description: "Timer length in minutes; 0 for alarms")
        var minutes: Int
    }

    func call(arguments: Arguments) async throws -> String {
        let label = arguments.label.trimmingCharacters(in: .whitespacesAndNewlines)
        switch arguments.kind {
        case .timer:
            guard arguments.minutes > 0 else { return "A timer needs a length in minutes." }
            let draft = ActionDraft(kind: .timer, title: label.isEmpty ? "Timer" : label, durationMinutes: min(arguments.minutes, 24 * 60))
            sink.send(.drafted(draft))
            return "A \(draft.durationMinutes)-minute timer is ready. The user confirms it below your reply; it isn't running yet."
        case .alarm:
            guard let parsed = PersonalDataTools.parseDate(arguments.time), parsed.hasTime else {
                return "The time \(arguments.time) is not in the YYYY-MM-DDTHH:MM format."
            }
            // A time that already passed today most likely means tomorrow.
            var date = parsed.date
            if date < Date() { date = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date }
            let draft = ActionDraft(kind: .alarm, title: label.isEmpty ? "Alarm" : label, date: date)
            sink.send(.drafted(draft))
            return "An alarm for \(PersonalDataTools.describe(date, withTime: true)) is ready. The user confirms it below your reply; it isn't set yet."
        }
    }
}

/// Schedules confirmed alarms and timers with AlarmKit; they ring like Clock alarms, even in
/// Silent mode, and show on the Lock Screen.
@MainActor
enum AlarmScheduler {
    struct Metadata: AlarmMetadata {}

    enum SchedulerError: LocalizedError {
        case accessDenied

        var errorDescription: String? {
            "Artemis isn't allowed to set alarms. You can allow it in Settings › Apps › Artemis."
        }
    }

    static func schedule(_ draft: ActionDraft) async throws {
        let manager = AlarmManager.shared
        var state = manager.authorizationState
        if state == .notDetermined {
            state = try await manager.requestAuthorization()
        }
        guard state == .authorized else { throw SchedulerError.accessDenied }

        let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: draft.title))
        let attributes = AlarmAttributes<Metadata>(presentation: AlarmPresentation(alert: alert), tintColor: .accentColor)
        let configuration: AlarmManager.AlarmConfiguration<Metadata> = draft.kind == .timer
            ? .timer(duration: TimeInterval(draft.durationMinutes * 60), attributes: attributes)
            : .alarm(schedule: .fixed(draft.date), attributes: attributes)
        _ = try await manager.schedule(id: UUID(), configuration: configuration)
    }
}
