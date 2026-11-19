import SwiftUI
import UIKit

/// The share extension's entry point: stages what was shared in the App Group, then opens the app
/// on it.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareView(
            model: model,
            onRequest: { [weak self] in self?.handOff($0) },
            onCancel: { [weak self] in self?.cancel() },
            onDone: { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        ))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        Task { await model.load(items) }
    }

    private func handOff(_ request: ShareRequest) {
        let url: URL
        do {
            url = try model.commit(request)
        } catch {
            model.markFailed(error)
            return
        }
        Task {
            if await openApp(url) {
                extensionContext?.completeRequest(returningItems: nil)
            } else {
                // The app picks the item up the next time it's opened.
                model.markSaved()
            }
        }
    }

    private func cancel() {
        model.discard()
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    /// The extension context's own `open` is documented for widgets and refuses in share
    /// extensions so far, but it's tried first in case that changes. Then the application object
    /// up the responder chain; if that ever stops working, the hand-off falls back to `markSaved`.
    private func openApp(_ url: URL) async -> Bool {
        if await extensionContext?.open(url) == true { return true }
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                return await application.open(url)
            }
            responder = current.next
        }
        return false
    }
}
