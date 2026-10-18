import AppKit

/// Spelling and grammar in the note's text: the lines under the mistakes, the corrections on a
/// right click, and the Edit menu's "Spelling and Grammar" items, which turn the Réglages
/// options on and off. See `ProofReader`.
extension NoteTextView {
    static let spellingColor = NSColor.systemRed
    static let grammarColor = NSColor.systemBlue

    /// Links, the "Source :" line and joined files are not words to check.
    func isUnchecked(_ range: NSRange) -> Bool {
        guard let storage = textStorage, range.upperBound <= storage.length, range.length > 0 else { return true }
        var skipped = false
        storage.enumerateAttributes(in: range) { attributes, _, stop in
            if attributes[NoteFormat.linkKey] != nil || attributes[.attachment] != nil || NoteFormat.block(in: attributes) == .source {
                skipped = true
                stop.pointee = true
            }
        }
        return skipped
    }

    /// Turns the checker on or off, as Réglages say.
    func setProofreading(spelling: Bool, grammar: Bool) {
        proofReader.checksSpelling = spelling && isEditable
        proofReader.checksGrammar = grammar && isEditable && ProofReader.grammarIsAvailable
    }

    // MARK: Drawing

    /// The mark the cursor touches, while the text view has the keyboard: a word being written
    /// isn't wrong yet.
    private var markTouchingCursor: NSRange? {
        let selection = selectedRange()
        guard selection.length == 0, window?.firstResponder === self else { return nil }
        return proofReader.marks.first { selection.location >= $0.range.location && selection.location <= $0.range.upperBound }?.range
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        let touched = markTouchingCursor
        if touched != markAtCursor {
            markAtCursor = touched
            needsDisplay = true
        }
    }

