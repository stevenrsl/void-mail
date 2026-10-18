import AppKit
import UniformTypeIdentifiers

/// The text of a note: an AppKit text view that formats as you type (see `TypingRules`), with no
/// toolbar. What is typed is shown formatted at once; ⌘B, ⌘I and the Format menu do the same on
/// a selection. Pasted text comes in in the note's style; its Markdown marks are read.
final class NoteTextView: NSTextView, NSTextViewDelegate {
    /// Called after every change of the text or its formatting.
    var onChange: (() -> Void)?
    /// Called when a key is typed in the note (not a ⌘ shortcut): the chrome fades away.
    var onTyping: (() -> Void)?

    var accent: AccentChoice = .violet {
        didSet {
            insertionPointColor = Theme.accentNS(accent)
            selectedTextAttributes = [.backgroundColor: Theme.accentSoftNS(accent)]
            linkTextAttributes = [.foregroundColor: Theme.accentNS(accent), .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
            needsDisplay = true
        }
    }

    /// Spelling and grammar, underlined in red and blue (Réglages).
    private(set) var proofReader: ProofReader!
    /// The mark the cursor is on, left undrawn while one writes there.
    var markAtCursor: NSRange?

    /// Dates of the note, written small and in monospace under its first paragraph (its title).
    var meta = "" {
        didSet { if meta != oldValue { needsDisplay = true } }
    }
    /// The dates in full, when the pointer rests on them.
    var metaHelp: String {
        get { metaToolTipOwner.text }
        set { metaToolTipOwner.text = newValue }
    }
    private let metaToolTipOwner = MetaToolTipOwner()
    private var metaToolTip: NSView.ToolTipTag?
    private var metaToolTipRect = NSRect.zero

    /// The note's text sits in a column of comfortable reading width, centered in the window.
    static let columnWidth: CGFloat = 700
    /// The room the floating controls keep around them (Void Notes' `NoteActions.inset`).
    static let accessoryInset: CGFloat = 4
    /// A note's first line is its title; a message's is body text (Void Mail).
    var startsWithTitle = true
    static let minimumMargin: CGFloat = 36
    static let topMargin: CGFloat = 30

    /// True while the view applies a change of its own, which the typing rules must not read.
    private var isApplyingRule = false
    /// True while the view sets its typing attributes itself (see `shouldChangeTypingAttributes`).
    private var isSettingTypingAttributes = false
    /// Characters changed since the last `didChangeText`, to be restyled.
    private var editedRange: NSRange?

    /// A text view ready for a note, in its scroll view.
    static func makeScrollable() -> (scrollView: NSScrollView, textView: NoteTextView) {
        // TextKit 1: the quote bars are drawn from the layout manager's line rects.
        let textView = NoteTextView(usingTextLayoutManager: false)
        // Highlighted words are marked as with a marker, not filled to the line's end.
        textView.textContainer?.replaceLayoutManager(MarkerLayoutManager())
        textView.isRichText = true
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticLinkDetectionEnabled = false
        // "--" stays two dashes: the third one makes a divider.
        textView.isAutomaticDashSubstitutionEnabled = false
        // Checked by the note's own proofreader, which underlines in red and blue.
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.proofReader = ProofReader(storage: textView.textStorage!)
        textView.proofReader.onChange = { [weak textView] in textView?.needsDisplay = true }
        textView.proofReader.skips = { [weak textView] range in textView?.isUnchecked(range) ?? false }
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: minimumMargin, height: topMargin)
        textView.delegate = textView
        textView.accent = .violet
        textView.setAccessibilityLabel("Texte du message")

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = textView
        return (scrollView, textView)
    }

    func load(_ content: NoteContent) {
        textStorage?.setAttributedString(NoteFormat.attributedString(from: content, attachments: attachmentsDirectory))
        undoManager?.removeAllActions()
        needsLayout = true
        setSelectedRange(NSRange(location: textStorage?.length ?? 0, length: 0))
        if content.text.isEmpty, startsWithTitle { setTyping(NoteFormat.attributes(block: .title)) }
    }

    var content: NoteContent {
        textStorage.map(NoteFormat.content(from:)) ?? NoteContent()
    }

    func focus() {
        window?.makeFirstResponder(self)
    }

