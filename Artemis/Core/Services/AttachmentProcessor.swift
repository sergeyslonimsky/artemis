import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Turns picked photos and files into attachments ready to be sent to a model.
enum AttachmentProcessor {
    /// Longest image side sent to providers; larger images only add tokens and upload time.
    static let maxImageDimension = 2048
    static let jpegQuality = 0.85
    /// Text is read before downscaling: a long screenshot shrunk to `maxImageDimension` loses its
    /// small print. Capped by area so a 48 MP photo doesn't take hundreds of megabytes.
    static let maxTextReadingPixels = 12_000_000

    enum ProcessingError: LocalizedError {
        case unreadableImage

        var errorDescription: String? {
            "The image could not be read."
        }
    }

    // MARK: - Async entry points (off the main actor)

    /// A file picked in Files; reads it within its security scope.
    @concurrent
    static func attachment(fromFileAt url: URL) async throws -> Attachment {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        return try fileAttachment(from: data, filename: url.lastPathComponent)
    }

    /// Image bytes from the photo library.
    @concurrent
    static func attachment(fromImageData data: Data) async throws -> Attachment {
        try imageAttachment(from: data)
    }

    /// A camera photo or scanned page: downscaled and compressed once.
    @concurrent
    static func attachment(fromPhoto image: UIImage, filename: String = "photo.jpg") async throws -> Attachment {
        let longest = max(image.size.width * image.scale, image.size.height * image.scale)
        let factor = min(1, CGFloat(maxImageDimension) / longest)
        let size = CGSize(width: image.size.width * image.scale * factor, height: image.size.height * image.scale * factor)
        guard let jpeg = (image.preparingThumbnail(of: size) ?? image).jpegData(compressionQuality: jpegQuality) else {
            throw ProcessingError.unreadableImage
        }
        let attachment = Attachment(filename: filename, mime: "image/jpeg", kind: .image, data: jpeg)
        ImageTextReader.shared.start(id: attachment.id) { uprightImage(from: image) }
        return attachment
    }

    // MARK: - Conversion

    /// Re-encodes any image format (HEIC, PNG, …) as a downscaled JPEG.
    static func imageAttachment(from data: Data, filename: String? = nil) throws -> Attachment {
        let jpeg = try downscaledJPEG(from: data)
        let base = filename.map { ($0 as NSString).deletingPathExtension } ?? "image-\(UUID().uuidString.prefix(6).lowercased())"
        let attachment = Attachment(filename: "\(base).jpg", mime: "image/jpeg", kind: .image, data: jpeg)
        ImageTextReader.shared.start(id: attachment.id) { uprightImage(from: data) }
        return attachment
    }

    /// Images are normalized like photos; everything else is attached as a document with its real MIME type.
    static func fileAttachment(from data: Data, filename: String) throws -> Attachment {
        let type = UTType(filenameExtension: (filename as NSString).pathExtension)
        if let type, type.conforms(to: .image) {
            return try imageAttachment(from: data, filename: filename)
        }
        let mime = type?.preferredMIMEType ?? "application/octet-stream"
        return Attachment(filename: filename, mime: mime, kind: .document, data: data)
    }

    /// Pixels as the image is meant to be seen (EXIF orientation applied), at most `maxPixels`.
    static func uprightImage(from data: Data, maxPixels: Int = maxTextReadingPixels) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        let scale = min(1, (Double(maxPixels) / Double(width * height)).squareRoot())
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(Double(max(width, height)) * scale),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// A camera photo or scanned page upright (its pixels may be stored rotated), at most `maxPixels`.
    static func uprightImage(from image: UIImage, maxPixels: Int = maxTextReadingPixels) -> CGImage? {
        let pixelWidth = image.size.width * image.scale, pixelHeight = image.size.height * image.scale
        let scale = min(1, (Double(maxPixels) / Double(pixelWidth * pixelHeight)).squareRoot())
        if image.imageOrientation == .up, scale == 1, let cgImage = image.cgImage {
            return cgImage
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: (pixelWidth * scale).rounded(), height: (pixelHeight * scale).rounded())
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }

    static func downscaledJPEG(from data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ProcessingError.unreadableImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // apply EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maxImageDimension,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ProcessingError.unreadableImage
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ProcessingError.unreadableImage
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ProcessingError.unreadableImage
        }
        return output as Data
    }
}
