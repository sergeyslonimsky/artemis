import CoreGraphics
import Foundation
import Synchronization
import Testing
import UIKit
@testable import Artemis

@Suite("Image text notes")
struct ImageTextNoteTests {
    func image(_ text: String?, isScan: Bool = false, filename: String = "photo.jpg") -> Artemis.Attachment {
        Attachment(filename: filename, mime: "image/jpeg", kind: .image, recognizedText: text, isScan: isScan)
    }

    static let receipt = (1...20).map { "Item \($0) 1 * 2.49 2.49 C" }.joined(separator: "\n")

    @Test func tellsDocumentsFromIncidentalText() {
        #expect(ImageTextNote.isDocument(image(Self.receipt)))
        #expect(!ImageTextNote.isDocument(image("STOP")))
        #expect(!ImageTextNote.isDocument(image("")))
        #expect(!ImageTextNote.isDocument(image(nil)))
        // A scanned page is a document however little it says.
        #expect(ImageTextNote.isDocument(image("Signed: J. Doe", isScan: true)))
    }

    @Test func photosWithoutTextKeepTheLabel() {
        #expect(ImageTextNote.note(for: image(""), detail: .full) == "[Attached image: photo.jpg]")
        #expect(ImageTextNote.note(for: image(nil), detail: .full) == "[Attached image: photo.jpg]")
        #expect(ImageTextNote.note(for: image(Self.receipt), detail: .label) == "[Attached image: photo.jpg]")
    }

    @Test func incidentalTextStaysInline() {
        let note = ImageTextNote.note(for: image("CAFE\nOPEN"), detail: .excerpt)
        #expect(note == "[Attached image: photo.jpg; text in it: \"CAFE / OPEN\"]")
    }

    @Test func documentsCarryFullTextOrAnExcerpt() {
        let receipt = image(Self.receipt, filename: "receipt.jpg")
        let full = ImageTextNote.note(for: receipt, detail: .full)
        #expect(full.contains("Item 20 1 * 2.49 2.49 C"))

        let excerpt = ImageTextNote.note(for: receipt, detail: .excerpt)
        #expect(excerpt.contains("Item 1 1 * 2.49 2.49 C"))
        #expect(!excerpt.contains("Item 20"))
        #expect(excerpt.count < full.count)
    }

    @Test func excerptEndsAtALineBreak() {
        let excerpt = ImageTextNote.excerpt(of: Self.receipt)
        #expect(excerpt.count <= ImageTextNote.excerptCharacters)
        #expect(excerpt.hasSuffix("2.49 C"))
    }

    @Test func latestImageGetsFullTextUnlessANewOneIsAttached() {
        let history = [
            userMessage("old", attachments: [image(Self.receipt)]),
            Message(chatId: "chat", role: .assistant, content: "Summary"),
            userMessage("new", attachments: [image(Self.receipt)]),
            Message(chatId: "chat", role: .assistant, content: "Summary"),
        ]
        #expect(ImageTextNote.details(for: history, currentHasImages: false) == [.excerpt, .excerpt, .full, .excerpt])
        #expect(ImageTextNote.details(for: history, currentHasImages: true) == [.excerpt, .excerpt, .excerpt, .excerpt])
    }
}

@Suite("Image text recognizer")
struct ImageTextRecognizerTests {
    typealias Line = ImageTextRecognizer.Line
    typealias Block = ImageTextRecognizer.Block

    @Test func joinsLinesAtTheSameHeightLeftToRight() {
        let lines = [
            Line(text: "2.49", box: CGRect(x: 0.8, y: 0.70, width: 0.1, height: 0.04)),
            Line(text: "Whole milk", box: CGRect(x: 0.1, y: 0.71, width: 0.3, height: 0.04)),
            Line(text: "TOTAL 2.49", box: CGRect(x: 0.1, y: 0.50, width: 0.8, height: 0.04)),
        ]
        let rows = ImageTextRecognizer.rows(of: lines)
        #expect(rows.map(\.text) == ["Whole milk 2.49", "TOTAL 2.49"])
    }

    @Test func slightlyTiltedRowsStillJoinButLinesOfDifferentSizesDont() {
        let tilted = [
            Line(text: "Bread", box: CGRect(x: 0.1, y: 0.680, width: 0.3, height: 0.04)),
            Line(text: "4.10", box: CGRect(x: 0.8, y: 0.695, width: 0.1, height: 0.04)),
        ]
        #expect(ImageTextRecognizer.rows(of: tilted).map(\.text) == ["Bread 4.10"])

        let headingAndNote = [
            Line(text: "INVOICE", box: CGRect(x: 0.1, y: 0.46, width: 0.5, height: 0.08)),
            Line(text: "No. 42", box: CGRect(x: 0.7, y: 0.46, width: 0.1, height: 0.02)),
        ]
        #expect(ImageTextRecognizer.rows(of: headingAndNote).map(\.text) == ["INVOICE", "No. 42"])
    }

