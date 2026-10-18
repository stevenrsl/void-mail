#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// How a note's text is formatted. The text view only carries a few "semantic" attributes —
/// the paragraph's kind, bold or another weight, italic, highlighting — and they are all that is
/// saved. Fonts, colors and paragraph styles are worked out from them (`restyle`), so a note
/// follows the theme. System font only; no color to choose.
enum NoteFormat {
    static let blockKey = NSAttributedString.Key("void.block")
    static let boldKey = NSAttributedString.Key("void.bold")
    static let italicKey = NSAttributedString.Key("void.italic")
    /// A weight other than bold (`NoteWeight` raw value); never together with `boldKey`.
    static let weightKey = NSAttributedString.Key("void.weight")
    static let highlightKey = NSAttributedString.Key("void.highlight")
    /// On the character that stands for a joined file (`Note.attachmentCharacter`): its name.
    /// The character also carries the `.attachment` that draws it (`NoteAttachmentCell`).
    static let attachmentKey = NSAttributedString.Key("void.attachment")
    /// The address a stretch of text opens (a string). The text view shows it as a link
    /// (`.link`, underlined in the accent color), worked out by `restyle`.
    static let linkKey = NSAttributedString.Key("void.link")
    /// Struck through (`~~texte~~`).
    static let strikeKey = NSAttributedString.Key("void.strike")
    /// Inline code (`` `texte` ``).
    static let codeKey = NSAttributedString.Key("void.code")
    /// On a whole list item: how many steps it is indented (an Int, 1 to `maxIndent`).
    static let indentKey = NSAttributedString.Key("void.indent")
    /// Tab indents a list item this many steps at most.
    static let maxIndent = 4
    /// Width of one step of indentation.
    static let indentStep: CGFloat = 22

    /// A little larger on iPhone, read from closer and touched with a finger.
    #if os(macOS)
    static let bodySize: CGFloat = 15
    /// Size of the dates under the title, and of a source line.
    static let metaSize: CGFloat = 11
    private static let headingSizes: (title: CGFloat, heading: CGFloat, subheading: CGFloat) = (26, 20, 16.5)
    #else
    /// On iPhone they follow the text size chosen in iOS (Dynamic Type), up to twice as large.
    static var bodySize: CGFloat { scaled(17) }
    static var metaSize: CGFloat { scaled(12) }
    private static var headingSizes: (title: CGFloat, heading: CGFloat, subheading: CGFloat) { (scaled(28), scaled(22), scaled(19)) }
    private static func scaled(_ size: CGFloat) -> CGFloat { min(UIFontMetrics(forTextStyle: .body).scaledValue(for: size), size * 2).rounded() }
    #endif
    static let bullet = "• "
    /// Markers of a checklist item, to do and done. The view draws a box over their first
    /// character; a click on it goes from one to the other.
    static let unchecked = "☐ "
    /// Seconds between checking an item and its going down the list.
    static let checklistSortDelay: Double = 0.5
    static let checked = "☑ "
    /// Text of a divider paragraph. It stays in the note (the file reads on its own); the view
    /// draws a line over it.
    static let rule = "---"

    // MARK: Appearance

    static func size(_ block: NoteBlock?) -> CGFloat {
        switch block {
        case .title: headingSizes.title
        case .heading: headingSizes.heading
        case .subheading: headingSizes.subheading
        case .source: metaSize
        case .quote, .divider, nil: bodySize
        }
    }

