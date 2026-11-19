import CoreGraphics
import Vision

/// Reads text in images (printed or handwritten) with Vision. Apple recommends OCR over the
/// language model for text extraction: the on-device model then works with the recognized text.
enum ImageTextRecognizer {
    /// Caps what goes into the prompt; the on-device context window is small.
    static let maxCharacters = 4000
    /// Below this Vision mostly "reads" textures and patterns in photos; clean print scores 0.45+.
    static let minimumConfidence: Float = 0.3

    /// A recognized line in normalized image coordinates (origin at the bottom left).
    struct Line: Equatable, Sendable {
        var text: String
        var box: CGRect
    }

    /// A row of output placed by its top edge.
    struct Block: Equatable, Sendable {
        var top: CGFloat
        var text: String
    }

    /// Marks text cut at `maxCharacters`, so the model doesn't total a receipt it saw half of.
    static let truncationMarker = "…(text truncated)"

    /// Recognized text top to bottom, or `nil` when the image has no meaningful text.
    /// Layout survives: a receipt keeps each item next to its price. Throws when Vision fails
    /// or the task is cancelled, which callers must not take for "no text".
    static func recognizeText(in image: CGImage) async throws -> String? {
        // Strips are joined line by line, before lines become rows: strips cut a page differently
        // (one sees a row as a table, the next its lines apart), but each line comes out of exactly one.
        var lines: [Line] = []
        for strip in strips(width: image.width, height: image.height) {
            try Task.checkCancellation()
            guard let cropped = image.cropping(to: strip.rect) else { continue }
            lines += try await self.lines(in: cropped)
                .map { strip.toImage($0) }
                .filter { strip.owns($0) }
        }
        return text(of: rows(of: lines))
    }

    /// The blocks top to bottom, cut at `maxCharacters`; `nil` when there's nothing meaningful.
    static func text(of blocks: [Block]) -> String? {
        let text = blocks
            .sorted { $0.top > $1.top }
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3 else { return nil }
        guard text.count > maxCharacters else { return text }
        return text.prefix(maxCharacters) + "\n" + truncationMarker
    }

    private static func lines(in image: CGImage) async throws -> [Line] {
        // The line request only helps when the document request saw no text at all (a sign in a
        // photo); lines it saw and dropped as noise would be dropped again.
        if let lines = try await documentLines(in: image) {
            return lines
        }
        return try await plainLines(in: image)
    }

    // MARK: - Strips

    /// Vision scales the whole image to its input size, so on a long screenshot or receipt the
    /// text shrinks until whole lines go missing. Such images are read in overlapping strips.
    static let maxStripAspect = 1.5
    static let stripOverlap = 0.15

    /// A horizontal band of the image (pixels, top-left origin) and the part of it whose lines
    /// it reports: lines in the overlap belong to one strip only.
    struct Strip: Equatable {
        var rect: CGRect
        var imageHeight: CGFloat
        var ownedTop: CGFloat
        var ownedBottom: CGFloat

        /// Moves a line from strip coordinates (normalized, bottom-left origin) to image ones.
        func toImage(_ line: Line) -> Line {
            let top = rect.minY + (1 - line.box.maxY) * rect.height
            let bottom = rect.minY + (1 - line.box.minY) * rect.height
            let box = CGRect(x: line.box.minX, y: 1 - bottom / imageHeight, width: line.box.width, height: (bottom - top) / imageHeight)
            return Line(text: line.text, box: box)
        }

        /// Whether the line (image coordinates) starts in this strip's own part.
        func owns(_ line: Line) -> Bool {
            let pixelsFromTop = (1 - line.box.maxY) * imageHeight
            return pixelsFromTop >= ownedTop && pixelsFromTop < ownedBottom
        }
    }

    static func strips(width: Int, height: Int) -> [Strip] {
        let width = CGFloat(width), height = CGFloat(height)
        let stripHeight = (width * maxStripAspect).rounded()
        // Text touching an edge can be reported slightly outside the image: the outer strips own it.
        guard height > stripHeight * 1.2 else {
            return [Strip(rect: CGRect(x: 0, y: 0, width: width, height: height), imageHeight: height, ownedTop: -.infinity, ownedBottom: .infinity)]
        }
        let overlap = (width * stripOverlap).rounded()
        let step = stripHeight - overlap
        var strips: [Strip] = []
        var top: CGFloat = 0
        while true {
            // A remainder too short to be worth its own Vision pass joins this strip.
            let isLast = height - (top + step) < stripHeight / 3
            let bottom = isLast ? height : top + stripHeight
            strips.append(Strip(
                rect: CGRect(x: 0, y: top, width: width, height: bottom - top),
                imageHeight: height,
                // A line cut at the step boundary is whole in the next strip, which owns it.
                ownedTop: strips.isEmpty ? -.infinity : top + overlap / 2,
                ownedBottom: isLast ? .infinity : top + step + overlap / 2
            ))
            if isLast { return strips }
            top += step
        }
    }

    /// Lines from document recognition (iOS 26+), `nil` when it found no text at all.
    private static func documentLines(in image: CGImage) async throws -> [Line]? {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.automaticallyDetectLanguage = true
        request.textRecognitionOptions.useLanguageCorrection = true
        request.barcodeDetectionOptions.enabled = false
        guard let document = try await request.perform(on: image).first?.document,
              !document.text.lines.isEmpty else { return nil }
        return document.text.lines
            .filter { $0.confidence >= minimumConfidence }
            .map { Line(text: $0.transcript, box: $0.boundingBox.cgRect) }
    }

    /// Plain line recognition, for images the document request finds nothing in (photos with a sign).
    private static func plainLines(in image: CGImage) async throws -> [Line] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        return try await request.perform(on: image)
            .filter { $0.confidence >= minimumConfidence }
            .map { Line(text: $0.transcript, box: $0.boundingBox.cgRect) }
    }

    /// Joins lines that sit at the same height, left to right: Vision reports an item and its
    /// price as separate lines, often far apart in its own order.
    static func rows(of lines: [Line]) -> [Block] {
        var rows: [[Line]] = []
        for line in lines.sorted(by: { $0.box.midY > $1.box.midY }) where !line.text.isEmpty {
            if let anchor = rows.last?.first,
               abs(anchor.box.midY - line.box.midY) < min(anchor.box.height, line.box.height) / 2 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.map { row in
            Block(
                top: row.map(\.box.maxY).max() ?? 0,
                text: row.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ")
            )
        }
    }
}
