import Foundation

/// A note as Markdown, and Markdown as a note: what is exported (a `.md` file that any editor
/// reads), and what is pasted or captured (text written elsewhere keeps its titles, lists, bold…).
/// Only what Void Notes shows is read or written: no tables, no colors.
enum NoteMarkdown {
    // MARK: Export

    /// The note in Markdown. `files`: the folder, next to the `.md` file, where its images and
    /// joined files are copied (their links point there); nil: they are only named.
    static func markdown(from content: NoteContent, photos: [String] = [], files: String? = nil) -> String {
        let text = semantic(content)
        let string = text.string as NSString
        var out = ""
        /// What the last paragraph written was, to know what goes between it and the next one.
        var last: Kind?
        var blankSince = false
        var paragraph = string.paragraphRange(for: NSRange(location: 0, length: 0))
        while true {
            let content = TypingRules.contentRange(of: paragraph, in: string)
            let (line, kind) = self.line(content, in: text, files: files)
            if line.isEmpty {
                blankSince = true
            } else {
                if let last {
                    out += last == kind && !blankSince && kind != .other ? (kind == .quote ? "\n>\n" : "\n") : "\n\n"
                }
                out += line
                last = kind
                blankSince = false
            }
            // The album, under the title.
            if paragraph.location == 0, !photos.isEmpty {
                if last != nil { out += "\n\n" }
                out += photos.map { "![](\(path($0, in: files)))" }.joined(separator: "\n")
                last = .other
            }
            if paragraph.upperBound >= string.length { break }
            paragraph = string.paragraphRange(for: NSRange(location: paragraph.upperBound, length: 0))
        }
        if out.isEmpty, !photos.isEmpty { out = photos.map { "![](\(path($0, in: files)))" }.joined(separator: "\n") }
        return out + "\n"
    }

    private enum Kind { case list, quote, other }

    /// One paragraph of the note, without its line break, as one line of Markdown.
    private static func line(_ range: NSRange, in text: NSAttributedString, files: String?) -> (String, Kind) {
        let string = text.string as NSString
        guard range.length > 0 else { return ("", .other) }
        let attributes = text.attributes(at: range.location, effectiveRange: nil)
        let block = NoteFormat.block(in: attributes)
        if block == .divider { return ("---", .other) }
        let object = (String(NoteText.attachmentCharacter) as NSString).character(at: 0)
        // A joined file is a line of its own.
        if range.length == 1, string.character(at: range.location) == object {
            guard let name = attributes[NoteFormat.attachmentKey] as? String else { return ("", .other) }
            let image = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"].contains((name as NSString).pathExtension.lowercased())
            return ("\(image ? "!" : "")[\(escaped(name))](\(path(name, in: files)))", .other)
        }
        var body = range
        var prefix = ""
        var kind = Kind.other
        if let marker = ListMarker.marker(in: string, paragraph: range) {
            body = NSRange(location: range.location + marker.text.utf16.count, length: range.length - marker.text.utf16.count)
            let indent = String(repeating: "    ", count: NoteFormat.indent(in: attributes))
            let mark: String = switch marker.kind {
            case .bullet: "- "
            case .numbered: "\(marker.number ?? 1). "
            case .checklist: marker.checked == true ? "- [x] " : "- [ ] "
            }
            prefix = indent + mark
            kind = .list
        }
        switch block {
        case .title: prefix = "# " + prefix
        case .heading: prefix = "## " + prefix
        case .subheading: prefix = "### " + prefix
        case .quote:
            prefix = "> " + prefix
            kind = .quote
        case .divider, .source, nil: break
        }
        var inline = self.inline(body, in: text)
        // Body text that would read as a mark of its own.
        if prefix.isEmpty, inline.range(of: #"^(#{1,6} |> |[-+*] |\d{1,9}[.)] |---$)"#, options: .regularExpression) != nil {
            inline = "\\" + inline
        }
        return (prefix + inline, kind)
    }

    /// A mark that opens and closes around a stretch of text.
    private enum Mark: Equatable {
        case link(String), bold, italic, highlight, strike, code

        var opening: String {
            switch self {
            case .link: "["
            case .bold: "**"
            case .italic: "*"
            case .highlight: "=="
            case .strike: "~~"
            case .code: "`"
            }
        }

