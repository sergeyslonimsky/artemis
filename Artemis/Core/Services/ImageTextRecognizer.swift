import CoreGraphics
import Vision

/// Reads text in images (printed or handwritten) with Vision. Apple recommends OCR over the
/// language model for text extraction: the on-device model then works with the recognized text.
enum ImageTextRecognizer {
    /// Caps what goes into the prompt; the on-device context window is small.
    static let maxCharacters = 4000

    /// Recognized lines in reading order, or `nil` when the image has no meaningful text.
    static func recognizeText(in image: CGImage) async -> String? {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true

        guard let observations = try? await request.perform(on: image) else { return nil }
        let text = observations
            .map(\.transcript)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3 else { return nil }
        return String(text.prefix(maxCharacters))
    }
}
