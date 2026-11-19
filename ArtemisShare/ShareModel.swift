import Foundation
import CoreTransferable
import Observation
import UIKit
import UniformTypeIdentifiers

/// A ready-made request for what was shared.
enum ShareAction: CaseIterable, Identifiable {
    case summarize
    case translate
    case addToCalendar

    var id: Self { self }

    var title: String {
        switch self {
        case .summarize: "Summarize"
        case .translate: "Translate to \(Locale.current.language.languageName)"
        case .addToCalendar: "Add Dates to Calendar"
        }
    }

    var systemImage: String {
        switch self {
        case .summarize: "text.append"
        case .translate: "translate"
        case .addToCalendar: "calendar.badge.plus"
        }
    }

    /// What the model is asked; in English like the app's own instructions.
    var prompt: String {
        switch self {
        case .summarize:
            return "Summarize this briefly."
        case .translate:
            return "Translate this into \(Locale.current.language.englishName)."
        case .addToCalendar:
            return "Find the events and dates in this and add them to my calendar."
        }
    }
}

/// What the user chose to do with the shared content.
enum ShareRequest {
    case action(ShareAction)
    case question(String)
    /// Only put it in a new chat's composer.
    case attachOnly
}

/// Reads what was shared into a staged inbox item, then completes it with the user's request.
@MainActor
@Observable
final class ShareModel {
    enum Phase: Equatable {
        case loading
        case ready
        case opening
        /// Handed off, but the app couldn't be opened from here.
        case saved
        case failed(String)
    }

    private(set) var phase = Phase.loading
    /// "Web page · Title", "2 images", "Text"…
    private(set) var summary = ""
    private(set) var summarySymbol = "square.and.arrow.down"
    var question = ""

    private var staged: (id: String, url: URL)?
    private var filenames: [String] = []
    private var texts: [String] = []
    private var pages: [WebPage] = []
    /// Links shared without their page (from apps other than Safari); they go into the prompt.
    private var links: [URL] = []
    private var fileCount = 0
    private var imageCount = 0

    /// Pages get this much text at most: enough for an article, not a whole site's markup.
    private static let maxPageCharacters = 100_000

    struct WebPage: Sendable {
        var url: URL?
        var title: String
        var text: String
    }

    // MARK: - Loading

    func load(_ items: [NSExtensionItem]) async {
        do {
            staged = try SharedInbox.makeFolder()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            do {
                try await load(provider)
            } catch {
                // Whatever else was shared still goes through.
                continue
            }
        }
        stageTexts()
        guard !filenames.isEmpty || !links.isEmpty else {
            phase = .failed("There's nothing Artemis can read in what was shared.")
            return
        }
        summarize()
        phase = .ready
    }

