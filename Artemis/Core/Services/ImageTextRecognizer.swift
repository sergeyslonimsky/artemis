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

    /// A piece of output placed by its top edge, so tables and loose lines interleave in page order.
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
        var blocks: [Block] = []
        for strip in strips(width: image.width, height: image.height) {
            try Task.checkCancellation()
            guard let cropped = image.cropping(to: strip.rect) else { continue }
            blocks += try await self.blocks(in: cropped)
                .map { strip.toImage($0) }
                .filter { strip.owns($0) }
        }
        return text(of: blocks)
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

    private static func blocks(in image: CGImage) async throws -> [Block] {
        // The line request only helps when the document request saw no text at all (a sign in a
        // photo); lines it saw and dropped as noise would be dropped again.
        if let blocks = try await documentBlocks(in: image) {
            return blocks
        }
        return try await lineBlocks(in: image)
    }

    // MARK: - Strips

    /// Vision scales the whole image to its input size, so on a long screenshot or receipt the
    /// text shrinks until whole lines go missing. Such images are read in overlapping strips.
    static let maxStripAspect = 1.5
    static let stripOverlap = 0.15

    /// A horizontal band of the image (pixels, top-left origin) and the part of it whose blocks
    /// it reports: blocks in the overlap belong to one strip only.
    struct Strip: Equatable {
        var rect: CGRect
        var imageHeight: CGFloat
        var ownedTop: CGFloat
        var ownedBottom: CGFloat

        /// Moves a block from strip coordinates (normalized, bottom-left origin) to image ones.
        func toImage(_ block: Block) -> Block {
            let pixelsFromTop = rect.minY + (1 - block.top) * rect.height
            return Block(top: 1 - pixelsFromTop / imageHeight, text: block.text)
        }

        /// Whether the block (image coordinates) starts in this strip's own part.
        func owns(_ block: Block) -> Bool {
            let pixelsFromTop = (1 - block.top) * imageHeight
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

    /// Document structure (iOS 26+): tables come out as rows of cells, which keeps receipts,
    /// price lists and forms readable; the rest goes through `rows(of:)`.
    /// `nil` when the request found no text at all.
    private static func documentBlocks(in image: CGImage) async throws -> [Block]? {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.automaticallyDetectLanguage = true
        request.textRecognitionOptions.useLanguageCorrection = true
        request.barcodeDetectionOptions.enabled = false
        guard let document = try await request.perform(on: image).first?.document,
              !document.text.lines.isEmpty else { return nil }

        var tableBoxes: [CGRect] = []
        var blocks: [Block] = []
        for table in document.tables {
            tableBoxes.append(table.boundingRegion.normalizedPath.boundingBox)
            // Row by row: a table cut by a strip boundary is placed (and owned) per row.
            for cells in table.rows {
                let cellLines = cells.map { $0.content.text.lines.filter { $0.confidence >= minimumConfidence } }
                let texts = cellLines
                    .map { $0.map(\.transcript).joined(separator: " ") }
                    .filter { !$0.isEmpty }
                guard let top = cellLines.joined().map(\.boundingBox.cgRect.maxY).max(), !texts.isEmpty else { continue }
                blocks.append(Block(top: top, text: texts.joined(separator: " | ")))
            }
        }

        let lines = document.text.lines
            .filter { $0.confidence >= minimumConfidence }
            .map { Line(text: $0.transcript, box: $0.boundingBox.cgRect) }
            .filter { line in !tableBoxes.contains { $0.contains(CGPoint(x: line.box.midX, y: line.box.midY)) } }
        return blocks + rows(of: lines)
    }

    /// Plain line recognition, for images the document request finds nothing in (photos with a sign).
    private static func lineBlocks(in image: CGImage) async throws -> [Block] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        let observations = try await request.perform(on: image)
        let lines = observations
            .filter { $0.confidence >= minimumConfidence }
            .map { Line(text: $0.transcript, box: $0.boundingBox.cgRect) }
        return rows(of: lines)
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