    @Test func longTextIsMarkedAsTruncated() throws {
        let blocks = (0..<200).map { Block(top: 1 - CGFloat($0) / 200, text: "Line \($0) with some words in it") }
        let text = try #require(ImageTextRecognizer.text(of: blocks))
        #expect(text.hasPrefix("Line 0 "))
        #expect(text.hasSuffix(ImageTextRecognizer.truncationMarker))
        #expect(text.count <= ImageTextRecognizer.maxCharacters + ImageTextRecognizer.truncationMarker.count + 1)
        #expect(ImageTextRecognizer.text(of: [Block(top: 1, text: "ok")]) == nil)
    }

    @Test func shortImagesAreReadWhole() {
        let strips = ImageTextRecognizer.strips(width: 1000, height: 1600)
        #expect(strips.count == 1)
        #expect(strips[0].rect == CGRect(x: 0, y: 0, width: 1000, height: 1600))
        // Text touching the top edge can be reported just above it.
        #expect(strips[0].owns(Line(text: "", box: CGRect(x: 0, y: 0.98, width: 1, height: 0.022))))
    }

    @Test func longImagesAreSplitIntoOverlappingStripsThatOwnEveryRowOnce() {
        let strips = ImageTextRecognizer.strips(width: 424, height: 2048)
        #expect(strips.count > 1)
        #expect(strips.last?.rect.maxY == 2048)
        for (upper, lower) in zip(strips, strips.dropFirst()) {
            #expect(lower.rect.minY < upper.rect.maxY)
            #expect(upper.ownedBottom == lower.ownedTop)
        }
        // Every row of pixels belongs to exactly one strip.
        for y in stride(from: 0.5, to: 2048, by: 7) {
            let line = Line(text: "", box: CGRect(x: 0, y: 1 - (y + 10) / 2048, width: 1, height: 10 / 2048))
            #expect(strips.count { $0.owns(line) } == 1)
        }
    }

    @Test func aShortRemainderJoinsTheLastStrip() {
        // Strips of 150 px stepping by 135: a 30 px remainder isn't worth its own pass.
        let strips = ImageTextRecognizer.strips(width: 100, height: 300)
        #expect(strips.map(\.rect.minY) == [0, 135])
        #expect(strips.last?.rect.maxY == 300)
    }

    @Test func stripLinesMoveToImageCoordinates() {
        let strip = ImageTextRecognizer.Strip(
            rect: CGRect(x: 0, y: 100, width: 50, height: 200), imageHeight: 1000, ownedTop: 0, ownedBottom: 1000
        )
        // The strip's top half: 100–200 px from the top of a 1000 px image.
        let line = strip.toImage(Line(text: "a", box: CGRect(x: 0.2, y: 0.5, width: 0.3, height: 0.5)))
        #expect(abs(line.box.maxY - 0.9) < 1e-9)
        #expect(abs(line.box.minY - 0.8) < 1e-9)
        #expect(line.box.minX == 0.2 && line.box.width == 0.3)
    }

    /// A long store-app screenshot: stored downscaled its print is too small to read, so the text
    /// comes from the original, in strips (read whole, Vision loses lines).
    @Test(.timeLimit(.minutes(1)))
    func readsEveryLineOfALongScreenshotFromTheOriginal() async throws {
        let items = (1...60).map { (name: "Item number \($0)", price: String(format: "%d.%02d", $0, $0)) }
        let size = CGSize(width: 500, height: 100 + CGFloat(items.count) * 70)
        let font = UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let png = UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            for (index, item) in items.enumerated() {
                let y = 60 + CGFloat(index) * 70
                (item.name as NSString).draw(at: CGPoint(x: 20, y: y), withAttributes: attributes)
                (item.price as NSString).draw(at: CGPoint(x: 400, y: y), withAttributes: attributes)
            }
        }
        let attachment = try AttachmentProcessor.imageAttachment(from: png, filename: "screenshot.png")
        let stored = try #require(attachment.data)

