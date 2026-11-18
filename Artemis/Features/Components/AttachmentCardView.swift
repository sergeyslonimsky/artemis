import SwiftUI

/// An attachment in the composer (`compact`) or in a sent message.
struct AttachmentCardView: View {
    let attachment: Attachment
    var compact: Bool
    var onRemove: (() -> Void)?

    @State private var thumbnail: UIImage?
    @Environment(\.displayScale) private var displayScale
    @Environment(\.database) private var database

    init(attachment: Attachment, compact: Bool = false, onRemove: (() -> Void)? = nil) {
        self.attachment = attachment
        self.compact = compact
        self.onRemove = onRemove
    }

    var body: some View {
        Group {
            if attachment.kind == .image {
                imageTile
            } else {
                documentCard
            }
        }
        .overlay(alignment: .topTrailing) {
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Color.black.opacity(0.7), in: Circle())
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .accessibilityLabel("Remove \(attachment.filename)")
            }
        }
        .padding(.top, onRemove == nil ? 0 : 6)
        .padding(.trailing, onRemove == nil ? 0 : 6)
        .task(id: attachment.id) { await loadThumbnail() }
    }

    private var imageSide: CGFloat { compact ? 60 : 180 }

    private var tileShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: compact ? 12 : 18, style: .continuous)
    }

    private var imageTile: some View {
        tileShape
            .fill(Color(uiColor: .tertiarySystemFill))
            .frame(width: imageSide, height: imageSide)
            .overlay {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(tileShape)
            // Keeps light images from dissolving into the background.
            .overlay(tileShape.strokeBorder(Color.primary.opacity(0.1)))
            .accessibilityLabel(attachment.filename)
    }

    private var documentCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 16))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(attachment.size.formatted(.byteCount(style: .file)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: 240, alignment: .leading)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Composer attachments carry their bytes; sent ones are read back from disk.
    private func loadThumbnail() async {
        guard attachment.kind == .image, thumbnail == nil else { return }
        let data = attachment.data
        let url = database.attachmentURL(id: attachment.id)
        let side = imageSide * displayScale
        thumbnail = await Task.detached(priority: .utility) {
            let image = data.flatMap(UIImage.init(data:)) ?? UIImage(contentsOfFile: url.path)
            return await image?.byPreparingThumbnail(ofSize: CGSize(width: side, height: side))
        }.value
    }
}
