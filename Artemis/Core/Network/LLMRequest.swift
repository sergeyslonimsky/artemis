import Foundation
import UniformTypeIdentifiers

public struct LLMRequest: Sendable {
    public var model: String
    public var messages: [Message]
    public var systemPrompt: String?
    public var preset: Preset?
    public var capabilities: ProviderCapabilities

    public init(
        model: String,
        messages: [Message],
        systemPrompt: String? = nil,
        preset: Preset? = nil,
        capabilities: ProviderCapabilities = ProviderKind.custom.capabilities
    ) {
        self.model = model
        self.messages = messages
        self.systemPrompt = systemPrompt
        self.preset = preset
        self.capabilities = capabilities
    }

    public func encodeToJSONData() throws -> Data {
        var wireMessages: [WireMessage] = []

        let effectiveSystem = preset?.systemPrompt.isEmpty == false ? preset?.systemPrompt : systemPrompt
        if let system = effectiveSystem, !system.isEmpty {
            wireMessages.append(WireMessage(role: "system", content: .text(system)))
        }

        for msg in messages {
            let content: WireContent
            if msg.attachments.isEmpty {
                content = .text(msg.content)
            } else {
                var parts: [WireContentPart] = []
                if !msg.content.isEmpty {
                    parts.append(WireContentPart(type: "text", text: msg.content))
                }
                for att in msg.attachments {
                    if let part = try wirePart(for: att) {
                        parts.append(part)
                    }
                }
                content = .parts(parts)
            }
            wireMessages.append(WireMessage(role: msg.role.rawValue, content: content))
        }

        let wire = WireRequest(
            model: model,
            messages: wireMessages,
            stream: true,
            streamOptions: capabilities.supportsStreamUsage ? .init(includeUsage: true) : nil,
            temperature: preset?.temperature,
            topP: preset?.topP,
            frequencyPenalty: preset?.frequencyPenalty,
            presencePenalty: preset?.presencePenalty
        )

        return try JSONEncoder().encode(wire)
    }

    /// Text documents are inlined (works everywhere); binary ones need `file` part support.
    private func wirePart(for attachment: Attachment) throws -> WireContentPart? {
        guard let data = attachment.data else { return nil }

        if attachment.kind == .image {
            guard capabilities.supportsImages else {
                throw LLMRequestError.unsupportedAttachment(attachment.filename, reason: "this provider does not accept images")
            }
            return WireContentPart(type: "image_url", imageUrl: .init(url: Self.dataURL(attachment, data)))
        }

        if Self.isTextDocument(attachment), let text = String(data: data, encoding: .utf8) {
            return WireContentPart(type: "text", text: "File: \(attachment.filename)\n```\n\(text)\n```")
        }

        guard capabilities.supportsFileParts else {
            throw LLMRequestError.unsupportedAttachment(attachment.filename, reason: "this provider does not accept file attachments")
        }
        return WireContentPart(
            type: "file",
            file: .init(filename: attachment.filename, fileData: Self.dataURL(attachment, data))
        )
    }

    private static func dataURL(_ attachment: Attachment, _ data: Data) -> String {
        "data:\(attachment.mime);base64,\(data.base64EncodedString())"
    }

    private static func isTextDocument(_ attachment: Attachment) -> Bool {
        guard let type = UTType(mimeType: attachment.mime) else { return false }
        return type.conforms(to: .text) || type.conforms(to: .json) || type.conforms(to: .xml)
    }
}

public enum LLMRequestError: LocalizedError {
    case unsupportedAttachment(String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedAttachment(let filename, let reason):
            "Can't send \(filename): \(reason)."
        }
    }
}

// MARK: - Wire Types
private struct WireRequest: Encodable {
    let model: String
    let messages: [WireMessage]
    let stream: Bool
    let streamOptions: WireStreamOptions?
    let temperature: Double?
    let topP: Double?
    let frequencyPenalty: Double?
    let presencePenalty: Double?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream
        case streamOptions = "stream_options"
        case temperature
        case topP = "top_p"
        case frequencyPenalty = "frequency_penalty"
        case presencePenalty = "presence_penalty"
    }
}

private struct WireStreamOptions: Encodable {
    let includeUsage: Bool
    enum CodingKeys: String, CodingKey {
        case includeUsage = "include_usage"
    }
}

private struct WireMessage: Encodable {
    let role: String
    let content: WireContent

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        switch content {
        case .text(let str):
            try container.encode(str, forKey: .content)
        case .parts(let parts):
            try container.encode(parts, forKey: .content)
        }
    }

    enum CodingKeys: String, CodingKey {
        case role, content
    }
}

private enum WireContent: Encodable {
    case text(String)
    case parts([WireContentPart])
}

private struct WireContentPart: Encodable {
    let type: String
    var text: String?
    var imageUrl: WireImageURL?
    var file: WireFilePart?

    enum CodingKeys: String, CodingKey {
        case type, text
        case imageUrl = "image_url"
        case file
    }
}

private struct WireImageURL: Encodable {
    let url: String
}

private struct WireFilePart: Encodable {
    let filename: String
    let fileData: String
    enum CodingKeys: String, CodingKey {
        case filename
        case fileData = "file_data"
    }
}