    /// A wavy line under each mistake: red for spelling, blue for grammar.
    func drawProofMarks(in dirtyRect: NSRect) {
        guard proofReader.isEnabled, !proofReader.marks.isEmpty, let storage = textStorage, let layoutManager else { return }
        let origin = textContainerOrigin
        let skipped = markTouchingCursor
        for mark in proofReader.marks where mark.range.upperBound <= storage.length && mark.range != skipped {
            let glyphs = layoutManager.glyphRange(forCharacterRange: mark.range, actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            (mark.kind == .spelling ? Self.spellingColor : Self.grammarColor).setStroke()
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { line, _, container, lineGlyphs, _ in
                let part = NSIntersectionRange(lineGlyphs, glyphs)
                guard part.length > 0 else { return }
                let box = layoutManager.boundingRect(forGlyphRange: part, in: container)
                let y = origin.y + line.minY + layoutManager.location(forGlyphAt: part.location).y + 3
                let rect = NSRect(x: origin.x + box.minX, y: y - 2, width: box.width, height: 4)
                guard rect.intersects(dirtyRect), rect.width > 1 else { return }
                Self.wave(from: rect.minX, to: rect.maxX, y: y).stroke()
            }
        }
    }

    /// A small wave along `y`, as word processors draw.
    private static func wave(from start: CGFloat, to end: CGFloat, y: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = 1.1
        path.lineCapStyle = .round
        let step: CGFloat = 2, height: CGFloat = 1.3
        var x = start
        var up = true
        path.move(to: NSPoint(x: x, y: y))
        while x < end {
            let next = min(x + step, end)
            let peak = up ? y - height : y + height
            path.curve(to: NSPoint(x: next, y: y), controlPoint1: NSPoint(x: x + (next - x) / 3, y: peak), controlPoint2: NSPoint(x: x + 2 * (next - x) / 3, y: peak))
            x = next
            up.toggle()
        }
        return path
    }

    // MARK: Right click

    /// On a mistake, the menu starts with what the checker says, its corrections, and the ways
    /// of leaving the word as it is.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        guard isEditable, proofReader.isEnabled, let menu, let layoutManager, let textContainer else { return menu }
        let point = convert(event.locationInWindow, from: nil)
        let origin = textContainerOrigin
        let inContainer = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = layoutManager.glyphIndex(for: inContainer, in: textContainer)
        guard layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).insetBy(dx: -1, dy: -2).contains(inContainer),
              let mark = proofReader.mark(at: layoutManager.characterIndexForGlyph(at: glyph))
        else { return menu }
        items(for: mark).reversed().forEach { menu.insertItem($0, at: 0) }
        return menu
    }

    /// The items a mistake adds at the top of the menu.
    func items(for mark: ProofReader.Mark) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if let detail = mark.detail, !detail.isEmpty {
            let item = NSMenuItem(title: detail, action: nil, keyEquivalent: "")
            item.isEnabled = false
            items.append(item)
        }
        let corrections = proofReader.corrections(for: mark)
        for correction in corrections {
            let item = NSMenuItem(title: correction, action: #selector(applyCorrection(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = Correction(range: mark.range, text: correction)
            items.append(item)
        }
        if corrections.isEmpty {
            let item = NSMenuItem(title: "Aucune suggestion", action: nil, keyEquivalent: "")
            item.isEnabled = false
            items.append(item)
        }
        items.append(.separator())
        let ignore = NSMenuItem(title: mark.kind == .spelling ? "Ignorer l'orthographe" : "Ignorer", action: #selector(ignoreMark(_:)), keyEquivalent: "")
        ignore.target = self
        ignore.representedObject = Correction(range: mark.range, text: "")
        items.append(ignore)
        if mark.kind == .spelling {
            let learn = NSMenuItem(title: "Ajouter au dictionnaire", action: #selector(learnMark(_:)), keyEquivalent: "")
            learn.target = self
            learn.representedObject = Correction(range: mark.range, text: "")
            items.append(learn)
        }
        items.append(.separator())
        return items
    }

    final class Correction: NSObject {
        let range: NSRange
        let text: String
        init(range: NSRange, text: String) {
            self.range = range
            self.text = text
        }
    }

    /// The mark, as it is now: the text may have changed since the menu opened.
    private func mark(for item: NSMenuItem) -> ProofReader.Mark? {
        guard let correction = item.representedObject as? Correction else { return nil }
        return proofReader.marks.first { $0.range == correction.range }
    }

    @objc func applyCorrection(_ sender: NSMenuItem) {
        guard isEditable, let storage = textStorage, let mark = mark(for: sender), let text = (sender.representedObject as? Correction)?.text else { return }
        replace(mark.range, with: NSAttributedString(string: text, attributes: storage.attributes(at: mark.range.location, effectiveRange: nil)))
    }

    @objc func ignoreMark(_ sender: NSMenuItem) {
        if let mark = mark(for: sender) { proofReader.ignore(mark) }
    }

    @objc func learnMark(_ sender: NSMenuItem) {
        if let mark = mark(for: sender) { proofReader.learn(mark) }
    }

    // MARK: Edit menu

    /// "Vérifier l'orthographe lors de la saisie" and "Vérifier la grammaire avec
    /// l'orthographe" turn the Réglages options on and off.
    override func toggleContinuousSpellChecking(_ sender: Any?) {
        AppSettings.shared.checksSpelling.toggle()
    }

    override func toggleGrammarChecking(_ sender: Any?) {
        AppSettings.shared.checksGrammar.toggle()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(toggleContinuousSpellChecking(_:)):
            (item as? NSMenuItem)?.state = AppSettings.shared.checksSpelling ? .on : .off
            return isEditable
        case #selector(toggleGrammarChecking(_:)):
            (item as? NSMenuItem)?.state = AppSettings.shared.checksGrammar && ProofReader.grammarIsAvailable ? .on : .off
            return isEditable && ProofReader.grammarIsAvailable
        default:
            return super.validateUserInterfaceItem(item)
        }
    }
}
