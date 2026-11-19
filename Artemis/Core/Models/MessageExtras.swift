import Foundation

/// A source of device data the on-device model looked at.
enum PersonalDataSource: String, Codable, Sendable, CaseIterable {
    case calendar
    case reminders
    case contacts
    case location
    case weather
    case health
    /// Not the user's data, but reported the same way: the turn was translated on the device.
    case translation
    /// Only shown while the text in attached images is read before an on-device reply.
    case imageText

    /// Private sources keep the reply on the device: it isn't escalated or shown to the cloud.
    /// Weather for a named place says nothing about the user (their location is its own source).
    var isPrivate: Bool {
        self != .weather && self != .translation && self != .imageText
    }

    /// "Checked your calendar" — shown under the reply.
    var usedLabel: String {
        switch self {
        case .calendar: "Checked your calendar"
        case .reminders: "Checked your reminders"
        case .contacts: "Checked your contacts"
        case .location: "Used your location"
        case .weather: "Checked the weather"
        case .health: "Checked your health data"
        case .translation: "Translated on this device"
        case .imageText: "Read the text in an image"
        }
    }

    /// "Checking your calendar…" — shown while the tool runs.
    var activityLabel: String {
        switch self {
        case .calendar: "Checking your calendar…"
        case .reminders: "Checking your reminders…"
        case .contacts: "Checking your contacts…"
        case .location: "Finding your location…"
        case .weather: "Checking the weather…"
        case .health: "Checking your health data…"
        case .translation: "Translating…"
        case .imageText: "Reading the image…"
        }
    }

    var systemImage: String {
        switch self {
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .contacts: "person.crop.circle"
        case .location: "location"
        case .weather: "cloud.sun"
        case .health: "heart"
        case .translation: "translate"
        case .imageText: "text.viewfinder"
        }
    }
}

/// A set of on-device tools, switched on per turn by the request's category: the model's
/// context is small, so it only sees the tools the request may need.
enum ToolGroup: String, Codable, Sendable, CaseIterable, Identifiable {
    case schedule
    case contacts
    case alarms
    case weather
    case places
    case health

    var id: String { rawValue }

    var title: String {
        switch self {
        case .schedule: "Calendar & Reminders"
        case .contacts: "Contacts"
        case .alarms: "Alarms & Timers"
        case .weather: "Weather"
        case .places: "Location & Places"
        case .health: "Health"
        }
    }

    var systemImage: String {
        switch self {
        case .schedule: "calendar"
        case .contacts: "person.crop.circle"
        case .alarms: "alarm"
        case .weather: "cloud.sun"
        case .places: "location"
        case .health: "heart"
        }
    }

    var detail: String {
        switch self {
        case .schedule: "Read your events and reminders, and draft new ones."
        case .contacts: "Look up people and draft calls, messages and emails."
        case .alarms: "Draft alarms and timers."
        case .weather: "Current weather and forecast from Open-Meteo; only approximate coordinates are sent."
        case .places: "Your current location, places nearby and travel times."
        case .health: "Steps, sleep, heart rate, workouts and more."
        }
    }
}

/// An action the model proposed. Nothing happens until the user confirms it.
struct ActionDraft: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case event
        case reminder
        case alarm
        case timer
        case call
        case message
        case email
    }

    enum Status: String, Codable, Sendable {
        case pending
        case added
        case dismissed
    }

    var id: String
    var kind: Kind
    /// Event, reminder or alarm title; the contact's name for calls, messages and emails.
    var title: String
    /// Event start, reminder due date or alarm time; unused for timers and contact actions.
    var date: Date
    /// `false` for all-day events and reminders without a time.
    var hasTime: Bool
    /// Event or timer length; ignored for other kinds.
    var durationMinutes: Int
    /// Phone number or email address of a contact action.
    var address: String?
    /// Text of a message or email.
    var body: String?
    var status: Status

    init(
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

/// A tool the on-device model called, kept to see why a reply went wrong.
struct ToolCallRecord: Codable, Equatable, Sendable {
    var name: String
    /// The arguments as JSON.
    var arguments: String
    /// What the tool returned, shortened.
    var output: String

    static let maxOutputLength = 1000
}

/// Extra facts about an assistant reply, stored as JSON in `messages.extras`.
struct MessageExtras: Codable, Equatable, Sendable {
    var personalDataUsed: [PersonalDataSource] = []
    var drafts: [ActionDraft] = []
    var toolCalls: [ToolCallRecord] = []

    init(personalDataUsed: [PersonalDataSource] = [], drafts: [ActionDraft] = [], toolCalls: [ToolCallRecord] = []) {
        self.personalDataUsed = personalDataUsed
        self.drafts = drafts
        self.toolCalls = toolCalls
    }

    /// Replies stored before a field existed lack its key.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        personalDataUsed = try container.decodeIfPresent([PersonalDataSource].self, forKey: .personalDataUsed) ?? []
        drafts = try container.decodeIfPresent([ActionDraft].self, forKey: .drafts) ?? []
        toolCalls = try container.decodeIfPresent([ToolCallRecord].self, forKey: .toolCalls) ?? []
    }

    var isEmpty: Bool { personalDataUsed.isEmpty && drafts.isEmpty && toolCalls.isEmpty }

    /// Whether the reply was built from data that must stay on the device.
    var usedPrivateData: Bool { personalDataUsed.contains(where: \.isPrivate) }
}
