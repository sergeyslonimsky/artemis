import Foundation
import FoundationModels

/// What the tools report back to the app while the model runs.
enum ToolEvent: Sendable {
    case started(PersonalDataSource)
    case drafted(ActionDraft)
}

/// Routes tool events to the current turn. A cached session keeps its tools across turns,
/// so the handler is swapped per turn instead of being captured by the tools.
final class ToolEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (ToolEvent) -> Void)?

    func setHandler(_ handler: (@Sendable (ToolEvent) -> Void)?) {
        lock.withLock { self.handler = handler }
    }

    func send(_ event: ToolEvent) {
        let handler = lock.withLock { self.handler }
        handler?(event)
    }
}

enum PersonalDataTools {
    static func all(sink: ToolEventSink) -> [any Tool] {
        [CalendarEventsTool(sink: sink), RemindersTool(sink: sink), DraftEventOrReminderTool(sink: sink)]
    }

    /// Added to the instructions when the tools are on.
    static let instructions = """
        You can look up the user's calendar events and open reminders with your tools; use them whenever \
        the user asks about their schedule, plans or to-dos. You can't save anything yourself: to add an \
        event or a reminder, call draftEventOrReminder, then tell the user to confirm it below your reply.
        """

    /// Parses `YYYY-MM-DD` or `YYYY-MM-DDTHH:MM` in the user's time zone.
    static func parseDate(_ text: String) -> (date: Date, hasTime: Bool)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        // Prefix lengths drop trailing seconds or zones the model may add ("…T15:00:00Z").
        let formats: [(format: String, length: Int, hasTime: Bool)] = [
            ("yyyy-MM-dd'T'HH:mm", 16, true),
            ("yyyy-MM-dd HH:mm", 16, true),
            ("yyyy-MM-dd", 10, false),
        ]
        for candidate in formats {
            formatter.dateFormat = candidate.format
            if let date = formatter.date(from: String(trimmed.prefix(candidate.length))) {
                return (date, candidate.hasTime)
            }
        }
        return nil
    }

    static func describe(_ date: Date, withTime: Bool) -> String {
        withTime
            ? date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
            : date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

// MARK: - Calendar

struct CalendarEventsTool: Tool {
    let sink: ToolEventSink

    let name = "getCalendarEvents"
    let description = "Lists the user's calendar events for a range of days."

    @Generable
    struct Arguments {
        @Guide(description: "First day to list, as YYYY-MM-DD")
        var startDate: String
        @Guide(description: "Number of days to list, from 1 to 31")
        var days: Int
    }

    func call(arguments: Arguments) async throws -> String {
        sink.send(.started(.calendar))
        let start = PersonalDataTools.parseDate(arguments.startDate).map { Calendar.current.startOfDay(for: $0.date) }
            ?? Calendar.current.startOfDay(for: Date())
        let days = min(max(arguments.days, 1), 31)

        let events: [PersonalDataStore.EventSummary]
        do {
            events = try await PersonalDataStore.shared.events(from: start, days: days)
        } catch {
            return error.localizedDescription
        }
        guard !events.isEmpty else { return "No events in this period." }

        // Compact lines: tool output shares the small context window.
        let lines = events.prefix(30).map { event -> String in
            let when = event.isAllDay
                ? PersonalDataTools.describe(event.start, withTime: false) + ", all day"
                : PersonalDataTools.describe(event.start, withTime: true) + "–" + event.end.formatted(date: .omitted, time: .shortened)
            let location = event.location.map { " @ \($0)" } ?? ""
            return "- \(when): \(event.title)\(location)"
        }
        let more = events.count > 30 ? "\n…and \(events.count - 30) more." : ""
        return lines.joined(separator: "\n") + more
    }
}

// MARK: - Reminders

struct RemindersTool: Tool {
    let sink: ToolEventSink

    let name = "getReminders"
    let description = "Lists the user's open reminders (to-dos)."

    @Generable
    struct Arguments {
        @Guide(description: "Only reminders due within this many days from today, including overdue ones; 0 lists all open reminders")
        var withinDays: Int
    }

    func call(arguments: Arguments) async throws -> String {
        sink.send(.started(.reminders))
        let reminders: [PersonalDataStore.ReminderSummary]
        do {
            reminders = try await PersonalDataStore.shared.openReminders(dueWithin: arguments.withinDays > 0 ? arguments.withinDays : nil)
        } catch {
            return error.localizedDescription
        }
        guard !reminders.isEmpty else { return "No open reminders." }

        let lines = reminders.prefix(30).map { reminder -> String in
            let due = reminder.due.map { " (due \(PersonalDataTools.describe($0, withTime: reminder.dueHasTime)))" } ?? ""
            return "- \(reminder.title)\(due)"
        }
        let more = reminders.count > 30 ? "\n…and \(reminders.count - 30) more." : ""
        return lines.joined(separator: "\n") + more
    }
}

// MARK: - Drafts

struct DraftEventOrReminderTool: Tool {
    let sink: ToolEventSink

    let name = "draftEventOrReminder"
    let description = "Prepares a new calendar event or reminder for the user to confirm. Does not save it."

    @Generable
    enum DraftKind {
        case event
        case reminder
    }

    @Generable
    struct Arguments {
        var kind: DraftKind
        @Guide(description: "Short title, e.g. \"Dentist\" or \"Buy milk\"")
        var title: String
        @Guide(description: "Event start or reminder due time as YYYY-MM-DDTHH:MM in local time, or YYYY-MM-DD without a time")
        var date: String
        @Guide(description: "Event length in minutes; 0 for reminders or if unknown")
        var durationMinutes: Int
    }

    func call(arguments: Arguments) async throws -> String {
        guard let parsed = PersonalDataTools.parseDate(arguments.date) else {
            return "The date \(arguments.date) is not in the YYYY-MM-DD or YYYY-MM-DDTHH:MM format."
        }
        let kind: ActionDraft.Kind = arguments.kind == .event ? .event : .reminder
        let draft = ActionDraft(
            kind: kind,
            title: arguments.title,
            date: parsed.date,
            hasTime: parsed.hasTime,
            durationMinutes: kind == .event ? (arguments.durationMinutes > 0 ? arguments.durationMinutes : 60) : 0
        )
        sink.send(.drafted(draft))
        let what = kind == .event ? "Event" : "Reminder"
        return "\(what) \"\(draft.title)\" on \(PersonalDataTools.describe(draft.date, withTime: draft.hasTime)) is ready. The user confirms it below your reply; it is not saved yet."
    }
}
