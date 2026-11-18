import Foundation

/// A source of device data the on-device model looked at.
public enum PersonalDataSource: String, Codable, Sendable, CaseIterable {
    case calendar
    case reminders
    case contacts
    case location
    case weather
    case health

    /// Private sources keep the reply on the device: it isn't escalated or shown to the cloud.
    /// Weather for a named place says nothing about the user (their location is its own source).
    public var isPrivate: Bool {
        self != .weather
    }

    /// "Checked your calendar" — shown under the reply.
    public var usedLabel: String {
        switch self {
        case .calendar: "Checked your calendar"
        case .reminders: "Checked your reminders"
        case .contacts: "Checked your contacts"
        case .location: "Used your location"
        case .weather: "Checked the weather"
        case .health: "Checked your health data"
        }
    }

    /// "Checking your calendar…" — shown while the tool runs.
    public var activityLabel: String {
        switch self {
        case .calendar: "Checking your calendar…"
        case .reminders: "Checking your reminders…"
        case .contacts: "Checking your contacts…"
        case .location: "Finding your location…"
        case .weather: "Checking the weather…"
        case .health: "Checking your health data…"
        }
    }

    public var systemImage: String {
        switch self {
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .contacts: "person.crop.circle"
        case .location: "location"
        case .weather: "cloud.sun"
        case .health: "heart"
        }
    }
}

/// A set of on-device tools, switched on per turn by the request's category: the model's
/// context is small, so it only sees the tools the request may need.
public enum ToolGroup: String, Codable, Sendable, CaseIterable, Identifiable {
    case schedule
    case contacts
    case alarms
    case weather
    case places
    case health

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .schedule: "Calendar & Reminders"
        case .contacts: "Contacts"
        case .alarms: "Alarms & Timers"
        case .weather: "Weather"
        case .places: "Location & Places"
        case .health: "Health"
        }
    }

    public var systemImage: String {
        switch self {
        case .schedule: "calendar"
        case .contacts: "person.crop.circle"
        case .alarms: "alarm"
        case .weather: "cloud.sun"
        case .places: "location"
        case .health: "heart"
        }
    }

    public var detail: String {
        switch self {
        case .schedule: "Read your events and reminders, and draft new ones."
        case .contacts: "Look up people and draft calls, messages and emails."
        case .alarms: "Draft alarms and timers."
        case .weather: "Current weather and forecast from Open-Meteo; only approximate coordinates are sent."
        case .places: "Your current location and places nearby."
        case .health: "Steps, sleep, heart rate, workouts and more."
        }
    }
}

/// An action the model proposed. Nothing happens until the user confirms it.
public struct ActionDraft: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case event
        case reminder
        case alarm
        case timer
        case call
        case message
        case email
    }

    public enum Status: String, Codable, Sendable {
        case pending
        case added
        case dismissed
    }

    public var id: String
    public var kind: Kind
    /// Event, reminder or alarm title; the contact's name for calls, messages and emails.
    public var title: String
    /// Event start, reminder due date or alarm time; unused for timers and contact actions.
    public var date: Date
    /// `false` for all-day events and reminders without a time.
    public var hasTime: Bool
    /// Event or timer length; ignored for other kinds.
    public var durationMinutes: Int
    /// Phone number or email address of a contact action.
    public var address: String?
    /// Text of a message or email.
    public var body: String?
    public var status: Status

    public init(
        id: String = UUID().uuidString.lowercased(),
        kind: Kind,
        title: String,
        date: Date = Date(),
        hasTime: Bool = true,
        durationMinutes: Int = 0,
        address: String? = nil,
        body: String? = nil,
        status: Status = .pending
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.date = date
        self.hasTime = hasTime
        self.durationMinutes = durationMinutes
        self.address = address
        self.body = body
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

    /// Whether the reply was built from data that must stay on the device.
    public var usedPrivateData: Bool { personalDataUsed.contains(where: \.isPrivate) }
}
