import AppKit
import ImageIO
import UniformTypeIdentifiers

/// How a file joined to a note shows in its text: an image as itself, as wide as the column at
/// most; any other file (a PDF, an archive…) as a small card with its icon, its name and its
/// size. The file itself is in the note's attachments folder; the text only holds its name.
final class NoteAttachmentCell: NSTextAttachmentCell {
    let name: String
    /// nil: the note has no folder to look in.
    let url: URL?
    /// The picture of an image file, no larger than the screen needs; nil for other files.
    private let picture: NSImage?

    static let cardSize = NSSize(width: 300, height: 46)
    static let maxImageHeight: CGFloat = 560
    /// Longest side, in pixels, of the picture kept in memory.
    private static let maxPixels = 2400

    init(name: String, url: URL?) {
        self.name = name
        self.url = url
        picture = url.flatMap(Self.picture(at:))
        super.init(imageCell: nil)
    }

    required init(coder: NSCoder) {
        fatalError("NoteAttachmentCell is never archived")
    }

    /// The character that shows `name`, a file of `directory`, with the attributes of body text.
    static func character(name: String, directory: URL?) -> NSAttributedString {
        let text = NSMutableAttributedString(string: String(NoteText.attachmentCharacter), attributes: NoteFormat.attributes(block: nil))
        text.addAttributes(attributes(name: name, directory: directory), range: NSRange(location: 0, length: text.length))
        return text
    }

    static func attributes(name: String, directory: URL?) -> [NSAttributedString.Key: Any] {
        let attachment = NSTextAttachment()
        attachment.attachmentCell = NoteAttachmentCell(name: name, url: directory?.appendingPathComponent(name))
        return [NoteFormat.attachmentKey: name, .attachment: attachment]
    }

    private static func picture(at url: URL) -> NSImage? {
        guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              // Its size on screen: in points, as the file says.
              let size = NSImage(contentsOf: url)?.size, size.width > 0, size.height > 0
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // A photo taken sideways is turned by the thumbnail: its sides may have swapped.
        let turned = (image.width > image.height) != (size.width > size.height)
        return NSImage(cgImage: image, size: turned ? NSSize(width: size.height, height: size.width) : size)
    }

    // MARK: Layout

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let room = max(80, lineFrag.width - position.x - 2 * textContainer.lineFragmentPadding)
        guard let picture else { return NSRect(x: 0, y: -4, width: min(Self.cardSize.width, room), height: Self.cardSize.height) }
        let scale = min(1, room / picture.size.width, Self.maxImageHeight / picture.size.height)
        return NSRect(x: 0, y: 0, width: floor(picture.size.width * scale), height: floor(picture.size.height * scale))
    }

    override func cellSize() -> NSSize { picture?.size ?? Self.cardSize }

    // MARK: Drawing

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if let picture {
            NSBezierPath(roundedRect: cellFrame, xRadius: 6, yRadius: 6).addClip()
            picture.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            return
        }
        let card = cellFrame.insetBy(dx: 0, dy: 1)
        NSColor.gray.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: card, xRadius: 8, yRadius: 8).fill()
        let exists = url.map { FileManager.default.fileExists(atPath: $0.path) } == true
        let icon = exists ? NSWorkspace.shared.icon(forFile: url!.path) : NSWorkspace.shared.icon(for: UTType(filenameExtension: (name as NSString).pathExtension) ?? .data)
        icon.draw(in: NSRect(x: card.minX + 9, y: card.midY - 15, width: 30, height: 30), from: .zero, operation: .sourceOver, fraction: exists ? 1 : 0.5, respectFlipped: true, hints: nil)
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingMiddle
        let text = NSRect(x: card.minX + 48, y: card.minY + 6, width: card.width - 58, height: 17)
        (name as NSString).draw(in: text, withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: Theme.primaryTextNS, .paragraphStyle: truncating,
        ])
        (detail(exists: exists) as NSString).draw(in: text.offsetBy(dx: 0, dy: 18), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.secondaryTextNS, .paragraphStyle: truncating,
        ])
    }

    /// Under the name: "PDF · 1,2 Mo".
    private func detail(exists: Bool) -> String {
        guard exists, let url else { return "Fichier introuvable" }
        let kind = (name as NSString).pathExtension.uppercased()
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return kind.isEmpty ? size : "\(kind)  ·  \(size)"
    }
}