    /// The note takes the keyboard as soon as it is in the window.
    var takesFocusWhenShown = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard takesFocusWhenShown, window != nil else { return }
        takesFocusWhenShown = false
        // Once the window has finished putting the view in place.
        DispatchQueue.main.async { [weak self] in self?.focus() }
    }

    override func keyDown(with event: NSEvent) {
        if isEditable, !event.modifierFlags.contains(.command) { onTyping?() }
        super.keyDown(with: event)
    }

    /// A note of the trash is read, not written: its text steps back, as the list's does.
    func dimText() {
        guard let storage = textStorage else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            // The characters under the checklist boxes stay unseen.
            if value as? NSColor != .clear { storage.addAttribute(.foregroundColor, value: Theme.secondaryTextNS, range: range) }
        }
        storage.endEditing()
    }

    // MARK: Formatting as you type

    /// Every keystroke goes through here before it changes the text.
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        let undoing = undoManager?.isUndoing == true || undoManager?.isRedoing == true
        if !isApplyingRule, !undoing, !hasMarkedText(), let replacementString,
           let action = TypingRules.action(in: string as NSString, range: affectedCharRange, replacement: replacementString, block: currentBlock, indent: currentIndent) {
            apply(action)
            return false
        }
        guard super.shouldChangeText(in: affectedCharRange, replacementString: replacementString) else { return false }
        let changed = NSRange(location: affectedCharRange.location, length: replacementString.map { $0.utf16.count } ?? affectedCharRange.length)
        editedRange = editedRange.map { NSUnionRange($0, changed) } ?? changed
        return true
    }

    override func didChangeText() {
        let edited = editedRange
        if let range = editedRange, let storage = textStorage {
            editedRange = nil
            storage.beginEditing()
            NoteFormat.restyle(storage, in: range)
            storage.endEditing()
        }
        super.didChangeText()
        // Quote bars and the placeholder are drawn by the view, not by the text.
        needsDisplay = true
        // A title that takes one more line pushes the album down.
        if albumHeight > 0 { layoutAlbum() }
        onChange?()
        if let edited, undoManager?.isUndoing != true, undoManager?.isRedoing != true { renumberLists(around: edited) }
        if !searchWords.isEmpty { showFound() }
    }

    /// True while the numbers of a list are being written again.
    private var isRenumbering = false

    /// The numbered list around `range` counts again from its first item (see `ListNumbering`),
    /// in the same undo step as the change that made it necessary.
    private func renumberLists(around range: NSRange) {
        guard !isRenumbering, let storage = textStorage else { return }
        let fixes = ListNumbering.fixes(in: storage, around: range)
        guard !fixes.isEmpty else { return }
        isRenumbering = true
        defer { isRenumbering = false }
        var selection = selectedRange()
        for fix in fixes {
            replace(fix.range, with: NSAttributedString(string: fix.marker, attributes: storage.attributes(at: fix.range.location, effectiveRange: nil)))
            let start = ListNumbering.moved(selection.location, by: fix), end = ListNumbering.moved(selection.upperBound, by: fix)
            selection = NSRange(location: start, length: end - start)
        }
        setSelectedRange(selection)
    }

    private func apply(_ action: TypingRules.Action) {
        guard let storage = textStorage else { return }
        switch action {
        case .replace(let range, let text):
            replace(range, with: NSAttributedString(string: text, attributes: typingAttributes))
        case .setBlock(let block, let marker):
            if marker.length > 0 { replace(marker, with: NSAttributedString()) }
            setBlock(block)
        case .inline(let range, let content, let style):
            let key = NoteFormat.key(of: style)
            let piece = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: content))
            piece.addAttribute(key, value: true, range: NSRange(location: 0, length: piece.length))
            if style == .bold { piece.removeAttribute(NoteFormat.weightKey, range: NSRange(location: 0, length: piece.length)) }
            // What is typed next is outside the passage.
            var typing = typingAttributes
            replace(range, with: piece)
            typing[key] = nil
            setTyping(typing)
        case .divider(let range):
            placeDivider(replacing: range)
        case .indent(let steps):
            changeIndent(by: steps)
        }
    }

    /// Puts a divider in the paragraph of `range`, which holds nothing else than `range`; the
    /// cursor goes to the line that follows.
    private func placeDivider(replacing range: NSRange) {
        // An empty last line has no break yet: the divider brings the line that follows it.
        let hasBreak = range.upperBound < (string as NSString).length
        replace(range, with: NSAttributedString(string: NoteFormat.rule + (hasBreak ? "" : "\n"), attributes: NoteFormat.attributes(block: .divider)))
        if hasBreak {
            setSelectedRange(NSRange(location: selectedRange().location + 1, length: 0))
        } else {
            setTyping(NoteFormat.attributes(block: nil))
        }
    }

    /// A change made by the view, undoable like a keystroke; the cursor ends up after it.
    func replace(_ range: NSRange, with text: NSAttributedString) {
        guard let storage = textStorage else { return }
        isApplyingRule = true
        defer { isApplyingRule = false }
        guard shouldChangeText(in: range, replacementString: text.string) else { return }
        storage.replaceCharacters(in: range, with: text)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + text.length, length: 0))
    }

    /// Return at the end of a title or heading: the next line is body text again.
    override func insertNewline(_ sender: Any?) {
        super.insertNewline(sender)
        guard currentBlock?.isSingleLine == true else { return }
        let string = self.string as NSString
        let paragraph = string.paragraphRange(for: NSRange(location: selectedRange().location, length: 0))
        // The cursor is on a new, empty line (not on the rest of a heading cut in two).
        if paragraph.length <= 1 { setBlock(nil) }
    }

    /// Backspace at the very start of a title, heading or quote turns it back into body text.
    /// A divider goes in one piece: from its own line, or from the start of the line after it.
    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length == 0, let storage = textStorage else { return super.deleteBackward(sender) }
        let string = self.string as NSString
        let paragraph = string.paragraphRange(for: selection)
        if currentBlock == .divider {
            replace(TypingRules.contentRange(of: paragraph, in: string), with: NSAttributedString())
            setTyping(NoteFormat.attributes(block: nil))
        } else if paragraph.location == selection.location, currentBlock != nil {
            setBlock(nil)
        } else if paragraph.location == selection.location, selection.location > 0,
                  case let previous = string.paragraphRange(for: NSRange(location: selection.location - 1, length: 0)),
                  NoteFormat.block(in: storage.attributes(at: previous.location, effectiveRange: nil)) == .divider {
            replace(previous, with: NSAttributedString())
        } else {
            super.deleteBackward(sender)
        }
    }

    /// The note ends with a title or a heading: there is no line after it to click on or to go
    /// down to. Going there makes that line, in body text.
    private func startTextAfterLastHeading() -> Bool {
        guard isEditable, let storage = textStorage, storage.length > 0, storage.string.last?.isNewline == false,
              NoteFormat.block(in: storage.attributes(at: storage.length - 1, effectiveRange: nil))?.isHeading == true
        else { return false }
        setSelectedRange(NSRange(location: storage.length, length: 0))
        insertNewline(nil)
        return true
    }

    /// A click at `point` (in the view), under everything written: true if it made the line of
    /// text that follows a last title.
    func clickBelowText(at point: NSPoint) -> Bool {
        guard let layoutManager, let textContainer else { return false }
        layoutManager.ensureLayout(for: textContainer)
        return point.y > textContainerOrigin.y + layoutManager.usedRect(for: textContainer).maxY && startTextAfterLastHeading()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // The box of a checklist item: checked or unchecked, the cursor stays where it is.
        if toggleCheckbox(at: point) { return }
        if event.clickCount == 1, clickBelowText(at: point) {
            window?.makeFirstResponder(self)
            return
        }
        super.mouseDown(with: event)
    }

    /// ⇧Tab in a list: the item comes back one step.
    override func insertBacktab(_ sender: Any?) {
        guard isEditable, currentIndent > 0 || isInList else { return super.insertBacktab(sender) }
        changeIndent(by: -1)
    }

    override func moveDown(_ sender: Any?) {
        // Already at the very end: ↓ has nowhere else to go.
        if selectedRange() == NSRange(location: (string as NSString).length, length: 0), startTextAfterLastHeading() { return }
        super.moveDown(sender)
    }

    var isItalic: Bool { currentAttributes[NoteFormat.italicKey] != nil }

    // MARK: Formatting commands (Format menu, ⌘B, ⌘I)

    /// Kind of the paragraph the cursor is in.
    var currentBlock: NoteBlock? {
        let paragraph = (string as NSString).paragraphRange(for: NSRange(location: selectedRange().location, length: 0))
        if paragraph.length > 0, let storage = textStorage {
            return NoteFormat.block(in: storage.attributes(at: paragraph.location, effectiveRange: nil))
        }
        // An empty last line has no character to carry its kind yet.
        return NoteFormat.block(in: typingAttributes)
    }

    /// Applies to the whole paragraphs of the selection; nil: body text.
    func setBlock(_ block: NoteBlock?) {
        guard isEditable, let storage = textStorage else { return }
        let paragraphs = (storage.string as NSString).paragraphRange(for: selectedRange())
        if paragraphs.length > 0 {
            guard shouldChangeText(in: paragraphs, replacementString: nil) else { return }
            storage.beginEditing()
            if let block {
                storage.addAttribute(NoteFormat.blockKey, value: block.rawValue, range: paragraphs)
            } else {
                storage.removeAttribute(NoteFormat.blockKey, range: paragraphs)
            }
            storage.endEditing()
            didChangeText()
        }
        var typing = typingAttributes
        typing[NoteFormat.blockKey] = block?.rawValue
        setTyping(typing)
    }

    func toggleBold() { setWeight(isOn(NoteFormat.boldKey) ? nil : .bold) }
    func toggleItalic() { toggle(NoteFormat.italicKey) }
    func toggleHighlight() { toggle(NoteFormat.highlightKey) }
    func toggleStrike() { toggle(NoteFormat.strikeKey) }
    func toggleCode() { toggle(NoteFormat.codeKey) }

    /// Weight at the cursor, or where the selection starts; nil: the paragraph's own.
    var currentWeight: NoteWeight? { NoteFormat.weight(in: currentAttributes) }
    var isHighlighted: Bool { currentAttributes[NoteFormat.highlightKey] != nil }
    var isStruck: Bool { currentAttributes[NoteFormat.strikeKey] != nil }
    var isCode: Bool { currentAttributes[NoteFormat.codeKey] != nil }

    /// Steps of indentation of the list item the cursor is in.
    var currentIndent: Int {
        guard let storage = textStorage else { return 0 }
        let paragraph = (string as NSString).paragraphRange(for: NSRange(location: min(selectedRange().location, storage.length), length: 0))
        return paragraph.length > 0 ? NoteFormat.indent(at: paragraph.location, in: storage) : NoteFormat.indent(in: typingAttributes)
    }

    /// The cursor is in a list item.
    var isInList: Bool {
        let string = self.string as NSString
        return selectedParagraphs.contains { ListMarker.marker(in: string, paragraph: $0) != nil }
    }

    /// Indents the list items of the selection by `steps` (negative: back), between none and
    /// `NoteFormat.maxIndent`. The numbers of a numbered list follow.
    func changeIndent(by steps: Int) {
        guard isEditable, let storage = textStorage else { return }
        let string = self.string as NSString
        let items = selectedParagraphs.filter { ListMarker.marker(in: string, paragraph: $0) != nil }
        let changes = items.map { ($0, min(max(NoteFormat.indent(at: $0.location, in: storage) + steps, 0), NoteFormat.maxIndent)) }
            .filter { NoteFormat.indent(at: $0.0.location, in: storage) != $0.1 }
        guard let first = changes.first, let last = changes.last else { return NSSound.beep() }
        let span = NSUnionRange(first.0, last.0)
        guard shouldChangeText(in: span, replacementString: nil) else { return }
        storage.beginEditing()
        for (paragraph, indent) in changes {
            if indent > 0 {
                storage.addAttribute(NoteFormat.indentKey, value: indent, range: paragraph)
            } else {
                storage.removeAttribute(NoteFormat.indentKey, range: paragraph)
            }
        }
        storage.endEditing()
        didChangeText()
        // What is typed next — the item that Return makes — has the same indentation.
        var typing = typingAttributes
        typing[NoteFormat.indentKey] = NoteFormat.indent(at: (string as NSString).paragraphRange(for: NSRange(location: selectedRange().location, length: 0)).location, in: storage)
        if typing[NoteFormat.indentKey] as? Int == 0 { typing[NoteFormat.indentKey] = nil }
        setTyping(typing)
    }

    private var currentAttributes: [NSAttributedString.Key: Any] {
        let selection = selectedRange()
        if selection.length > 0, let storage = textStorage { return storage.attributes(at: selection.location, effectiveRange: nil) }
        return typingAttributes
    }

    /// On the selection, or on what is typed next when nothing is selected. nil: the weight the
    /// paragraph has by itself.
    func setWeight(_ weight: NoteWeight?) {
        change { attributes in
            attributes[NoteFormat.boldKey] = weight == .bold ? true : nil
            attributes[NoteFormat.weightKey] = weight == .bold ? nil : weight?.rawValue
        }
    }

    /// Already on everywhere: turned off; otherwise turned on everywhere.
    private func toggle(_ key: NSAttributedString.Key) {
        let on = !isOn(key)
        change { $0[key] = on ? true : nil }
    }

    /// The whole selection has the attribute (or what is typed next, when nothing is selected).
    private func isOn(_ key: NSAttributedString.Key) -> Bool {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else { return typingAttributes[key] != nil }
        var covered = NSRange()
        return storage.attribute(key, at: range.location, longestEffectiveRange: &covered, in: range) != nil && covered.upperBound >= range.upperBound
    }

    /// Changes semantic attributes of the selection, or of what is typed next.
    private func change(_ edit: (inout [NSAttributedString.Key: Any]) -> Void) {
        guard isEditable, let storage = textStorage else { return }
        let range = selectedRange()
        guard range.length > 0 else {
            var typing = typingAttributes
            edit(&typing)
            setTyping(typing)
            return
        }
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        var pieces: [(NSRange, [NSAttributedString.Key: Any])] = []
        storage.enumerateAttributes(in: range) { attributes, piece, _ in
            var attributes = attributes
            edit(&attributes)
            pieces.append((piece, attributes))
        }
        storage.beginEditing()
        for (piece, attributes) in pieces { storage.setAttributes(attributes, range: piece) }
        storage.endEditing()
        didChangeText()
    }

    /// A divider under the paragraph of the cursor (in its place if that paragraph is empty).
    func insertDivider() {
        guard isEditable else { return }
        let string = self.string as NSString
        let paragraph = string.paragraphRange(for: NSRange(location: selectedRange().location, length: 0))
        let content = TypingRules.contentRange(of: paragraph, in: string)
        undoManager?.beginUndoGrouping()
        if content.length > 0 {
            setSelectedRange(NSRange(location: content.upperBound, length: 0))
            replace(NSRange(location: content.upperBound, length: 0), with: NSAttributedString(string: "\n", attributes: NoteFormat.attributes(block: nil)))
        }
        placeDivider(replacing: NSRange(location: selectedRange().location, length: 0))
        undoManager?.endUndoGrouping()
    }

    // MARK: Links

    /// Address of the link the cursor is in (or at the end of), or that the selection starts in.
    var currentLink: String? {
        textStorage.flatMap { NoteFormat.link(at: selectedRange().location, in: $0)?.address }
    }

    /// Makes the selection a link to `url`; with nothing selected, the link the cursor is in
    /// changes address. nil: the link goes, its text stays. Nothing selected outside a link, the
    /// address itself is written, as a link.
    func setLink(_ url: URL?) {
        guard isEditable, let storage = textStorage else { return }
        let string = storage.string as NSString
        var range = selectedRange()
        if range.length == 0, let link = NoteFormat.link(at: range.location, in: storage) { range = link.range }
        // A line break or a space at the end of the selection isn't part of the link.
        while range.length > 0, let scalar = UnicodeScalar(string.character(at: range.upperBound - 1)), CharacterSet.whitespacesAndNewlines.contains(scalar) {
            range.length -= 1
        }
        if range.length == 0 {
            guard let url, selectedRange().length == 0 else { return }
            let shown = url.scheme == "mailto" ? String(url.absoluteString.dropFirst("mailto:".count)) : url.absoluteString
            var attributes = typingAttributes
            attributes[NoteFormat.linkKey] = url.absoluteString
            replace(selectedRange(), with: NSAttributedString(string: shown, attributes: attributes))
            setTyping(NoteFormat.typingAttributes(typingAttributes, at: selectedRange().location, in: storage))
            return
        }
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        if let url {
            storage.addAttribute(NoteFormat.linkKey, value: url.absoluteString, range: range)
        } else {
            storage.removeAttribute(NoteFormat.linkKey, range: range)
        }
        storage.endEditing()
        didChangeText()
    }

    /// The paragraphs the selection touches. Empty lines of a longer selection are left out.
    private var selectedParagraphs: [NSRange] {
        let string = self.string as NSString
        let span = string.paragraphRange(for: selectedRange())
        var paragraphs: [NSRange] = []
        var location = span.location
        repeat {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            paragraphs.append(paragraph)
            location = paragraph.upperBound
        } while location < span.upperBound && paragraphs.last!.length > 0
        if paragraphs.count > 1 {
            paragraphs.removeAll { string.substring(with: $0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        return paragraphs
    }

    /// Turns the selected paragraphs into list items, or back into plain paragraphs if they all
    /// are items of that kind already. An item that changes kind keeps its text; a checklist
    /// item that already is one keeps its check.
    func toggleList(_ kind: ListMarker.Kind) {
        guard isEditable else { return }
        let string = self.string as NSString
        let selection = selectedRange()
        let paragraphs = selectedParagraphs
        let markers = paragraphs.map { ListMarker.marker(in: string, paragraph: $0) }
        let removing = !markers.isEmpty && markers.allSatisfy { $0?.kind == kind }

        undoManager?.beginUndoGrouping()
        var end = selection.upperBound
        for (index, paragraph) in paragraphs.enumerated().reversed() {
            if !removing, kind == .checklist, markers[index]?.kind == .checklist { continue }
            let old = NSRange(location: paragraph.location, length: markers[index]?.text.utf16.count ?? 0)
            let new = removing ? "" : ListMarker.text(kind, number: index + 1)
            replace(old, with: NSAttributedString(string: new, attributes: typingAttributes))
            end += new.utf16.count - old.length
        }
        undoManager?.endUndoGrouping()
        setSelectedRange(NSRange(location: min(max(end, 0), (self.string as NSString).length), length: 0))
    }

    // MARK: Checklists

    /// The checklist item under the cursor is done (the first one, for a selection); nil: the
    /// cursor isn't in a checklist.
    var isChecked: Bool? {
        let string = self.string as NSString
        return selectedParagraphs.lazy.compactMap { ListMarker.marker(in: string, paragraph: $0)?.checked }.first
    }

    /// Checks the checklist items of the selection — or unchecks them, if they all are checked.
    func toggleChecked() {
        guard isEditable else { return }
        let string = self.string as NSString
        let items = selectedParagraphs.filter { ListMarker.marker(in: string, paragraph: $0)?.checked != nil }
        guard !items.isEmpty else { return }
        let checked = !items.allSatisfy { ListMarker.marker(in: string, paragraph: $0)?.checked == true }
        undoManager?.beginUndoGrouping()
        // Both markers are as long: nothing moves.
        for item in items { setChecked(checked, at: item.location) }
        undoManager?.endUndoGrouping()
        sortChecklistsSoon(around: items.map(\.location))
    }

    /// A click at `point` (in the view): true if it was on the box of a checklist item, which
    /// it checked or unchecked.
    func toggleCheckbox(at point: NSPoint) -> Bool {
        guard isEditable, let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return false }
        let origin = textContainerOrigin
        let index = layoutManager.characterIndex(for: NSPoint(x: point.x - origin.x, y: point.y - origin.y), in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
        let string = storage.string as NSString
        let paragraph = string.paragraphRange(for: NSRange(location: min(index, string.length), length: 0))
        guard let checked = ListMarker.marker(in: string, paragraph: paragraph)?.checked,
              checkboxRect(at: paragraph.location)?.insetBy(dx: -4, dy: -4).contains(point) == true
        else { return false }
        setChecked(!checked, at: paragraph.location)
        sortChecklistsSoon(around: [paragraph.location])
        return true
    }

    /// Items just checked or unchecked, whose lists are to be put in order.
    private var unsortedItems: [Int] = []
    /// The text as it was when they were: typed in since, it is left as it is.
    private var unsortedText = ""
    private var sortRequest = 0

    /// A moment after an item is checked (time to see it checked), it goes down to the end of
    /// what is still to do, as in Apple Notes; unchecked, it goes back up there. Several items
    /// checked in a row move together.
    private func sortChecklistsSoon(around locations: [Int]) {
        unsortedItems += locations
        unsortedText = string
        sortRequest += 1
        let request = sortRequest
        DispatchQueue.main.asyncAfter(deadline: .now() + NoteFormat.checklistSortDelay) { [weak self] in
            guard let self, self.sortRequest == request else { return }
            self.sortChecklists()
        }
    }

    private func sortChecklists() {
        let locations = unsortedItems
        unsortedItems = []
        guard isEditable, string == unsortedText else { return }
        var sorted = Set<Int>()
        // The lines change places in a quick cross-fade.
        if let layer = enclosingScrollView?.contentView.layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.25
            layer.add(fade, forKey: "sort")
        }
        undoManager?.beginUndoGrouping()
        // Sorting keeps the length of the text: the other locations stay right.
        for location in locations {
            guard let storage = textStorage, let sort = ChecklistSort(storage, around: location), sorted.insert(sort.range.location).inserted else { continue }
            let selection = selectedRange()
            replace(sort.range, with: sort.text)
            // The cursor follows the item it was in.
            let start = sort.moved(selection.location), end = sort.moved(selection.upperBound)
            setSelectedRange(end - start == selection.length ? NSRange(location: start, length: selection.length) : NSRange(location: start, length: 0))
        }
        undoManager?.endUndoGrouping()
    }

    /// Changes the marker of the checklist item that starts at `location`; the cursor stays.
    private func setChecked(_ checked: Bool, at location: Int) {
        guard let storage = textStorage, location < storage.length else { return }
        let selection = selectedRange()
        let box = String((checked ? NoteFormat.checked : NoteFormat.unchecked).prefix(1))
        replace(NSRange(location: location, length: 1), with: NSAttributedString(string: box, attributes: storage.attributes(at: location, effectiveRange: nil)))
        setSelectedRange(selection)
    }

    /// Where the box of the checklist item that starts at `location` is drawn, in the view: in
    /// place of its character, centered on the capitals of the line.
    func checkboxRect(at location: Int) -> NSRect? {
        guard let storage = textStorage, let layoutManager, location < storage.length else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: location)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let position = layoutManager.location(forGlyphAt: glyph)
        let font = NoteFormat.font(block: NoteFormat.block(in: storage.attributes(at: location, effectiveRange: nil)), weight: nil, italic: false)
        let side = NoteFormat.boxSide(font)
        let origin = textContainerOrigin
        let middle = origin.y + line.minY + position.y - font.capHeight / 2
        return NSRect(x: round(origin.x + line.minX + position.x), y: round(middle - side / 2), width: side, height: side)
    }

    /// A box in place of each checklist marker: empty for what is to do, filled with the accent
    /// color and checked for what is done.
    private func drawCheckboxes(in dirtyRect: NSRect) {
        guard let storage = textStorage, let layoutManager, let textContainer, storage.length > 0 else { return }
        let string = storage.string as NSString
        let origin = textContainerOrigin
        let glyphs = layoutManager.glyphRange(forBoundingRect: dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y), in: textContainer)
        let shown = string.paragraphRange(for: layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
        var location = shown.location
        while location < shown.upperBound {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            guard paragraph.length > 0 else { break }
            location = paragraph.upperBound
            guard let checked = ListMarker.marker(in: string, paragraph: paragraph)?.checked, let box = checkboxRect(at: paragraph.location) else { continue }
            let radius = box.width * 0.28
            if checked {
                Theme.accentNS(accent).setFill()
                NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius).fill()
                let check = NSBezierPath()
                check.move(to: NSPoint(x: box.minX + box.width * 0.25, y: box.minY + box.height * 0.53))
                check.line(to: NSPoint(x: box.minX + box.width * 0.43, y: box.minY + box.height * 0.70))
                check.line(to: NSPoint(x: box.minX + box.width * 0.76, y: box.minY + box.height * 0.31))
                check.lineWidth = 1.7
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                Theme.onAccentNS.setStroke()
                check.stroke()
            } else {
                let outline = NSBezierPath(roundedRect: box.insetBy(dx: 0.75, dy: 0.75), xRadius: radius, yRadius: radius)
                outline.lineWidth = 1.5
                Theme.secondaryTextNS.setStroke()
                outline.stroke()
            }
        }
    }

    private func setTyping(_ attributes: [NSAttributedString.Key: Any]) {
        var attributes = attributes
        attributes[NoteFormat.attachmentKey] = nil
        attributes[.attachment] = nil
        let block = NoteFormat.block(in: attributes)
        attributes[.font] = NoteFormat.font(block: block, attributes: attributes)
        attributes[.backgroundColor] = attributes[NoteFormat.highlightKey] != nil ? Theme.highlightNS : attributes[NoteFormat.codeKey] != nil ? Theme.codeBackgroundNS : nil
        attributes[.foregroundColor] = NoteFormat.color(block)
        attributes[.paragraphStyle] = NoteFormat.paragraphStyle(block: block, indent: NoteFormat.indent(in: attributes))
        attributes[.kern] = nil
        attributes[.strikethroughStyle] = attributes[NoteFormat.strikeKey] != nil ? NSUnderlineStyle.single.rawValue : nil
        attributes[.strikethroughColor] = nil
        // Worked out from `NoteFormat.linkKey` once typed.
        attributes[.link] = nil
        attributes[.toolTip] = nil
        isSettingTypingAttributes = true
        typingAttributes = attributes
        isSettingTypingAttributes = false
        updateInsertionPointStateAndRestartTimer(true)
        needsDisplay = true
    }

    /// AppKit takes the typing attributes from the character before the cursor. On an empty last
    /// line that is the previous line's break: without this, the line after a title would be a
    /// title too. An empty note starts with its title.
    func textView(_ textView: NSTextView, shouldChangeTypingAttributes oldTypingAttributes: [String: Any] = [:],
                  toAttributes newTypingAttributes: [NSAttributedString.Key: Any] = [:]) -> [NSAttributedString.Key: Any] {
        guard !isSettingTypingAttributes, let storage = textStorage else { return newTypingAttributes }
        // What is typed after an image is text, not the image again.
        var newTypingAttributes = newTypingAttributes
        newTypingAttributes[NoteFormat.attachmentKey] = nil
        newTypingAttributes[.attachment] = nil
        // Nor the room kept after a checklist box, nor the line through a done item.
        newTypingAttributes[.kern] = nil
        newTypingAttributes[.strikethroughStyle] = newTypingAttributes[NoteFormat.strikeKey] != nil ? NSUnderlineStyle.single.rawValue : nil
        newTypingAttributes[.strikethroughColor] = nil
        if storage.length == 0, startsWithTitle { return NoteFormat.attributes(block: .title) }
        let selection = selectedRange()
        // At the end of a link, what is typed isn't part of it.
        newTypingAttributes = NoteFormat.typingAttributes(newTypingAttributes, at: selection.location, in: storage)
        if selection.length == 0, selection.location == storage.length, storage.string.last?.isNewline == true,
           NoteFormat.block(in: newTypingAttributes)?.isSingleLine == true {
            return NoteFormat.attributes(block: nil)
        }
        return newTypingAttributes
    }

    // MARK: Pasting

    /// Text comes in as plain text (pasted or dropped): a note keeps Void Notes' own formatting.
    /// Files and images come in as attachments.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string, .fileURL, .png, .tiff] }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        guard isEditable else { return }
        // Files copied in the Finder.
        let files = Self.files(in: pasteboard)
        if !files.isEmpty { return attach(files: files) }
        // An image copied from a page or a picture editor (not text that also has a picture).
        if pasteboard.string(forType: .string) == nil, let data = Self.png(in: pasteboard) {
            if let addPhotoData { return addPhotoData(data, "Image.png") }
            if let name = attachData?(data, "Image.png") { return insertAttachments([name], at: selectedRange()) }
        }
        pasteText(readingMarkdown: true)
    }

    /// ⌘V: text written in Markdown comes in formatted — titles, lists, bold, links… — the
    /// marks gone. ⌥⇧⌘V (Coller et conserver le style) keeps it as it is, marks included.
    override func pasteAsPlainText(_ sender: Any?) {
        pasteText(readingMarkdown: false)
    }

    func pasteText(readingMarkdown: Bool) {
        guard isEditable, let pasted = NSPasteboard.general.string(forType: .string), !pasted.isEmpty else { return }
        // The character of an image copied from a note comes without its file.
        let text = pasted.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: String(NoteText.attachmentCharacter), with: "")
        guard !text.isEmpty else { return }
        if readingMarkdown, NoteMarkdown.looksLikeMarkdown(text) { return pasteMarkdown(text) }
        let piece = NSMutableAttributedString(string: text, attributes: typingAttributes)
        // Pasted into a title, only the first line is part of the title.
        if currentBlock?.isHeading == true, let firstBreak = text.firstIndex(of: "\n") {
            let rest = NSRange(firstBreak..., in: text)
            piece.setAttributes(NoteFormat.attributes(block: nil), range: NSRange(location: rest.location + 1, length: rest.length - 1))
        }
        replace(selectedRange(), with: piece)
    }

    /// Markdown pasted: formatted as the note would have it. Its first line goes on the line of
    /// the cursor, in its kind (a title stays a title).
    private func pasteMarkdown(_ markdown: String) {
        let piece = NoteMarkdown.pasted(markdown, typing: typingAttributes, startsLine: startsLine(selectedRange().location))
        replace(selectedRange(), with: piece)
    }

    /// Nothing comes before `location` on its line.
    private func startsLine(_ location: Int) -> Bool {
        location == 0 || (string as NSString).character(at: location - 1) == 10
    }

    // MARK: Attachments

    /// Folder of the files joined to the note.
    var attachmentsDirectory: URL?
    /// Copies a file into that folder and returns the name it has there.
    var attachFile: ((URL) -> String?)?
    /// The same for a pasted image.
    var attachData: ((Data, String) -> String?)?
    /// Adds images to the note's album. nil (and `addPhotoData` too): images go in the text,
    /// like any other file.
    var addPhotos: (([URL]) -> Void)?
    var addPhotoData: ((Data, String) -> Void)?

    private static func files(in pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    private static func png(in pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff), let image = NSBitmapImageRep(data: tiff) else { return nil }
        return image.representation(using: .png, properties: [:])
    }

    /// "Joindre un fichier…": images and files chosen in a panel go where the cursor is.
    func chooseAttachments() {
        guard isEditable, let window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Joindre"
        panel.message = "Images, PDF ou tout autre fichier : ils partent avec le message."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            self?.attach(files: panel.urls)
            self?.focus()
        }
    }

    /// "Ajouter des images…": the images chosen in a panel go to the note's album.
    func choosePhotos() {
        guard isEditable, let window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Ajouter"
        panel.message = "Les images vont dans l'album de la note, sous son titre : une copie est gardée avec elle."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            self?.attach(files: panel.urls)
            self?.focus()
        }
    }

    /// Copies the files next to the note: the images go to its album, the others show at `range`
    /// (nil: at the cursor).
    func attach(files: [URL], at range: NSRange? = nil) {
        guard isEditable else { return }
        // A folder isn't a file to join.
        var files = files.filter { !$0.hasDirectoryPath }
        if let addPhotos {
            let images = files.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
            if !images.isEmpty { addPhotos(images) }
            files.removeAll { images.contains($0) }
        }
        insertAttachments(files.compactMap { attachFile?($0) }, at: range ?? selectedRange())
    }

    /// Each file on a line of its own, in body text; the cursor ends up on the line after them.
    func insertAttachments(_ names: [String], at range: NSRange) {
        guard isEditable, !names.isEmpty else { return }
        let string = self.string as NSString
        let body = NoteFormat.attributes(block: nil)
        let piece = NSMutableAttributedString()
        if range.location > 0, string.character(at: range.location - 1) != 10 { piece.append(NSAttributedString(string: "\n", attributes: body)) }
        for name in names {
            piece.append(NoteAttachmentCell.character(name: name, directory: attachmentsDirectory))
            piece.append(NSAttributedString(string: "\n", attributes: body))
        }
        // Already followed by a line break: no empty line is added.
        if range.upperBound < string.length, string.character(at: range.upperBound) == 10 { piece.deleteCharacters(in: NSRange(location: piece.length - 1, length: 1)) }
        replace(range, with: piece)
        if selectedRange().location < (self.string as NSString).length, (self.string as NSString).character(at: selectedRange().location) == 10 {
            setSelectedRange(NSRange(location: selectedRange().location + 1, length: 0))
        }
        setTyping(body)
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.fileURL]
    }

    /// Files dropped on the text are joined where they are dropped.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = Self.files(in: sender.draggingPasteboard)
        guard isEditable, !files.isEmpty else { return super.performDragOperation(sender) }
        let index = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        attach(files: files, at: NSRange(location: index, length: 0))
        window?.makeFirstResponder(self)
        return true
    }

    /// A click on an image or a file selects it; a double click opens it in its app.
    func textView(_ textView: NSTextView, clickedOn cell: NSTextAttachmentCellProtocol, in cellFrame: NSRect, at charIndex: Int) {
        setSelectedRange(NSRange(location: charIndex, length: 1))
    }

    func textView(_ textView: NSTextView, doubleClickedOn cell: NSTextAttachmentCellProtocol, in cellFrame: NSRect, at charIndex: Int) {
        guard let url = (cell as? NoteAttachmentCell)?.url, FileManager.default.fileExists(atPath: url.path) else { return NSSound.beep() }
        NSWorkspace.shared.open(url)
    }

    // MARK: Search

    /// The words searched for in the list: shown in the note on a soft background while the
    /// search lasts; the first one is brought into view when the note opens.
    var searchWords: [String] = [] {
        didSet {
            guard searchWords != oldValue else { return }
            showFound()
            if oldValue.isEmpty, let first = NoteText.found(searchWords, in: string).first {
                // Once the view is in its window and laid out.
                DispatchQueue.main.async { [weak self] in self?.scrollRangeToVisible(first) }
            }
        }
    }

    /// Laid over the text by the layout manager: neither saved nor part of the undo history.
    private func showFound() {
        guard let layoutManager, let storage = textStorage else { return }
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: storage.length))
        let color = Theme.accentNS(accent).withAlphaComponent(0.3)
        for range in NoteText.found(searchWords, in: storage.string) {
            layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range)
        }
    }

    // MARK: Printing

    /// ⌘P: the note on paper — or in a PDF, from the print panel — in the light theme, with its
    /// dates, boxes and quote bars, without the controls or the album.
    func printNote(title: String) {
        guard let storage = textStorage, let window else { return }
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        // The view keeps its own margin on each side.
        info.leftMargin = 36
        info.rightMargin = 36
        info.topMargin = 36
        info.bottomMargin = 36
        let (_, paper) = Self.makeScrollable()
        paper.appearance = NSAppearance(named: .aqua)
        paper.setProofreading(spelling: false, grammar: false)
        paper.isEditable = false
        paper.isSelectable = false
        paper.accent = accent
        paper.meta = meta
        paper.textStorage?.setAttributedString(storage)
        paper.frame = NSRect(x: 0, y: 0, width: info.paperSize.width - info.leftMargin - info.rightMargin, height: 10)
        paper.sizeToFit()
        let operation = NSPrintOperation(view: paper, printInfo: info)
        operation.jobTitle = title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    // MARK: Layout and drawing

    /// Controls shown at the end of the first line (formatting, delete). The text makes room
    /// for them: a long title goes to the next line rather than under them. Once the title has
    /// scrolled away, they stay at the top of what is shown.
    var accessory: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let accessory { addSubview(accessory) }
            layoutAccessory()
        }
    }

    /// Told when the controls start or stop floating over the text.
    var accessoryFloats: ((Bool) -> Void)?
    private var accessoryFloating = false

    /// Scrolling moves the controls along, to keep them in sight.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        guard let clip = superview as? NSClipView else { return }
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipViewScrolled), name: NSView.boundsDidChangeNotification, object: clip)
    }

    @objc private func clipViewScrolled() {
        layoutAccessory()
    }

    /// The note's album of images, shown under the dates. The text makes room for it.
    var album: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            // Under the controls, which may float over it.
            if let album { addSubview(album, positioned: .below, relativeTo: accessory) }
            needsLayout = true
        }
    }

    /// Height the album takes; 0: the note has no image.
    var albumHeight: CGFloat = 0 {
        didSet { if albumHeight != oldValue { needsLayout = true } }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let margin = max(Self.minimumMargin, floor((newSize.width - Self.columnWidth) / 2))
        if textContainerInset.width != margin {
            textContainerInset = NSSize(width: margin, height: Self.topMargin)
        }
        layoutAccessory()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        layoutAlbum()
    }

    /// The album goes under the dates; the text that follows the first paragraph starts below it.
    private func layoutAlbum() {
        guard let textContainer else { return }
        let accessoryRoom = textContainer.exclusionPaths.first.map { [$0] } ?? []
        guard let album, albumHeight > 0, var place = metaPlace() else {
            album?.isHidden = true
            if textContainer.exclusionPaths.count > accessoryRoom.count { textContainer.exclusionPaths = accessoryRoom }
            if minSize.height != 0 { minSize.height = 0 }
            return
        }
        let padding = textContainer.lineFragmentPadding
        var top: CGFloat = 0
        // The room kept for the album moves the text, the first paragraph included when it has
        // just grown into that room: measured again until it stays where it is.
        for _ in 0..<4 {
            // Under the dates, as far from them whether text follows the title or not.
            top = max(place.bottom, place.top + NoteFormat.metaSpace + 10) + 8
            let room = NSRect(x: 0, y: place.bottom + 1, width: textContainer.size.width, height: top + albumHeight + 8 - place.bottom - 1)
            if textContainer.exclusionPaths.count == accessoryRoom.count + 1, textContainer.exclusionPaths.last?.bounds == room { break }
            textContainer.exclusionPaths = accessoryRoom + [NSBezierPath(rect: room)]
            guard let moved = metaPlace(), moved != place else { break }
            place = moved
        }
        let origin = textContainerOrigin
        let frame = NSRect(x: origin.x + padding, y: origin.y + top, width: textContainer.size.width - 2 * padding, height: albumHeight)
        if album.frame != frame { album.frame = frame }
        album.isHidden = false
        // A note that is only a title is as tall as its album.
        let height = frame.maxY + Self.topMargin
        if minSize.height != height {
            minSize.height = height
            sizeToFit()
        }
    }

    /// Where the dates are written, in the text container: `top`, where their room starts, and
    /// `bottom`, the end of the first paragraph's last line. nil: the paragraph isn't laid out.
    private func metaPlace() -> (top: CGFloat, bottom: CGFloat)? {
        guard let storage = textStorage, let layoutManager else { return nil }
        if storage.length == 0 {
            let line = layoutManager.extraLineFragmentRect.maxY
            return (max(line, NoteFormat.size(.title) + 8), max(line, NoteFormat.size(.title) + 8))
        }
        let first = (storage.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
        let glyphs = layoutManager.glyphRange(forCharacterRange: first, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyphs.upperBound - 1, effectiveRange: nil)
        var y = line.maxY
        // The room kept under the paragraph is part of its last line — except when the
        // paragraph is the whole note: nothing follows, nothing is kept.
        let style = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        if first.upperBound < storage.length || storage.string.last?.isNewline == true {
            y -= style?.paragraphSpacing ?? 0
        } else {
            // Nor the line spacing: added here, so the dates don't move when Return is pressed.
            y += style?.lineSpacing ?? 0
        }
        return (y, line.maxY)
    }

    private func layoutAccessory() {
        guard let accessory, let textContainer else { return }
        // The controls' own room around them (for their background when floating) stays out of
        // the column.
        let inset = NoteTextView.accessoryInset
        let size = accessory.fittingSize
        let padding = textContainer.lineFragmentPadding
        let place = Self.topMargin + 4 - inset
        // Scrolled past their place: at the top of what is shown, a little below it.
        let top = visibleRect.minY + 10
        let floating = top > place
        let frame = NSRect(x: bounds.width - textContainerInset.width - padding - size.width + inset, y: max(place, top), width: size.width, height: size.height)
        if accessory.frame != frame { accessory.frame = frame }
        if floating != accessoryFloating {
            accessoryFloating = floating
            accessoryFloats?(floating)
        }
        let column = bounds.width - 2 * textContainerInset.width
        let room = NSRect(x: column - padding - (size.width - 2 * inset) - 10, y: 0, width: size.width - 2 * inset + padding + 10, height: size.height - 2 * inset + 4)
        if textContainer.exclusionPaths.first?.bounds != room { textContainer.exclusionPaths = [NSBezierPath(rect: room)] }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawQuoteBars()
        drawDividers()
        drawCheckboxes(in: dirtyRect)
        drawProofMarks(in: dirtyRect)
        drawMeta()
        if string.isEmpty { drawPlaceholder() }
    }

    /// A line across the column in place of each divider's dashes.
    private func drawDividers() {
        guard let storage = textStorage, let layoutManager, let textContainer else { return }
        let string = storage.string as NSString
        let origin = textContainerOrigin
        let x = origin.x + textContainer.lineFragmentPadding
        let width = textContainer.size.width - 2 * textContainer.lineFragmentPadding
        Theme.dividerNS.setFill()
        storage.enumerateAttribute(NoteFormat.blockKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value as? String == NoteBlock.divider.rawValue else { return }
            // Dividers that follow each other share the attribute: one line per paragraph.
            var location = range.location
            while location < range.upperBound {
                let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
                guard paragraph.length > 0 else { break }
                let dashes = layoutManager.glyphRange(forCharacterRange: NSRange(location: paragraph.location, length: 1), actualCharacterRange: nil)
                let rect = layoutManager.boundingRect(forGlyphRange: dashes, in: textContainer)
                NSRect(x: x, y: origin.y + rect.minY + floor(NoteFormat.bodySize * 0.7), width: width, height: 1).fill()
                location = paragraph.upperBound
            }
        }
    }

    /// The dates, under the first paragraph: `restyle` keeps `NoteFormat.metaSpace` free there.
    private func drawMeta() {
        guard !meta.isEmpty, let textContainer, let y = metaPlace()?.top else { return }
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        let origin = textContainerOrigin
        let rect = NSRect(x: origin.x + textContainer.lineFragmentPadding, y: origin.y + y + 3,
                          width: textContainer.size.width - 2 * textContainer.lineFragmentPadding, height: 16)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: NoteFormat.metaSize, weight: .regular),
            .foregroundColor: Theme.secondaryTextNS,
            .paragraphStyle: truncating,
        ]
        (meta as NSString).draw(in: rect, withAttributes: attributes)
        let written = NSRect(x: rect.minX, y: rect.minY, width: min(ceil((meta as NSString).size(withAttributes: attributes).width), rect.width), height: rect.height)
        if written != metaToolTipRect, !metaHelp.isEmpty {
            if let metaToolTip { removeToolTip(metaToolTip) }
            metaToolTip = addToolTip(written, owner: metaToolTipOwner, userData: nil)
            metaToolTipRect = written
        }
    }

    /// A bar in the accent color along each quote.
    private func drawQuoteBars() {
        guard let storage = textStorage, let layoutManager, let textContainer else { return }
        let origin = textContainerOrigin
        let x = origin.x + textContainer.lineFragmentPadding
        var bars: [NSRect] = []
        storage.enumerateAttribute(NoteFormat.blockKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value as? String == NoteBlock.quote.rawValue else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            bars.append(NSRect(x: x, y: origin.y + rect.minY + 2, width: 3, height: max(rect.height - 5, 8)))
        }
        // A quote just started on the empty last line has no character yet.
        if NoteFormat.block(in: typingAttributes) == .quote, selectedRange().location == storage.length {
            let extra = layoutManager.extraLineFragmentRect
            if extra.height > 0 { bars.append(NSRect(x: x, y: origin.y + extra.minY + 2, width: 3, height: max(extra.height - 5, 8))) }
        }
        Theme.accentNS(accent).setFill()
        for bar in bars {
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    private func drawPlaceholder() {
        let block = NoteFormat.block(in: typingAttributes)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NoteFormat.font(block: block, weight: nil, italic: false),
            .foregroundColor: Theme.secondaryTextNS.withAlphaComponent(0.55),
        ]
        let origin = textContainerOrigin
        let x = origin.x + (textContainer?.lineFragmentPadding ?? 0) + (block == .quote ? NoteFormat.quoteIndent : 0)
        ((block == .title ? "Titre" : "Écrivez…") as NSString).draw(at: NSPoint(x: x, y: origin.y), withAttributes: attributes)
    }
}

/// Gives the tooltip of the dates its text (the text view keeps its own tooltips, the links').
private final class MetaToolTipOwner: NSObject, NSViewToolTipOwner {
    var text = ""

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String { text }
}
