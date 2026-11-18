import Foundation
import UIKit

/// Carries out a draft the user confirmed.
@MainActor
enum DraftPerformer {
    enum PerformError: LocalizedError {
        case cantOpen(ActionDraft.Kind)

        var errorDescription: String? {
            switch self {
            case .cantOpen(.call): "This device can't make phone calls."
            case .cantOpen(.email): "No email app is set up on this device."
            default: "This device can't send messages."
            }
        }
    }

    /// Confirms or dismisses a draft shown under `messageId` and records the outcome.
    static func resolve(_ draft: ActionDraft, messageId: String, confirm: Bool, database: AppDatabase = .shared) async throws {
        guard confirm else {
            try database.setDraftStatus(messageId: messageId, draftId: draft.id, status: .dismissed)
            return
        }
        try await perform(draft)
        try database.setDraftStatus(messageId: messageId, draftId: draft.id, status: .added)
    }

    /// What to say once a draft is confirmed (voice mode).
    static func confirmation(for draft: ActionDraft) -> String {
        switch draft.kind {
        case .event: "Added \(draft.title) to your calendar."
        case .reminder: "Reminder added."
        case .alarm: "Alarm set for \(draft.date.formatted(date: .omitted, time: .shortened))."
        case .timer: "Timer started."
        case .call: "Calling \(draft.title)."
        case .message, .email: "Opening the message to \(draft.title)."
        }
    }

    static func perform(_ draft: ActionDraft) async throws {
        switch draft.kind {
        case .event, .reminder:
            try await PersonalDataStore.shared.save(draft)
        case .alarm, .timer:
            try await AlarmScheduler.schedule(draft)
        case .call, .message, .email:
            guard let url = url(for: draft), await UIApplication.shared.open(url) else {
                throw PerformError.cantOpen(draft.kind)
            }
        }
    }

    /// Calls and messages hand off to the Phone and Messages apps, where the user sends them.
    static func url(for draft: ActionDraft) -> URL? {
        guard let address = draft.address else { return nil }
        let body = draft.body?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        switch draft.kind {
        case .call:
            return URL(string: "tel:\(phoneDigits(address))")
        case .message:
            return URL(string: "sms:\(phoneDigits(address))" + (body.isEmpty ? "" : "&body=\(body)"))
        case .email:
            let to = address.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? address
            return URL(string: "mailto:\(to)" + (body.isEmpty ? "" : "?body=\(body)"))
        default:
            return nil
        }
    }

    private static func phoneDigits(_ number: String) -> String {
        number.filter { $0.isNumber || $0 == "+" }
    }
}
