import Foundation
@preconcurrency import MessageUI
import UIKit

/// A system screen that finishes a drafted action: the message or mail composer, or the
/// calendar's event editor. The draft counts as done only if the user sends or saves there.
struct DraftSheet: Identifiable, Equatable {
    enum Kind: Equatable {
        case compose
        case editEvent
    }

    let kind: Kind
    let draft: ActionDraft
    /// The message the draft card belongs to.
    let messageId: String

    var id: String { draft.id }
}

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

    enum Outcome {
        /// Carried out (or dismissed) and recorded.
        case done
        /// The user finishes it in a system screen; record the result with `finish(_:sent:)`.
        case needsSheet(DraftSheet)
    }

    /// Confirms or dismisses a draft shown under `messageId` and records the outcome. Messages and
    /// emails open the system composer when the device has one, so they are sent from the app.
    static func resolve(
        _ draft: ActionDraft,
        messageId: String,
        confirm: Bool,
        database: AppDatabase = .shared
    ) async throws -> Outcome {
        guard confirm else {
            try database.setDraftStatus(messageId: messageId, draftId: draft.id, status: .dismissed)
            return .done
        }
        if canCompose(draft.kind) {
            return .needsSheet(DraftSheet(kind: .compose, draft: draft, messageId: messageId))
        }
        try await perform(draft)
        try database.setDraftStatus(messageId: messageId, draftId: draft.id, status: .added)
        return .done
    }

    /// Records the result of a system composer or editor; cancelling leaves the draft pending.
    static func finish(_ sheet: DraftSheet, completed: Bool, database: AppDatabase = .shared) throws {
        guard completed else { return }
        try database.setDraftStatus(messageId: sheet.messageId, draftId: sheet.draft.id, status: .added)
    }

    private static func canCompose(_ kind: ActionDraft.Kind) -> Bool {
        switch kind {
        case .message: MFMessageComposeViewController.canSendText()
        case .email: MFMailComposeViewController.canSendMail()
        default: false
        }
    }

    /// What to say once a draft is confirmed (voice mode).
    static func confirmation(for draft: ActionDraft) -> String {
        switch draft.kind {
        case .event: "Added \(draft.title) to your calendar."
        case .reminder: "Reminder added."
        case .alarm: "Alarm set for \(draft.date.formatted(date: .omitted, time: .shortened))."
        case .timer: "Timer started."
        case .call: "Calling \(draft.title)."
        case .message, .email: "Here's the message to \(draft.title). Tap Send when it's ready."
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
            var components = URLComponents()
            components.scheme = "mailto"
            components.path = address
            if let text = draft.body, !text.isEmpty {
                components.queryItems = [URLQueryItem(name: "body", value: text)]
            }
            return components.url
        default:
            return nil
        }
    }

    private static func phoneDigits(_ number: String) -> String {
        number.filter { $0.isNumber || $0 == "+" }
    }
}
