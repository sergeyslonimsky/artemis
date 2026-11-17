import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns picked photos and files into attachments ready to be sent to a model.
public enum AttachmentProcessor {
    /// Longest image side sent to providers; larger images only add tokens and upload time.
    public static let maxImageDimension = 2048
    public static let jpegQuality = 0.85

    public enum ProcessingError: LocalizedError {
        case unreadableImage

        public var errorDescription: String? {
            "The image could not be read."
        }
    }

    /// Re-encodes any image format (HEIC, PNG, …) as a downscaled JPEG.
    public static func imageAttachment(from data: Data, filename: String? = nil) throws -> Attachment {
        let jpeg = try downscaledJPEG(from: data)
        let base = filename.map { ($0 as NSString).deletingPathExtension } ?? "image-\(UUID().uuidString.prefix(6).lowercased())"
        return Attachment(filename: "\(base).jpg", mime: "image/jpeg", kind: .image, data: jpeg)
    }

    /// Images are normalized like photos; everything else is attached as a document with its real MIME type.
    public static func fileAttachment(from data: Data, filename: String) throws -> Attachment {
        let type = UTType(filenameExtension: (filename as NSString).pathExtension)
        if let type, type.conforms(to: .image) {
            return try imageAttachment(from: data, filename: filename)
        }
        let mime = type?.preferredMIMEType ?? "application/octet-stream"
        return Attachment(filename: filename, mime: mime, kind: .document, data: data)
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