        var closing: String {
            if case .link(let address) = self { return "](\(address))" }
            return opening
        }
    }

    /// The text of `range` with its marks; they open and close around words, never around the
    /// spaces that start or end them.
    private static func inline(_ range: NSRange, in text: NSAttributedString) -> String {
        var out = ""
        var open: [Mark] = []
        func close(from index: Int) {
            guard index < open.count else { return }
            let spaces = out.reversed().prefix { $0 == " " }.count
            out.removeLast(spaces)
            for mark in open[index...].reversed() { out += mark.closing }
            out += String(repeating: " ", count: spaces)
            open.removeSubrange(index...)
        }
        text.enumerateAttributes(in: range) { attributes, run, _ in
            var marks: [Mark] = []
            if let link = attributes[NoteFormat.linkKey] as? String { marks.append(.link(link)) }
            if attributes[NoteFormat.boldKey] != nil { marks.append(.bold) }
            if attributes[NoteFormat.italicKey] != nil { marks.append(.italic) }
            if attributes[NoteFormat.highlightKey] != nil { marks.append(.highlight) }
            if attributes[NoteFormat.strikeKey] != nil { marks.append(.strike) }
            if attributes[NoteFormat.codeKey] != nil { marks.append(.code) }
            var piece = (text.string as NSString).substring(with: run).filter { $0 != NoteText.attachmentCharacter }
            // What is open and goes on stays open; what ends closes (and what was opened inside it).
            if let ended = open.firstIndex(where: { !marks.contains($0) }) { close(from: ended) }
            let leading = piece.prefix { $0 == " " }
            if marks.contains(where: { !open.contains($0) }) {
                out += leading
                piece.removeFirst(leading.count)
            }
            for mark in marks where !open.contains(mark) {
                out += mark.opening
                open.append(mark)
            }
            out += open.contains(.code) ? piece : escaped(piece)
        }
        close(from: 0)
        return out
    }