    private func load(_ provider: NSItemProvider) async throws {
        if provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier) {
            // Safari ran SafariPage.js: the page's own text.
            pages.append(try await provider.loadWebPage())
        } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                  !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url = try await provider.load(URL.self)
            if url.isFileURL {
                try copyFile(at: url)
            } else {
                links.append(url)
            }
        } else if !provider.registeredContentTypes.isEmpty,
                  provider.registeredContentTypes.allSatisfy({ $0.conforms(to: .text) }) {
            texts.append(try await provider.load(String.self))
        } else {
            try await loadFile(from: provider)
        }
    }

    private func loadFile(from provider: NSItemProvider) async throws {
        let type = provider.registeredContentTypes.first { $0.conforms(to: .data) } ?? .data
        let isImage = type.conforms(to: .image)
        do {
            let name = Self.filename(suggested: provider.suggestedName, type: type, fallback: isImage ? "Image" : "File")
            let destination = try freeURL(for: name)
            try await provider.copyFile(of: type, to: destination)
            filenames.append(destination.lastPathComponent)
        } catch where isImage {
            // Screenshots from the markup editor come only as an image object.
            let png = try await provider.loadImagePNG()
            try write(png, named: Self.filename(suggested: provider.suggestedName, type: .png, fallback: "Image"))
        }
        added(isImage: isImage)
    }

    private func copyFile(at url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let destination = try freeURL(for: url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: destination)
        filenames.append(destination.lastPathComponent)
        added(isImage: UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false)
    }

    private func added(isImage: Bool) {
        if isImage { imageCount += 1 } else { fileCount += 1 }
    }

    /// Text and pages become text files: the app inlines them into the prompt like any picked file.
    private func stageTexts() {
        for page in pages {
            var body = [page.title, page.url?.absoluteString].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "\n")
            body += "\n\n" + String(page.text.prefix(Self.maxPageCharacters))
            let title = page.title.isEmpty ? (page.url?.host() ?? "Web Page") : page.title
            try? write(Data(body.utf8), named: Self.sanitized(title) + ".txt")
        }
        let text = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        if !text.isEmpty {
            try? write(Data(text.utf8), named: "Shared Text.txt")
        }
    }

    /// Adds a file to the staged item.
    private func write(_ data: Data, named name: String) throws {
        let destination = try freeURL(for: name)
        try data.write(to: destination)
        filenames.append(destination.lastPathComponent)
    }

    /// A name not taken yet in the staged folder.
    private func freeURL(for name: String) throws -> URL {
        guard let folder = staged?.url else { throw SharedInbox.InboxError.unavailable }
        let base = URL(filePath: name).deletingPathExtension().lastPathComponent
        let ext = URL(filePath: name).pathExtension
        var candidate = name
        var number = 2
        while filenames.contains(candidate) {
            candidate = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            number += 1
        }
        return folder.appending(path: candidate)
    }

    private static func filename(suggested: String?, type: UTType, fallback: String) -> String {
        let base = sanitized(suggested.flatMap { $0.isEmpty ? nil : $0 } ?? fallback)
        guard URL(filePath: base).pathExtension.isEmpty, let ext = type.preferredFilenameExtension else { return base }
        return "\(base).\(ext)"
    }

    private static func sanitized(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "-")
        return String(cleaned.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
    }

    private func summarize() {
        var parts: [String] = []
        if let page = pages.first {
            parts.append(page.title.isEmpty ? "Web page" : page.title)
            summarySymbol = "safari"
        } else if let link = links.first {
            parts.append(link.host() ?? link.absoluteString)
            summarySymbol = "link"
        }
        if !texts.isEmpty {
            parts.append("Text")
            summarySymbol = "text.alignleft"
        }
        if imageCount > 0 {
            parts.append(Self.counted(imageCount, "image"))
            summarySymbol = "photo"
        }
        if fileCount > 0 {
            parts.append(Self.counted(fileCount, "file"))
            summarySymbol = "doc"
        }
        summary = parts.joined(separator: " · ")
    }

    /// "1 image", "3 images": Foundation's automatic grammar agreement picks the form.
    private static func counted(_ count: Int, _ noun: String) -> String {
        String(AttributedString(localized: "^[\(count) \(noun)](inflect: true)").characters)
    }

    // MARK: - Handing off

    /// Completes the inbox item; returns the URL that opens it in the app.
    func commit(_ request: ShareRequest) throws -> URL {
        guard let staged else { throw SharedInbox.InboxError.unavailable }
        let linkLines = links.map(\.absoluteString).joined(separator: "\n")
        let ask: String
        switch request {
        case .action(let action): ask = action.prompt
        case .question(let question): ask = question.trimmingCharacters(in: .whitespacesAndNewlines)
        case .attachOnly: ask = ""
        }
        let prompt = [ask, linkLines].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let isAttachOnly = if case .attachOnly = request { true } else { false }
        try SharedInbox.commit(SharedItem(
            id: staged.id,
            createdAt: Date(),
            prompt: prompt,
            autoSend: !isAttachOnly,
            filenames: filenames
        ))
        phase = .opening
        return SharedInbox.url(for: staged.id)
    }

    func markSaved() {
        phase = .saved
    }

    func markFailed(_ error: any Error) {
        phase = .failed(error.localizedDescription)
    }

    /// Cancelled before handing off: nothing is left behind.
    func discard() {
        guard let staged, phase != .opening, phase != .saved else { return }
        SharedInbox.remove(id: staged.id)
    }
}

// MARK: - Item providers

// Called on the main actor, which owns the providers; the system calls back on its own queues.
@MainActor
private extension NSItemProvider {
    /// What SafariPage.js returned, a property list under the preprocessing results key.
    func loadWebPage() async throws -> ShareModel.WebPage {
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            _ = loadDataRepresentation(for: .propertyList) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
        let item = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        guard let results = item?[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return ShareModel.WebPage(
            url: (results["url"] as? String).flatMap(URL.init(string:)),
            title: results["title"] as? String ?? "",
            text: results["text"] as? String ?? ""
        )
    }

    func load<Value: Transferable & Sendable>(_ type: Value.Type) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadTransferable(type: type) { continuation.resume(with: $0) }
        }
    }

    /// The system's temporary copy only lives during the callback, so it's copied there.
    func copyFile(of type: UTType, to destination: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            _ = loadFileRepresentation(for: type) { url, _, error in
                guard let url else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                    return
                }
                do {
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func loadImagePNG() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadObject(ofClass: UIImage.self) { image, error in
                if let data = (image as? UIImage)?.pngData() {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadCorruptFile))
                }
            }
        }
    }
}
