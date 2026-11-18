import Foundation

/// A personal-data source the on-device model looked at.
public enum PersonalDataSource: String, Codable, Sendable, CaseIterable {
    case calendar
    case reminders

    /// "Checked your calendar" — shown under the reply.
    public var usedLabel: String {
        switch self {
        case .calendar: "Checked your calendar"
        case .reminders: "Checked your reminders"
        }
    }

    /// "Checking your calendar…" — shown while the tool runs.
    public var activityLabel: String {
        switch self {
        case .calendar: "Checking your calendar…"
        case .reminders: "Checking your reminders…"
        }
    }

    public var systemImage: String {
        switch self {
        case .calendar: "calendar"
        case .reminders: "checklist"
        }
    }
}

/// An event or reminder the model proposed. Nothing is written until the user confirms it.
public struct ActionDraft: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case event
        case reminder
    }

    public enum Status: String, Codable, Sendable {
        case pending
        case added
        case dismissed
    }

    public var id: String
    public var kind: Kind
    public var title: String
    /// Event start or reminder due date.
    public var date: Date
    /// `false` for all-day events and reminders without a time.
    public var hasTime: Bool
    /// Event length; ignored for reminders.
    public var durationMinutes: Int
    public var status: Status

    public init(
        id: String = UUID().uuidString.lowercased(),
        kind: Kind,
        title: String,
        date: Date,
        hasTime: Bool,
        durationMinutes: Int,
        status: Status = .pending
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.date = date
        self.hasTime = hasTime
        self.durationMinutes = durationMinutes
        self.status = status
    }
}

/// Extra facts about an assistant reply, stored as JSON in `messages.extras`.
public struct MessageExtras: Codable, Equatable, Sendable {
    public var personalDataUsed: [PersonalDataSource] = []
    public var drafts: [ActionDraft] = []

    public init(personalDataUsed: [PersonalDataSource] = [], drafts: [ActionDraft] = []) {
        self.personalDataUsed = personalDataUsed
        self.drafts = drafts
    }

    public var isEmpty: Bool { personalDataUsed.isEmpty && drafts.isEmpty }
}