    /// `weight` nil: the paragraph's own weight. `code`: monospaced, a little smaller, so it
    /// sits in the line.
    static func font(block: NoteBlock?, weight: NoteWeight?, italic: Bool, code: Bool = false) -> PlatformFont {
        let own: PlatformFont.Weight = switch block {
        case .title: .bold
        case .heading, .subheading: .semibold
        case .quote, .divider, .source, nil: .regular
        }
        let fontWeight: PlatformFont.Weight = switch weight {
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        // Bold still stands out in a title.
        case .bold: block?.isHeading == true ? .heavy : .bold
        case nil: own
        }
        let font = block == .source ? PlatformFont.monospacedSystemFont(ofSize: size(block), weight: fontWeight)
            : code ? PlatformFont.monospacedSystemFont(ofSize: round(size(block) * 0.9 * 2) / 2, weight: fontWeight)
            : PlatformFont.systemFont(ofSize: size(block), weight: fontWeight)
        guard italic else { return font }
        #if canImport(AppKit)
        return PlatformFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: font.pointSize) ?? font
        #else
        return font.fontDescriptor.withSymbolicTraits(.traitItalic).map { PlatformFont(descriptor: $0, size: font.pointSize) } ?? font
        #endif
    }

    static func color(_ block: NoteBlock?) -> PlatformColor {
        switch block {
        case .quote, .source: Theme.secondaryTextNS
        // The dashes of a divider don't show: the line is drawn by the view.
        case .divider: .clear
        default: Theme.primaryTextNS
        }
    }

    #if canImport(AppKit)
    private static let lineMeasure = NSLayoutManager()
    private static func lineHeight(_ font: PlatformFont) -> CGFloat { lineMeasure.defaultLineHeight(for: font) }
    #else
    private static func lineHeight(_ font: PlatformFont) -> CGFloat { font.lineHeight }
    #endif
    /// Room between a checklist box and the space that follows it.
    static let boxGap: CGFloat = 3
    static let boxCharacterSize: CGFloat = 6
    /// Side of a checklist box in a paragraph of that font.
    static func boxSide(_ font: PlatformFont) -> CGFloat { round(font.pointSize * 0.93) }

    /// Left margin of a quote, where its bar is drawn.
    static let quoteIndent: CGFloat = 16
    /// Room kept under the first paragraph of a note, where the view writes its dates.
    static var metaSpace: CGFloat { metaSize + 15 }

    /// `markerWidth`: width of the paragraph's list marker, so wrapped lines align with the
    /// text rather than with the bullet. `first`: the note's first paragraph. `fixedLine`: the
    /// lines are as tall as the paragraph's own font makes them, whatever font a character
    /// comes from (the box of a checklist item isn't in the system font).
    /// `indent`: steps of indentation of a list item.
    static func paragraphStyle(block: NoteBlock?, markerWidth: CGFloat = 0, first: Bool = false, fixedLine: Bool = false, indent: Int = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        if fixedLine {
            let height = ceil(lineHeight(font(block: block, weight: nil, italic: false)))
            style.minimumLineHeight = height
            style.maximumLineHeight = height
        }
        switch block {
        case .title:
            style.paragraphSpacing = 10
        case .heading:
            style.paragraphSpacingBefore = 14
            style.paragraphSpacing = 6
        case .subheading:
            style.paragraphSpacingBefore = 10
            style.paragraphSpacing = 4
        case .quote:
            style.firstLineHeadIndent = quoteIndent
            // A quote breathes apart from the text around it.
            style.paragraphSpacingBefore = 6
            style.paragraphSpacing = 14
        case .divider, .source, nil:
            style.paragraphSpacing = 6
        }
        if first { style.paragraphSpacing += metaSpace }
        style.firstLineHeadIndent += CGFloat(indent) * indentStep
        style.headIndent = style.firstLineHeadIndent + markerWidth
        return style
    }

    /// What a stretch of plain text of that kind carries: the semantic attribute and its look.
    static func attributes(block: NoteBlock?) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(block: block, weight: nil, italic: false),
            .foregroundColor: color(block),
            .paragraphStyle: paragraphStyle(block: block),
        ]
        if let block { attributes[blockKey] = block.rawValue }
        return attributes
    }

    static func block(in attributes: [NSAttributedString.Key: Any]) -> NoteBlock? {
        (attributes[blockKey] as? String).flatMap(NoteBlock.init)
    }

    static func weight(in attributes: [NSAttributedString.Key: Any]) -> NoteWeight? {
        if attributes[boldKey] != nil { return .bold }
        return (attributes[weightKey] as? String).flatMap(NoteWeight.init)
    }

    /// Steps of indentation of the list item that starts at `location`; 0: none.
    static func indent(at location: Int, in text: NSAttributedString) -> Int {
        guard location < text.length else { return 0 }
        return indent(in: text.attributes(at: location, effectiveRange: nil))
    }

    static func indent(in attributes: [NSAttributedString.Key: Any]) -> Int {
        min(max(attributes[indentKey] as? Int ?? 0, 0), maxIndent)
    }

    /// The attribute a style typed between marks gives its text.
    static func key(of style: TypingRules.InlineStyle) -> NSAttributedString.Key {
        switch style {
        case .bold: boldKey
        case .italic: italicKey
        case .highlight: highlightKey
        case .strike: strikeKey
        case .code: codeKey
        }
    }

    /// The font a stretch of text with those semantic attributes is shown in.
    static func font(block: NoteBlock?, attributes: [NSAttributedString.Key: Any]) -> PlatformFont {
        font(block: block, weight: weight(in: attributes), italic: attributes[italicKey] != nil, code: attributes[codeKey] != nil)
    }

    /// Makes the paragraphs touching `range` consistent, then gives them their look: a paragraph
    /// has one kind (that of its first character — after two paragraphs are joined, or text is
    /// pasted), and its font, color and indents follow from the semantic attributes.
    static func restyle(_ text: NSMutableAttributedString, in range: NSRange) {
        let string = text.string as NSString
        guard string.length > 0 else { return }
        let start = min(range.location, string.length)
        var paragraphs = string.paragraphRange(for: NSRange(location: start, length: min(range.length, string.length - start)))
        // The first paragraph keeps room under it for the dates. When it changes, the one that
        // follows may have been the first until now.
        if paragraphs.location == 0, paragraphs.upperBound < string.length {
            paragraphs = NSUnionRange(paragraphs, string.paragraphRange(for: NSRange(location: paragraphs.upperBound, length: 0)))
        }
        var location = paragraphs.location
        while location < paragraphs.upperBound {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            guard paragraph.length > 0 else { break }
            var block = block(in: text.attributes(at: paragraph.location, effectiveRange: nil))
            // A divider is its three dashes and nothing else: typed in, it is body text again.
            if block == .divider, string.substring(with: TypingRules.contentRange(of: paragraph, in: string)) != rule { block = nil }
            if let block {
                text.addAttribute(blockKey, value: block.rawValue, range: paragraph)
            } else {
                text.removeAttribute(blockKey, range: paragraph)
            }
            text.enumerateAttributes(in: paragraph) { attributes, run, _ in
                let font = font(block: block, attributes: attributes)
                if attributes[.font] as? PlatformFont != font { text.addAttribute(.font, value: font, range: run) }
                if attributes[highlightKey] != nil {
                    text.addAttribute(.backgroundColor, value: Theme.highlightNS, range: run)
                } else if attributes[codeKey] != nil {
                    text.addAttribute(.backgroundColor, value: Theme.codeBackgroundNS, range: run)
                } else if attributes[.backgroundColor] != nil {
                    text.removeAttribute(.backgroundColor, range: run)
                }
                if let url = (attributes[linkKey] as? String).flatMap(URL.init(string:)) {
                    if attributes[.link] as? URL != url { text.addAttribute(.link, value: url, range: run) }
                    #if canImport(AppKit)
                    // Its address, when the pointer rests on it.
                    text.addAttribute(.toolTip, value: url.absoluteString, range: run)
                    #else
                    // UIKit leaves the underline of its link attributes out.
                    text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: run)
                    #endif
                } else if attributes[.link] != nil {
                    text.removeAttribute(.link, range: run)
                    #if canImport(AppKit)
                    text.removeAttribute(.toolTip, range: run)
                    #else
                    text.removeAttribute(.underlineStyle, range: run)
                    #endif
                }
            }
            // The break that ends a heading is body-sized: it sets the height of the empty line
            // (and of the cursor) that follows the last heading of a note.
            if block?.isHeading == true, paragraph.length > 1, string.character(at: paragraph.upperBound - 1) == 10 {
                text.addAttribute(.font, value: font(block: nil, weight: nil, italic: false), range: NSRange(location: paragraph.upperBound - 1, length: 1))
            }
            var markerWidth: CGFloat = 0
            let marker = ListMarker.marker(in: string, paragraph: paragraph)
            // Only a list item is indented; the whole item has the indentation of its start.
            let indent = marker == nil ? 0 : indent(at: paragraph.location, in: text)
            if indent > 0 {
                text.addAttribute(indentKey, value: indent, range: paragraph)
            } else {
                text.removeAttribute(indentKey, range: paragraph)
            }
            if let marker {
                let markerFont = text.attribute(.font, at: paragraph.location, effectiveRange: nil) as? PlatformFont ?? font(block: block, weight: nil, italic: false)
                markerWidth = ceil((marker.text as NSString).size(withAttributes: [.font: markerFont]).width)
            }
            // The character under a checklist box is kept small, so that it never moves the
            // line it is on (it comes from another font, and "☑" isn't as tall as "☐"); the
            // room of the box is added after it.
            let boxed = NSRange(location: paragraph.location, length: marker?.checked != nil ? 1 : 0)
            text.enumerateAttribute(.kern, in: paragraph) { value, run, _ in
                if value != nil, run != boxed { text.removeAttribute(.kern, range: run) }
            }
            if boxed.length > 0 {
                let own = font(block: block, weight: nil, italic: false)
                let small: [NSAttributedString.Key: Any] = [.font: PlatformFont.systemFont(ofSize: boxCharacterSize)]
                let room = boxSide(own) + boxGap
                text.addAttributes(small, range: boxed)
                text.addAttribute(.kern, value: room - (string.substring(with: boxed) as NSString).size(withAttributes: small).width, range: boxed)
                markerWidth = ceil(room + (" " as NSString).size(withAttributes: [.font: own]).width)
            }
            text.addAttribute(.paragraphStyle, value: paragraphStyle(block: block, markerWidth: markerWidth, first: paragraph.location == 0, fixedLine: marker?.checked != nil, indent: indent), range: paragraph)
            // What is done steps back.
            text.addAttribute(.foregroundColor, value: marker?.checked == true ? Theme.secondaryTextNS : color(block), range: paragraph)
            // …and is struck through, after its box.
            text.removeAttribute(.strikethroughStyle, range: paragraph)
            text.removeAttribute(.strikethroughColor, range: paragraph)
            let content = TypingRules.contentRange(of: paragraph, in: string)
            if let marker, marker.checked == true, content.length > marker.text.utf16.count {
                let struck = NSRange(location: content.location + marker.text.utf16.count, length: content.length - marker.text.utf16.count)
                text.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .strikethroughColor: Theme.secondaryTextNS], range: struck)
            } else {
                // Text struck through by hand, in the color of the text.
                text.enumerateAttribute(strikeKey, in: content) { value, run, _ in
                    if value != nil { text.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: run) }
                }
            }
            // A bullet or a number steps back: the item's text leads.
            if let marker, marker.checked == nil {
                text.addAttribute(.foregroundColor, value: Theme.secondaryTextNS, range: NSRange(location: paragraph.location, length: min(marker.text.utf16.count, paragraph.length)))
            }
            // The box of a checklist item doesn't show as a character: the view draws it.
            if marker?.checked != nil { text.addAttribute(.foregroundColor, value: PlatformColor.clear, range: NSRange(location: paragraph.location, length: 1)) }
            location = paragraph.upperBound
        }
        // Only its own character shows a file: text typed or joined next to it doesn't.
        let object = (String(NoteText.attachmentCharacter) as NSString).character(at: 0)
        var strays: [NSRange] = []
        text.enumerateAttribute(.attachment, in: paragraphs) { value, run, _ in
            guard value != nil else { return }
            for index in run.location..<run.upperBound where string.character(at: index) != object { strays.append(NSRange(location: index, length: 1)) }
        }
        for stray in strays {
            text.removeAttribute(.attachment, range: stray)
            text.removeAttribute(attachmentKey, range: stray)
        }
    }

    // MARK: Links

    /// The address typed for a link, made one a browser opens: "void.app" is
    /// "https://void.app", "nom@exemple.fr" is "mailto:nom@exemple.fr". nil: not an address.
    static func linkURL(from typed: String) -> URL? {
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !typed.contains(where: \.isWhitespace) else { return nil }
        let address: String
        if typed.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil, !typed.hasPrefix("localhost:") {
            address = typed
        } else if typed.contains("@"), !typed.contains("/") {
            address = "mailto:" + typed
        } else if typed.contains(".") || typed.hasPrefix("localhost") {
            address = "https://" + typed
        } else {
            return nil
        }
        guard let url = URL(string: address), url.scheme != nil else { return nil }
        // "https://" alone, or "https://.": nowhere to go.
        if ["http", "https"].contains(url.scheme?.lowercased()), url.host()?.contains(where: { $0.isLetter || $0.isNumber }) != true { return nil }
        return url
    }

    /// What is typed next, after the cursor moved to `location`: inside a link, it is part of
    /// it; at its end, it isn't (the link doesn't grow as one goes on writing).
    static func typingAttributes(_ attributes: [NSAttributedString.Key: Any], at location: Int, in text: NSAttributedString) -> [NSAttributedString.Key: Any] {
        guard let link = attributes[linkKey] as? String else { return attributes }
        if location < text.length, location > 0, text.attribute(linkKey, at: location, effectiveRange: nil) as? String == link { return attributes }
        var attributes = attributes
        attributes[linkKey] = nil
        attributes[.link] = nil
        #if canImport(AppKit)
        attributes[.toolTip] = nil
        #endif
        return attributes
    }

    /// The link at `location` (or just before it, at its end): its address and its whole text.
    static func link(at location: Int, in text: NSAttributedString) -> (address: String, range: NSRange)? {
        for index in [location, location - 1] where index >= 0 && index < text.length {
            var range = NSRange()
            if let address = text.attribute(linkKey, at: index, longestEffectiveRange: &range, in: NSRange(location: 0, length: text.length)) as? String {
                return (address, range)
            }
        }
        return nil
    }

    // MARK: Saved form

    /// The text as shown in the editor. `attachments`: the folder of the note's joined files.
    static func attributedString(from content: NoteContent, attachments: URL? = nil) -> NSMutableAttributedString {
        let object = (String(NoteText.attachmentCharacter) as NSString).character(at: 0)
        let text = NSMutableAttributedString(string: content.text, attributes: attributes(block: nil))
        for run in content.runs {
            // A file edited by hand may point outside the text.
            let range = NSIntersectionRange(NSRange(location: run.start, length: run.length), NSRange(location: 0, length: text.length))
            guard range.length > 0 else { continue }
            if let block = run.block { text.addAttribute(blockKey, value: block.rawValue, range: range) }
            if run.bold == true || run.weight == .bold {
                text.addAttribute(boldKey, value: true, range: range)
            } else if let weight = run.weight {
                text.addAttribute(weightKey, value: weight.rawValue, range: range)
            }
            if run.italic == true { text.addAttribute(italicKey, value: true, range: range) }
            if run.highlight == true { text.addAttribute(highlightKey, value: true, range: range) }
            if let link = run.link { text.addAttribute(linkKey, value: link, range: range) }
            if run.strike == true { text.addAttribute(strikeKey, value: true, range: range) }
            if run.code == true { text.addAttribute(codeKey, value: true, range: range) }
            if let indent = run.indent, indent > 0 { text.addAttribute(indentKey, value: min(indent, maxIndent), range: range) }
            if let name = run.attachment {
                let string = text.string as NSString
                for index in range.location..<range.upperBound where string.character(at: index) == object {
                    text.addAttributes(NoteAttachmentCell.attributes(name: name, directory: attachments), range: NSRange(location: index, length: 1))
                }
            }
        }
        restyle(text, in: NSRange(location: 0, length: text.length))
        return text
    }

    /// What is saved: the plain text and the semantic attributes, without fonts or colors.
    static func content(from text: NSAttributedString) -> NoteContent {
        var runs: [StyleRun] = []
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            let weight = weight(in: attributes)
            let run = StyleRun(start: range.location, length: range.length, block: block(in: attributes),
                               bold: weight == .bold ? true : nil, italic: attributes[italicKey] != nil ? true : nil,
                               weight: weight == .bold ? nil : weight, highlight: attributes[highlightKey] != nil ? true : nil,
                               attachment: attributes[attachmentKey] as? String, link: attributes[linkKey] as? String,
                               strike: attributes[strikeKey] != nil ? true : nil, code: attributes[codeKey] != nil ? true : nil,
                               indent: indent(in: attributes) > 0 ? indent(in: attributes) : nil)
            guard run.block != nil || run.bold != nil || run.italic != nil || run.weight != nil || run.highlight != nil || run.attachment != nil || run.link != nil
                    || run.strike != nil || run.code != nil || run.indent != nil else { return }
            // Fonts and colors split the runs more finely than what is saved: joined back here
            // (never two files: each has its own character).
            if run.attachment == nil, var joined = runs.last, joined.start + joined.length == run.start {
                joined.start = run.start
                joined.length = run.length
                if joined == run {
                    runs[runs.count - 1].length += run.length
                    return
                }
            }
            runs.append(run)
        }
        return NoteContent(text: text.string, runs: runs)
    }
}

