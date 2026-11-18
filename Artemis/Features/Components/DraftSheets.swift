import EventKit
import EventKitUI
@preconcurrency import MessageUI
import SwiftUI

/// Presents `sheet`'s system screen; `onFinish(true)` once the user sent or saved.
struct DraftSheetView: View {
    let sheet: DraftSheet
    let onFinish: (Bool) -> Void

    var body: some View {
        switch sheet.kind {
        case .compose:
            MessageComposer(draft: sheet.draft, onFinish: onFinish)
                .ignoresSafeArea()
        case .editEvent:
            EventEditor(draft: sheet.draft, onFinish: onFinish)
                .ignoresSafeArea()
        }
    }
}

// MARK: - Messages and Mail

/// The system message or mail composer, filled in from a draft; the user sends it themselves.
struct MessageComposer: UIViewControllerRepresentable {
    let draft: ActionDraft
    let onFinish: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        let recipients = draft.address.map { [$0] } ?? []
        let body = draft.body ?? ""
        if draft.kind == .email {
            let composer = MFMailComposeViewController()
            composer.setToRecipients(recipients)
            composer.setMessageBody(body, isHTML: false)
            composer.mailComposeDelegate = context.coordinator
            return composer
        }
        let composer = MFMessageComposeViewController()
        composer.recipients = recipients
        composer.body = body
        composer.messageComposeDelegate = context.coordinator
        return composer
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate, MFMailComposeViewControllerDelegate {
        let onFinish: (Bool) -> Void

        init(onFinish: @escaping (Bool) -> Void) {
            self.onFinish = onFinish
        }

        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            onFinish(result == .sent)
        }

        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: (any Error)?) {
            onFinish(result == .sent || result == .saved)
        }
    }
}

// MARK: - Calendar

/// The system event editor, filled in from a draft. Needs no calendar access: the user saves it.
struct EventEditor: UIViewControllerRepresentable {
    let draft: ActionDraft
    let onFinish: (Bool) -> Void

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = draft.title
        event.startDate = draft.date
        event.isAllDay = !draft.hasTime
        event.endDate = draft.date.addingTimeInterval(TimeInterval((draft.durationMinutes > 0 ? draft.durationMinutes : 60) * 60))

        let editor = EKEventEditViewController()
        editor.eventStore = store
        editor.event = event
        editor.editViewDelegate = context.coordinator
        return editor
    }

    func updateUIViewController(_ uiViewController: EKEventEditViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let onFinish: (Bool) -> Void

        init(onFinish: @escaping (Bool) -> Void) {
            self.onFinish = onFinish
        }

        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            onFinish(action == .saved)
        }
    }
}
