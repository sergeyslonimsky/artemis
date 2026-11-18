import Foundation

/// A `/chat/completions` request built from the chat history.
struct LLMRequest: Sendable {
    var model: String
    var messages: [Message]
    var systemPrompt: String?
    var preset: Preset?
    var capabilities: ProviderCapabilities = ProviderKind.custom.capabilities
    /// Asks the gateway to run its own web search/fetch tool loop (OpenRouter-style `plugins` marker).
    var webSearch = false
    /// `false` replaces attachments of earlier messages with text notes (fallback when a provider
    /// rejects them despite advertising support).
    var includesPastAttachments = true

    func encodeToJSONData() throws -> Data {
        var wireMessages: [WireMessage] = []
        if let system = Preset.effectiveSystemPrompt(preset: preset, fallback: systemPrompt) {
            wireMessages.append(WireMessage(role: "system", content: .text(system)))
        }

        // Only the message being answered must carry its attachments; earlier ones the model
        // can't read become a note (the earlier reply about them is already in the history).
        let latestUserIndex = messages.lastIndex { $0.role == .user }
        for (index, message) in messages.enumerated() {
            let content: WireContent
            if message.attachments.isEmpty {
                content = .text(message.content)
            } else {
                var parts: [WireContentPart] = message.content.isEmpty ? [] : [.text(message.content)]
                for attachment in message.attachments {
                    if let part = try wirePart(for: attachment, isCurrent: index == latestUserIndex) {
                        parts.append(part)
                    }
                }
                content = .parts(parts)
            }
            wireMessages.append(WireMessage(role: message.role.rawValue, content: content))
        }

        let wire = WireRequest(
            model: model,
            messages: wireMessages,
            stream: true,
            streamOptions: capabilities.supportsStreamUsage ? .init(includeUsage: true) : nil,
            plugins: webSearch ? [WirePlugin(id: "web")] : nil,
            temperature: preset?.temperature,
            topP: preset?.topP,
            frequencyPenalty: preset?.frequencyPenalty,
            presencePenalty: preset?.presencePenalty
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(wire)
    }

    /// Text documents are inlined (works everywhere); binary ones need `file` part support.
    private func wirePart(for attachment: Attachment, isCurrent: Bool) throws -> WireContentPart? {
        guard let data = attachment.data else { return nil }

        if !isCurrent && !includesPastAttachments {
            return try unsupported(attachment, isCurrent: false, reason: "")
        }
        if attachment.kind == .image {
            guard capabilities.supportsImages else {
                return try unsupported(attachment, isCurrent: isCurrent, reason: "\(model) doesn't accept images")
            }
            return .image(url: Self.dataURL(attachment, data))
        }
        if let text = attachment.text {
            return .text("File: \(attachment.filename)\n```\n\(text)\n```")
        }
        guard capabilities.supportsFileParts else {
            return try unsupported(attachment, isCurrent: isCurrent, reason: "\(model) doesn't accept files like this")
        }
        return .file(filename: attachment.filename, data: Self.dataURL(attachment, data))
    }

    /// Fails for the message being answered; earlier attachments degrade to a text note.
    private func unsupported(_ attachment: Attachment, isCurrent: Bool, reason: String) throws -> WireContentPart {
        if isCurrent {
            throw LLMRequestError.unsupportedAttachment(attachment.filename, reason: reason)
        }
        return .text("[\(attachment.kindLabel): \(attachment.filename) — not available to this model]")
    }

    private static func dataURL(_ attachment: Attachment, _ data: Data) -> String {
        "data:\(attachment.mime);base64,\(data.base64EncodedString())"
    }
}

enum LLMRequestError: LocalizedError {
    case unsupportedAttachment(String, reason: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedAttachment(let filename, let reason):
            "Can't send \(filename): \(reason). Switch to On-device or a model that supports it."
        }
    }
}

// MARK: - Wire types
// Property names are encoded in snake_case (`streamOptions` → `stream_options`).

private struct WireRequest: Encodable {
    let model: String
    let messages: [WireMessage]
    let stream: Bool
    let streamOptions: WireStreamOptions?
    /// Omitted unless used: providers that reject unknown fields would fail every request.
    let plugins: [WirePlugin]?
    let temperature: Double?
    let topP: Double?
    let frequencyPenalty: Double?
    let presencePenalty: Double?
}

private struct WireStreamOptions: Encodable {
    let includeUsage: Bool
}

private struct WirePlugin: Encodable {
    let id: String
}

private struct WireMessage: Encodable {
    let role: String
    let content: WireContent
}

/// A plain string, or an array of typed parts for messages with attachments.
private enum WireContent: Encodable {
    case text(String)
    case parts([WireContentPart])

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text): try container.encode(text)
        case .parts(let parts): try container.encode(parts)
        }
    }
}

private struct WireContentPart: Encodable {
    enum Kind: String, Encodable {
        case text
        case imageUrl = "image_url"
        case file
    }

    struct ImageURL: Encodable {
        let url: String
    }

    struct File: Encodable {
        let filename: String
        let fileData: String
    }

    let type: Kind
    var text: String?
    var imageUrl: ImageURL?
    var file: File?

    static func text(_ text: String) -> Self {
        WireContentPart(type: .text, text: text)
    }

    static func image(url: String) -> Self {
        WireContentPart(type: .imageUrl, imageUrl: ImageURL(url: url))
    }

    static func file(filename: String, data: String) -> Self {
        WireContentPart(type: .file, file: File(filename: filename, fileData: data))
    }
}