/// List markers at the start of a paragraph: "• " for a bulleted item, "12. " for a numbered one,
/// "☐ " and "☑ " for a checklist item. They are plain characters of the note.
enum ListMarker {
    enum Kind {
        case bullet, numbered, checklist
    }

    struct Item {
        let text: String
        /// Of a numbered item.
        let number: Int?
        /// Of a checklist item: done or not.
        let checked: Bool?

        var kind: Kind { number != nil ? .numbered : checked != nil ? .checklist : .bullet }
    }

    private static let pattern = try! NSRegularExpression(pattern: "^(?:• |[☐☑] |(\\d{1,9})\\. )")

    static func marker(in string: NSString, paragraph: NSRange) -> Item? {
        guard let match = pattern.firstMatch(in: string as String, options: .anchored, range: paragraph) else { return nil }
        let text = string.substring(with: match.range)
        let number = match.range(at: 1).location == NSNotFound ? nil : Int(string.substring(with: match.range(at: 1)))
        return Item(text: text, number: number, checked: text == NoteFormat.checked ? true : text == NoteFormat.unchecked ? false : nil)
    }

    /// The marker a new item of that kind starts with.
    static func text(_ kind: Kind, number: Int = 1) -> String {
        switch kind {
        case .bullet: NoteFormat.bullet
        case .numbered: "\(number). "
        case .checklist: NoteFormat.unchecked
        }
    }
}