    /// Characters that Markdown would read as marks, written as themselves.
    private static func escaped(_ text: String) -> String {
        var out = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            switch character {
            case "\\", "*", "`", "[", "]":
                out += "\\"
            // "nom_de_fichier" stays as it is; "_mot_" would be italic.
            case "_" where !(index > 0 && isWordCharacter(characters[index - 1]) && index + 1 < characters.count && isWordCharacter(characters[index + 1])):
                out += "\\"
            case "~" where index + 1 < characters.count && characters[index + 1] == "~", "=" where index + 1 < characters.count && characters[index + 1] == "=":
                out += "\\"
            default:
                break
            }
            out.append(character)
        }
        return out
    }

    private static func isWordCharacter(_ character: Character) -> Bool { character.isLetter || character.isNumber }

    private static func path(_ name: String, in folder: String?) -> String {
        let path = folder.map { $0 + "/" + name } ?? name
        return path.contains(where: { $0 == " " || $0 == "(" || $0 == ")" }) ? "<\(path)>" : path
    }

    /// The semantic attributes of the note over its text, without fonts or colors.
    static func semantic(_ content: NoteContent) -> NSAttributedString {
        let text = NSMutableAttributedString(string: content.text)
        for run in content.runs {
            let range = NSIntersectionRange(NSRange(location: run.start, length: run.length), NSRange(location: 0, length: text.length))
            guard range.length > 0 else { continue }
            if let block = run.block { text.addAttribute(NoteFormat.blockKey, value: block.rawValue, range: range) }
            if run.bold == true || run.weight == .bold { text.addAttribute(NoteFormat.boldKey, value: true, range: range) }
            if run.italic == true { text.addAttribute(NoteFormat.italicKey, value: true, range: range) }
            if run.highlight == true { text.addAttribute(NoteFormat.highlightKey, value: true, range: range) }
            if run.strike == true { text.addAttribute(NoteFormat.strikeKey, value: true, range: range) }
            if run.code == true { text.addAttribute(NoteFormat.codeKey, value: true, range: range) }
            if let link = run.link { text.addAttribute(NoteFormat.linkKey, value: link, range: range) }
            if let indent = run.indent { text.addAttribute(NoteFormat.indentKey, value: indent, range: range) }
            if let name = run.attachment { text.addAttribute(NoteFormat.attachmentKey, value: name, range: range) }
        }
        return text
    }

    /// `name` without what a file name can't have; `otherwise` when nothing is left.
    static func safeName(_ name: String, otherwise: String) -> String {
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return safe.isEmpty ? otherwise : String(safe.prefix(80))
    }

    // MARK: Import

    /// Text written elsewhere has Markdown marks in it: a title, a list, bold… Plain sentences
    /// don't (a lone "*" or "_" is no reason).
    static func looksLikeMarkdown(_ text: String) -> Bool {
        text.range(of: #"(?m)^[ \t]{0,3}(#{1,6}[ \t]+\S|>[ \t]?\S|[-*+][ \t]+\S|\d{1,9}[.)][ \t]+\S|```|(-{3,}|\*{3,}|_{3,})[ \t]*$)"#, options: .regularExpression) != nil
            || text.range(of: #"\*\*\S[^\n]*?\*\*|__\S[^\n]*?__|~~\S[^\n]*?~~|==\S[^\n]*?==|\[[^\]\n]+\]\([^)\s]+\)|`[^`\n]+`"#, options: .regularExpression) != nil
    }

    /// Markdown made a note: titles (`#`, `##`, `###` and below), lists (bulleted, numbered, to
    /// check, indented), quotes, dividers, code, and bold, italic, `==` highlighting, `~~`
    /// striking, links. Blank lines are kept between two paragraphs of text only.
    /// `titled`: a first line of plain text is the note's title.
    static func content(fromMarkdown markdown: String, titled: Bool = false) -> NoteContent {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .filter { $0 != NoteText.attachmentCharacter }
            .components(separatedBy: "\n")
        var paragraphs: [Paragraph] = []
        var fenced = false
        var blank = false
        /// Columns where the list items being read start: one per step of indentation.
        var columns: [Int] = []
        for raw in lines {
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                fenced.toggle()
                continue
            }
            if fenced {
                paragraphs.append(Paragraph(text: NSAttributedString(string: raw, attributes: [NoteFormat.codeKey: true]), kind: .code))
                continue
            }
            if raw.trimmingCharacters(in: .whitespaces).isEmpty {
                blank = true
                continue
            }
            let paragraph = parse(raw, columns: &columns)
            if paragraph.kind != .list { columns = [] }
            // A blank line stays between two paragraphs of text: elsewhere, the note's own room
            // between paragraphs is enough.
            paragraph.blankBefore = blank && paragraph.kind == .text && paragraphs.last?.kind == .text
            blank = false
            paragraphs.append(paragraph)
        }
        if titled, let first = paragraphs.first, first.kind == .text, first.block == nil { paragraphs[0].block = .title }

        let text = NSMutableAttributedString()
        for paragraph in paragraphs {
            if text.length > 0 { text.append(NSAttributedString(string: paragraph.blankBefore ? "\n\n" : "\n")) }
            let start = text.length
            text.append(NSAttributedString(string: paragraph.marker))
            text.append(paragraph.text)
            // The kind and the indentation are the whole paragraph's, its break included (as
            // the editor writes them): laid over it once the text is all there.
            paragraph.range = NSRange(location: start, length: text.length - start)
        }
        // Each paragraph's kind and indentation over it and its break.
        for paragraph in paragraphs {
            guard let range = paragraph.range else { continue }
            let whole = NSRange(location: range.location, length: min(range.length + 1, text.length - range.location))
            if let block = paragraph.block { text.addAttribute(NoteFormat.blockKey, value: block.rawValue, range: whole) }
            if paragraph.indent > 0 { text.addAttribute(NoteFormat.indentKey, value: paragraph.indent, range: whole) }
        }
        return NoteFormat.content(from: text)
    }

    /// Markdown pasted in a note, ready to go in its text. `typing`: the attributes of what
    /// would be typed there. `startsLine`: nothing comes before it on its line — otherwise its
    /// first line joins that one, as plain text of it; on a title, its first line is part of
    /// the title, the rest isn't.
    static func pasted(_ markdown: String, typing: [NSAttributedString.Key: Any], startsLine: Bool) -> NSAttributedString {
        let piece = NoteFormat.attributedString(from: content(fromMarkdown: markdown))
        let string = piece.string as NSString
        guard piece.length > 0 else { return piece }
        let first = string.paragraphRange(for: NSRange(location: 0, length: 0))
        let block = NoteFormat.block(in: typing)
        if !startsLine || block?.isHeading == true {
            // Its marker and its kind go: the line keeps its own.
            if let marker = ListMarker.marker(in: string, paragraph: first) {
                piece.deleteCharacters(in: NSRange(location: 0, length: marker.text.utf16.count))
            }
            let line = (piece.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
            piece.removeAttribute(NoteFormat.indentKey, range: line)
            if let block {
                piece.addAttribute(NoteFormat.blockKey, value: block.rawValue, range: line)
            } else {
                piece.removeAttribute(NoteFormat.blockKey, range: line)
            }
            if let indent = typing[NoteFormat.indentKey] { piece.addAttribute(NoteFormat.indentKey, value: indent, range: line) }
        }
        return piece
    }

    private final class Paragraph {
        enum Kind { case text, heading, list, quote, divider, code }

        let text: NSAttributedString
        let kind: Kind
        var block: NoteBlock?
        /// The list marker of the note ("• ", "☐ "…), written before the text.
        var marker = ""
        var indent = 0
        var blankBefore = false
        /// Where it is in the note, once written.
        var range: NSRange?

        init(text: NSAttributedString, kind: Kind, block: NoteBlock? = nil) {
            self.text = text
            self.kind = kind
            self.block = block
        }
    }

    private static let heading = try! NSRegularExpression(pattern: #"^[ \t]{0,3}(#{1,6})[ \t]+(.*?)(?:[ \t]+#+)?[ \t]*$"#)
    private static let quote = try! NSRegularExpression(pattern: #"^[ \t]{0,3}(?:>[ \t]?)+(.*)$"#)
    private static let divider = try! NSRegularExpression(pattern: #"^[ \t]{0,3}(?:(?:-[ \t]*){3,}|(?:\*[ \t]*){3,}|(?:_[ \t]*){3,})$"#)
    private static let listItem = try! NSRegularExpression(pattern: #"^([ \t]*)(?:([-*+])|(\d{1,9})[.)])[ \t]+(?:\[([ xX])\][ \t]+)?(.*)$"#)

    private static func parse(_ line: String, columns: inout [Int]) -> Paragraph {
        let ns = line as NSString
        let whole = NSRange(location: 0, length: ns.length)
        if divider.firstMatch(in: line, range: whole) != nil { return Paragraph(text: NSAttributedString(string: NoteFormat.rule), kind: .divider, block: .divider) }
        if let match = heading.firstMatch(in: line, range: whole) {
            let level = match.range(at: 1).length
            return Paragraph(text: inline(ns.substring(with: match.range(at: 2))), kind: .heading, block: level == 1 ? .title : level == 2 ? .heading : .subheading)
        }
        if let match = listItem.firstMatch(in: line, range: whole) {
            let leading = ns.substring(with: match.range(at: 1))
            let column = leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            while let last = columns.last, last > column { columns.removeLast() }
            if columns.last.map({ column > $0 }) ?? true { columns.append(column) }
            let paragraph = Paragraph(text: inline(ns.substring(with: match.range(at: 5))), kind: .list)
            if match.range(at: 4).location != NSNotFound {
                paragraph.marker = ns.substring(with: match.range(at: 4)).lowercased() == "x" ? NoteFormat.checked : NoteFormat.unchecked
            } else if match.range(at: 3).location != NSNotFound {
                paragraph.marker = ListMarker.text(.numbered, number: Int(ns.substring(with: match.range(at: 3))) ?? 1)
            } else {
                paragraph.marker = NoteFormat.bullet
            }
            paragraph.indent = min(columns.count - 1, NoteFormat.maxIndent)
            return paragraph
        }
        if let match = quote.firstMatch(in: line, range: whole) {
            return Paragraph(text: inline(ns.substring(with: match.range(at: 1))), kind: .quote, block: .quote)
        }
        return Paragraph(text: inline(line.trimmingCharacters(in: .whitespaces)), kind: .text)
    }

    // Marks inside a line, from the strongest to the weakest. `\*` and the like are kept as
    // they are: they stand in for themselves while the marks are read.
    private static let escape = try! NSRegularExpression(pattern: #"\\([\\`*_{}\[\]()#+\-.!>~=|])"#)
    private static let codeSpan = try! NSRegularExpression(pattern: #"`([^`]+)`"#)
    private static let image = try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\([^)]*\)"#)
    private static let link = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)"#)
    private static let autolink = try! NSRegularExpression(pattern: #"<((?:https?|mailto):[^>\s]+)>"#)
    private static let strong = [try! NSRegularExpression(pattern: #"\*\*(?=\S)(.+?)(?<=\S)\*\*"#), try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])__(?=\S)(.+?)(?<=\S)__(?![\p{L}\p{N}])"#)]
    private static let strike = try! NSRegularExpression(pattern: #"~~(?=\S)(.+?)(?<=\S)~~"#)
    private static let mark = try! NSRegularExpression(pattern: #"==(?=\S)(.+?)(?<=\S)=="#)
    private static let emphasis = [try! NSRegularExpression(pattern: #"(?<![*\p{L}\p{N}])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![*\p{L}\p{N}])"#),
                                   try! NSRegularExpression(pattern: #"(?<![_\p{L}\p{N}])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![_\p{L}\p{N}])"#)]

    /// One line of Markdown, its marks gone and their formatting laid over the text.
    static func inline(_ markdown: String) -> NSAttributedString {
        // Escaped characters are hidden in the private use area while the marks are read.
        let hidden = NSMutableString(string: markdown)
        for match in escape.matches(in: markdown, range: NSRange(location: 0, length: hidden.length)).reversed() {
            let character = hidden.substring(with: match.range(at: 1)).unicodeScalars.first!.value
            hidden.replaceCharacters(in: match.range, with: String(Character(UnicodeScalar(0xE000 + character)!)))
        }
        let text = NSMutableAttributedString(string: hidden as String)
        replace(codeSpan, in: text) { _ in [NoteFormat.codeKey: true] }
        replace(image, in: text) { _ in [:] }
        replace(link, in: text) { address in
            NoteFormat.linkURL(from: address ?? "").map { [NoteFormat.linkKey: $0.absoluteString] } ?? [:]
        }
        replace(autolink, in: text, keepsAddress: true) { address in
            NoteFormat.linkURL(from: address ?? "").map { [NoteFormat.linkKey: $0.absoluteString] } ?? [:]
        }
        for pattern in strong { replace(pattern, in: text) { _ in [NoteFormat.boldKey: true] } }
        replace(strike, in: text) { _ in [NoteFormat.strikeKey: true] }
        replace(mark, in: text) { _ in [NoteFormat.highlightKey: true] }
        for pattern in emphasis { replace(pattern, in: text) { _ in [NoteFormat.italicKey: true] } }
        // The hidden characters, back as themselves.
        let string = text.mutableString
        var index = 0
        while index < string.length {
            let unit = string.character(at: index)
            if unit >= 0xE000, unit < 0xE080 { string.replaceCharacters(in: NSRange(location: index, length: 1), with: String(Character(UnicodeScalar(unit - 0xE000)!))) }
            index += 1
        }
        return text
    }

    /// Each stretch `pattern` finds (out of code) becomes its first group, with `attributes`;
    /// the second group, if any, is given to `attributes` (a link's address).
    /// `keepsAddress`: the stretch becomes its first group as the text (an address written as such).
    private static func replace(_ pattern: NSRegularExpression, in text: NSMutableAttributedString, keepsAddress: Bool = false,
                                attributes: (String?) -> [NSAttributedString.Key: Any]) {
        var start = 0
        while start < text.length, let match = pattern.firstMatch(in: text.string, range: NSRange(location: start, length: text.length - start)) {
            var inCode = false
            text.enumerateAttribute(NoteFormat.codeKey, in: match.range) { value, _, stop in
                if value != nil { inCode = true; stop.pointee = true }
            }
            // Code is written as it is.
            if inCode && pattern !== codeSpan {
                start = match.range.location + 1
                continue
            }
            let string = text.string as NSString
            let inner = match.range(at: 1)
            let address = match.numberOfRanges > 2 && match.range(at: 2).location != NSNotFound ? string.substring(with: match.range(at: 2)) : keepsAddress ? string.substring(with: inner) : nil
            let piece = NSMutableAttributedString(attributedString: text.attributedSubstring(from: inner))
            piece.addAttributes(attributes(address), range: NSRange(location: 0, length: piece.length))
            text.replaceCharacters(in: match.range, with: piece)
            start = match.range.location + max(piece.length, 1)
        }
    }
}
