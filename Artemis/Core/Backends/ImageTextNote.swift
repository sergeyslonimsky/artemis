import Foundation

/// How an image from an earlier turn reaches the on-device model, which only gets text for
/// past turns: what OCR read in it, sized to the image's role and the room left.
enum ImageTextNote {
    /// How much of the recognized text a past turn carries.
    enum Detail: Comparable {
        /// Just that an image was attached (the reply about it is already in the history).
        case label
        /// The start of a document, for older turns.
        case excerpt
        /// Everything recognized, for the image the conversation is most likely about.
        case full
    }

    /// Up to this much text in a photo is incidental (a sign, a caption), not its content.
    static let incidentalCharacters = 60
    static let incidentalLines = 3
    static let excerptCharacters = 300

    /// Whether the text is the image's content: a receipt, a screenshot, a scanned page.
    static func isDocument(_ attachment: Attachment) -> Bool {
        guard let text = attachment.recognizedText, !text.isEmpty else { return false }
        if attachment.isScan { return true }
        let lines = text.split(whereSeparator: \.isNewline).count
        return text.count > incidentalCharacters || lines > incidentalLines
    }

    /// The note standing in for an image of an earlier turn.
    static func note(for attachment: Attachment, detail: Detail) -> String {
        let label = "Attached image: \(attachment.filename)"
        guard detail > .label, let text = attachment.recognizedText, !text.isEmpty else {
            return "[\(label)]"
        }
        guard isDocument(attachment) else {
            let inline = text.split(whereSeparator: \.isNewline).joined(separator: " / ")
            return "[\(label); text in it: \"\(inline)\"]"
        }
        if detail == .excerpt, text.count > excerptCharacters {
            return """
                [\(label); start of the text recognized in it (OCR):
                \"\"\"
                \(excerpt(of: text))
                …
                \"\"\"]
                """
        }
        return """
            [\(label); text recognized in it (OCR, may contain errors):
            \"\"\"
            \(text)
            \"\"\"]
            """
    }

    /// The text cut to `excerptCharacters` at a line break when there is one.
    static func excerpt(of text: String) -> String {
        let prefix = text.prefix(excerptCharacters)
        guard let lastBreak = prefix.lastIndex(where: \.isNewline) else { return String(prefix) }
        return String(prefix[..<lastBreak])
    }

    /// The text of the image being asked about, appended to the prompt next to the image itself.
    static func promptText(for attachment: Attachment) -> String? {
        guard let text = attachment.recognizedText, !text.isEmpty else { return nil }
        return """
            Text recognized in the attached image \(attachment.filename) (OCR, may contain errors):
            \"\"\"
            \(text)
            \"\"\"
            """
    }

    /// Detail for each history message, oldest first: the latest message with an image gets the
    /// full text unless the user is attaching a new image now; older ones get an excerpt.
    static func details(for history: [Message], currentHasImages: Bool) -> [Detail] {
        let latestWithImage = history.lastIndex { $0.attachments.contains { $0.kind == .image } }
        return history.indices.map { index in
            index == latestWithImage && !currentHasImages ? .full : .excerpt
        }
    }
}