/// A checklist whose items were just checked or unchecked, put in order as in Apple Notes: what
/// is still to do first, what is done after it — each in the order it was.
struct ChecklistSort {
    /// The items of the list, the line break after the last one left out.
    let range: NSRange
    /// The same items, in their new order.
    let text: NSAttributedString
    /// Where each item was, and where it goes.
    private let moves: [(from: NSRange, to: Int)]

    /// The list `location` is in, sorted; nil: it isn't in a checklist, or is in order already.
    /// The first paragraph of the note (its title) is never part of a list that moves.
    init?(_ text: NSAttributedString, around location: Int) {
        let string = text.string as NSString
        guard location < string.length else { return nil }
        let start = string.paragraphRange(for: NSRange(location: location, length: 0))
        // An item indented otherwise ends the list that moves: a sub-list stays under its item.
        let level = NoteFormat.indent(at: start.location, in: text)
        func isItem(_ paragraph: NSRange) -> Bool {
            paragraph.location > 0 && paragraph.length > 0 && ListMarker.marker(in: string, paragraph: paragraph)?.checked != nil
                && NoteFormat.indent(at: paragraph.location, in: text) == level
        }
        guard isItem(start) else { return nil }
        var items = [start]
        while items[0].location > 0, case let previous = string.paragraphRange(for: NSRange(location: items[0].location - 1, length: 0)), isItem(previous) {
            items.insert(previous, at: 0)
        }
        while items[items.count - 1].upperBound < string.length, case let next = string.paragraphRange(for: NSRange(location: items[items.count - 1].upperBound, length: 0)), isItem(next) {
            items.append(next)
        }
        // Each item without its line break.
        let lines = items.map { TypingRules.contentRange(of: $0, in: string) }
        let done = lines.map { ListMarker.marker(in: string, paragraph: $0)?.checked == true }
        let order = lines.indices.filter { !done[$0] } + lines.indices.filter { done[$0] }
        guard order != Array(lines.indices) else { return nil }

        let sorted = NSMutableAttributedString()
        var moves: [(NSRange, Int)] = []
        let range = NSRange(location: lines[0].location, length: lines[lines.count - 1].upperBound - lines[0].location)
        for (position, index) in order.enumerated() {
            if position > 0 {
                // The break carries the paragraph's kind, as the item's own one did.
                sorted.append(NSAttributedString(string: "\n", attributes: text.attributes(at: lines[index].location, effectiveRange: nil)))
            }
            moves.append((lines[index], range.location + sorted.length))
            sorted.append(text.attributedSubstring(from: lines[index]))
        }
        self.range = range
        self.text = sorted
        self.moves = moves
    }

    /// Where a location of the text is once the list is sorted: it follows its item.
    func moved(_ location: Int) -> Int {
        guard location >= range.location, location <= range.upperBound else { return location }
        for move in moves where location >= move.from.location && location <= move.from.upperBound {
            return move.to + location - move.from.location
        }
        // On a line break between two items: after the item that comes first.
        return location
    }
}
