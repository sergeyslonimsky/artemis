import Foundation

// How model values read in the interface.

extension RoutingMode {
    var title: String {
        switch self {
        case .auto: "Auto"
        case .onDevice: "On-device"
        case .cloud: "Cloud"
        }
    }
}

extension CloudPolicy {
    var title: String {
        switch self {
        case .alwaysAsk: "Always ask"
        case .alwaysAllow: "Always allow"
        case .deny: "Never"
        }
    }

    /// Picker order: the default first, then from more to less cloud use.
    static let pickerOrder: [CloudPolicy] = [.alwaysAsk, .alwaysAllow, .deny]
}

/// "anthropic/claude-sonnet-4.5:free" → title "claude-sonnet-4.5", vendor "anthropic", free.
struct ModelName {
    let title: String
    let vendor: String?
    let isFree: Bool

    init(_ id: String) {
        var rest = id
        isFree = rest.hasSuffix(ProviderKind.freeModelSuffix)
        if isFree { rest.removeLast(ProviderKind.freeModelSuffix.count) }
        if let slash = rest.lastIndex(of: "/") {
            vendor = String(rest[..<slash])
            title = String(rest[rest.index(after: slash)...])
        } else {
            vendor = nil
            title = rest
        }
    }

    /// "OpenRouter · anthropic/claude-sonnet-4.5", or `nil` when neither is known.
    static func label(provider: String?, model: String?) -> String? {
        let parts = [provider, model].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

extension ActionDraft.Kind {
    var systemImage: String {
        switch self {
        case .event: "calendar.badge.plus"
        case .reminder: "checklist"
        case .alarm: "alarm"
        case .timer: "timer"
        case .call: "phone"
        case .message: "message"
        case .email: "envelope"
        }
    }

    var confirmTitle: String {
        switch self {
        case .event: "Add"
        case .reminder: "Remind"
        case .alarm, .timer: "Set"
        case .call: "Call"
        case .message, .email: "Write"
        }
    }

    var doneTitle: String {
        switch self {
        case .event, .reminder: "Added"
        case .alarm, .timer: "Set"
        case .call: "Called"
        case .message, .email: "Opened"
        }
    }

    var title: String {
        switch self {
        case .event: "Event"
        case .reminder: "Reminder"
        case .alarm: "Alarm"
        case .timer: "Timer"
        case .call: "Call"
        case .message: "Message"
        case .email: "Email"
        }
    }
}

extension ActionDraft {
    /// "Event · Tue 4 Mar, 15:00–16:00", "Alarm · Tomorrow, 07:00", "Call · +48 …".
    var detail: String {
        "\(kind.title) · \(when)"
    }

    private var when: String {
        switch kind {
        case .event where hasTime && durationMinutes > 0:
            let end = date.addingTimeInterval(TimeInterval(durationMinutes * 60))
            return (date..<end).formatted(date: .abbreviated, time: .shortened)
        case .event, .reminder:
            return hasTime
                ? date.formatted(date: .abbreviated, time: .shortened)
                : date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        case .alarm:
            let text = Self.relativeDayAndTime.string(from: date)
            // AlarmKit alarms ring like Clock alarms but aren't listed in the Clock app.
            return status == .added ? text + " · see Settings, not Clock" : text
        case .timer:
            return Duration.seconds(durationMinutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide))
        case .call, .message, .email:
            return address ?? ""
        }
    }

    /// "Today, 07:00" / "Tomorrow, 07:00" / "4 Mar 2026, 07:00".
    private static var relativeDayAndTime: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }
}
