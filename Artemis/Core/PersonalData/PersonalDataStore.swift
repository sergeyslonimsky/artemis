import EventKit
import Foundation

/// Calendar and Reminders through EventKit. Reads feed the on-device model's tools; writes happen
/// only when the user confirms a draft.
public actor PersonalDataStore {
    public static let shared = PersonalDataStore()

    public struct EventSummary: Sendable {
        public var title: String
        public var start: Date
        public var end: Date
        public var isAllDay: Bool
        public var calendar: String
        public var location: String?
    }

    public struct ReminderSummary: Sendable {
        public var title: String
        public var due: Date?
        public var dueHasTime: Bool
        public var list: String
    }

    public enum StoreError: LocalizedError {
        case accessDenied(PersonalDataSource)

        public var errorDescription: String? {
            switch self {
            case .accessDenied(.calendar):
                "Artemis doesn't have access to your calendar. You can allow it in Settings › Privacy & Security › Calendars."
            case .accessDenied(.reminders):
                "Artemis doesn't have access to your reminders. You can allow it in Settings › Privacy & Security › Reminders."
            }
        }
    }

    private let store = EKEventStore()

    // MARK: - Access

    /// Asks for full access the first time; afterwards reports the current state.
    public func requestAccess(to source: PersonalDataSource) async -> Bool {
        let entityType: EKEntityType = source == .calendar ? .event : .reminder
        switch EKEventStore.authorizationStatus(for: entityType) {
        case .fullAccess:
            return true
        case .notDetermined:
            do {
                return source == .calendar
                    ? try await store.requestFullAccessToEvents()
                    : try await store.requestFullAccessToReminders()
            } catch {
                return false
            }
        default:
            return false
        }
    }

    // MARK: - Reads

    public func events(from start: Date, days: Int) async throws -> [EventSummary] {
        guard await requestAccess(to: .calendar) else { throw StoreError.accessDenied(.calendar) }
        let end = Calendar.current.date(byAdding: .day, value: days, to: start) ?? start
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                EventSummary(
                    title: event.title ?? "Untitled",
                    start: event.startDate,
                    end: event.endDate,
                    isAllDay: event.isAllDay,
                    calendar: event.calendar?.title ?? "",
                    location: event.location?.isEmpty == false ? event.location : nil
                )
            }
    }

    /// Open reminders; `dueWithin` limits them to those due in the next N days (overdue included).
    public func openReminders(dueWithin days: Int?) async throws -> [ReminderSummary] {
        guard await requestAccess(to: .reminders) else { throw StoreError.accessDenied(.reminders) }
        let end = days.flatMap { Calendar.current.date(byAdding: .day, value: $0, to: Calendar.current.startOfDay(for: Date())) }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: end, calendars: nil)

        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let summaries = (reminders ?? []).map { reminder in
                    ReminderSummary(
                        title: reminder.title ?? "Untitled",
                        due: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                        dueHasTime: reminder.dueDateComponents?.hour != nil,
                        list: reminder.calendar?.title ?? ""
                    )
                }
                continuation.resume(returning: summaries.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) })
            }
        }
    }

    // MARK: - Writes (user-confirmed drafts only)

    public func save(_ draft: ActionDraft) async throws {
        switch draft.kind {
        case .event:
            guard await requestAccess(to: .calendar) else { throw StoreError.accessDenied(.calendar) }
            let event = EKEvent(eventStore: store)
            event.title = draft.title
            event.calendar = store.defaultCalendarForNewEvents
            if draft.hasTime {
                event.startDate = draft.date
                event.endDate = draft.date.addingTimeInterval(TimeInterval(max(draft.durationMinutes, 15) * 60))
            } else {
                event.isAllDay = true
                event.startDate = Calendar.current.startOfDay(for: draft.date)
                event.endDate = event.startDate
            }
            try store.save(event, span: .thisEvent)

        case .reminder:
            guard await requestAccess(to: .reminders) else { throw StoreError.accessDenied(.reminders) }
            let reminder = EKReminder(eventStore: store)
            reminder.title = draft.title
            reminder.calendar = store.defaultCalendarForNewReminders()
            let components: Set<Calendar.Component> = draft.hasTime
                ? [.year, .month, .day, .hour, .minute]
                : [.year, .month, .day]
            reminder.dueDateComponents = Calendar.current.dateComponents(components, from: draft.date)
            if draft.hasTime {
                reminder.addAlarm(EKAlarm(absoluteDate: draft.date))
            }
            try store.save(reminder, commit: true)
        }
    }
}
