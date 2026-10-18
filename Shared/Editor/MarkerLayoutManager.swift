#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Lays out a note's text, and draws its highlighted words as a marker would: a band of yellow
/// across the lower half of the letters, exactly as wide as the words. TextKit would fill the
/// whole line instead — to the margin when the highlight goes on to the next line, and under the
/// bullet of a list on that next line.
class MarkerLayoutManager: NSLayoutManager {
    /// Where the glyphs being drawn start in the view.
    private var drawingOrigin = CGPoint.zero

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        drawingOrigin = origin
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<CGRect>, count rectCount: Int, forCharacterRange charRange: NSRange, color: PlatformColor) {
        guard let storage = textStorage, charRange.location < storage.length,
              storage.attribute(NoteFormat.highlightKey, at: charRange.location, effectiveRange: nil) != nil,
              // The selection is filled through here too, in its own color.
              storage.attribute(.backgroundColor, at: charRange.location, effectiveRange: nil) as? PlatformColor == color
        else { return super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color) }
        drawMarker(characters: charRange, color: color)
    }

    private func drawMarker(characters: NSRange, color: PlatformColor) {
        guard let storage = textStorage else { return }
        let string = storage.string as NSString
        let glyphs = glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
        color.setFill()
        enumerateLineFragments(forGlyphRange: glyphs) { [self] line, _, container, lineGlyphs, _ in
            var part = NSIntersectionRange(lineGlyphs, glyphs)
            // The space or the line break at the end of a line isn't marked.
            while part.length > 0, let scalar = Unicode.Scalar(string.character(at: characterIndexForGlyph(at: part.upperBound - 1))),
                  CharacterSet.whitespacesAndNewlines.contains(scalar) {
                part.length -= 1
            }
            guard part.length > 0 else { return }
            let words = boundingRect(forGlyphRange: part, in: container)
            let baseline = line.minY + location(forGlyphAt: part.location).y
            let size = (storage.attribute(.font, at: characterIndexForGlyph(at: part.location), effectiveRange: nil) as? PlatformFont)?.pointSize ?? NoteFormat.bodySize
            let band = CGRect(x: drawingOrigin.x + words.minX - 1, y: drawingOrigin.y + baseline - size * 0.47,
                              width: words.width + 2, height: size * 0.6)
            #if canImport(AppKit)
            NSBezierPath(roundedRect: band, xRadius: 2, yRadius: 2).fill()
            #else
            UIBezierPath(roundedRect: band, cornerRadius: 2).fill()
            #endif
        }
    }
}