        let text = try #require(try await ImageTextReader.shared.text(id: attachment.id, data: stored))
        let lines = text.split(separator: "\n").map(String.init)
        for item in items {
            #expect(lines.contains { $0.contains(item.name) && $0.contains(item.price) }, "\(item.name) \(item.price)")
        }
        // Rows in the overlap of two strips come out once.
        #expect(Set(lines).count == lines.count)
    }

    /// Camera photos may keep their pixels rotated with an orientation tag.
    @Test(.timeLimit(.minutes(1)))
    func readsRotatedCameraPhotosUpright() async throws {
        let size = CGSize(width: 600, height: 200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let upright = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            ("ORIENTATION TEST" as NSString).draw(
                at: CGPoint(x: 40, y: 70), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 40), .foregroundColor: UIColor.black]
            )
        }
        // Pixels turned on their side, shown upright through the orientation tag.
        let sideways = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 600), format: format).image { _ in
            UIImage(cgImage: try! #require(upright.cgImage), scale: 1, orientation: .right).draw(at: .zero)
        }
        let photo = UIImage(cgImage: try #require(sideways.cgImage), scale: 1, orientation: .left)
        #expect(photo.size == size)

        let attachment = try await AttachmentProcessor.attachment(fromPhoto: photo)
        let stored = try #require(attachment.data)
        let text = try await ImageTextReader.shared.text(id: attachment.id, data: stored)
        #expect(text?.contains("ORIENTATION TEST") == true)

        let storedImage = try #require(AttachmentProcessor.uprightImage(from: stored))
        #expect(storedImage.width > storedImage.height)
    }

    @Test(.timeLimit(.minutes(1)))
    func blankImageHasNoText() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        }
        #expect(try await ImageTextRecognizer.recognizeText(in: try #require(image.cgImage)) == nil)
    }
}

@Suite("Image text reader")
struct ImageTextReaderTests {
    @Test func anImageIsReadOnceForEveryoneWhoAsks() async throws {
        let reader = ImageTextReader()
        let loads = Mutex(0)
        reader.start(id: "a") {
            loads.withLock { $0 += 1 }
            return nil
        }
        async let first = reader.text(id: "a", data: Data())
        async let second = reader.text(id: "a", data: Data())
        _ = try await (first, second)
        #expect(loads.withLock { $0 } == 1)
    }

    @Test func aCancelledReadingIsNotTakenForNoText() async throws {
        let reader = ImageTextReader()
        let image = try #require(UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { _ in }.cgImage)
        reader.start(id: "a") {
            Thread.sleep(forTimeInterval: 0.3)
            return image
        }
        let waiting = Task { try await reader.text(id: "a", data: Data()) }
        try await Task.sleep(for: .milliseconds(50))
        reader.cancel(id: "a")
        await #expect(throws: CancellationError.self) { try await waiting.value }
    }
}

@Suite("On-device history budget")
struct OnDeviceHistoryBudgetTests {
    @Test func keepsTheMostDetailedVariantThatFitsNewestFirst() async {
        let kept = await AppleOnDeviceBackend.fitNewestFirst([[10], [30, 5], [20]], room: 30, variants: { $0 }, cost: { $0 })
        #expect(kept == [5, 20])
    }

    @Test func stopsAtTheFirstMessageThatDoesntFit() async {
        // Skipping a message would leave a gap in the conversation.
        let kept = await AppleOnDeviceBackend.fitNewestFirst([[1], [100], [1]], room: 10, variants: { $0 }, cost: { $0 })
        #expect(kept == [1])
        let skipsEmpty = await AppleOnDeviceBackend.fitNewestFirst([[1], [], [1]], room: 10, variants: { $0 }, cost: { $0 })
        #expect(skipsEmpty == [1, 1])
    }

    @Test func historyTextsShrinkOnlyWhenTheyDiffer() {
        let receipt = Attachment(filename: "r.jpg", mime: "image/jpeg", kind: .image, recognizedText: ImageTextNoteTests.receipt)
        let note = Attachment(filename: "n.jpg", mime: "image/jpeg", kind: .image, recognizedText: "Signed: J. Doe", isScan: true)
        let photo = Attachment(filename: "p.jpg", mime: "image/jpeg", kind: .image, recognizedText: "")

        #expect(AppleOnDeviceBackend.historyTexts(for: userMessage("Sum it", attachments: [receipt]), maxDetail: .full).count == 3)
        #expect(AppleOnDeviceBackend.historyTexts(for: userMessage("Sum it", attachments: [receipt]), maxDetail: .excerpt).count == 2)
        // A short document is the same in full and as an excerpt: counted once.
        #expect(AppleOnDeviceBackend.historyTexts(for: userMessage("", attachments: [note]), maxDetail: .full).count == 2)
        #expect(AppleOnDeviceBackend.historyTexts(for: userMessage("Nice", attachments: [photo]), maxDetail: .full) == ["Nice\n[Attached image: p.jpg]"])
        #expect(AppleOnDeviceBackend.historyTexts(for: userMessage(""), maxDetail: .full).isEmpty)
    }
}
