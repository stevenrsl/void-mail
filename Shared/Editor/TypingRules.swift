import Foundation

/// Formatting as you type: what the keystroke about to be made should do instead of inserting
/// its character. The marks are those of Markdown, and they disappear once understood — the
/// text shows formatted, never as code.
///
///     "# " "## " "### "   title, heading, subheading        "> "   quote
///     "- " "* "           bulleted list                     "1. "  numbered list
///     "[] " "[ ] "        checklist item, to do             "[x] " checklist item, done
///     **bold**            bold                              *italic* _italic_
///     ==highlight==       highlighted                       "---"  divider
///     ~~strike~~          struck through                    `code` inline code
///
/// The checklist marks also work after a bullet ("- [ ] ", as in Markdown). Return continues a
/// list or a quote; Return on an empty item ends it; Backspace just after a marker removes it.
/// Tab indents a list item; Return on an empty indented item, or Backspace just after its
/// marker, brings it back one step.
enum TypingRules {
    enum InlineStyle {
        case bold, italic, highlight, strike, code
    }

    enum Action: Equatable {
        /// Replace `range` with `text` (list markers).
        case replace(range: NSRange, text: String)
        /// Remove `marker` and make the paragraph a `block` (nil: back to body text).
        case setBlock(NoteBlock?, marker: NSRange)
        /// Replace `range` (marks included) with the text of `content`, in that style.
        case inline(range: NSRange, content: NSRange, style: InlineStyle)
        /// Replace `range` (the dashes typed so far) with a divider.
        case divider(range: NSRange)
        /// Indent the list item being typed in by `by` steps (negative: back).
        case indent(by: Int)
    }

    /// `block`: kind of the paragraph being typed in; `indent`: its steps of indentation, if it
    /// is a list item. nil result: the keystroke goes through.
    static func action(in string: NSString, range: NSRange, replacement: String, block: NoteBlock?, indent: Int = 0) -> Action? {
        let paragraph = string.paragraphRange(for: NSRange(location: range.location, length: 0))
        let marker = ListMarker.marker(in: string, paragraph: paragraph)
        let markerRange = NSRange(location: paragraph.location, length: marker?.text.utf16.count ?? 0)

        switch replacement {
        case " " where range.length == 0:
            // What was typed since the start of the paragraph, e.g. "##".
            let typed = NSRange(location: paragraph.location, length: range.location - paragraph.location)
            switch string.substring(with: typed) {
            case "-", "*": return block?.isHeading == true ? nil : .replace(range: typed, text: NoteFormat.bullet)
            case "[]", "[ ]", NoteFormat.bullet + "[]", NoteFormat.bullet + "[ ]":
                return block?.isHeading == true ? nil : .replace(range: typed, text: NoteFormat.unchecked)
            // Also in the empty box that Return has just made.
            case "[x]", "[X]", NoteFormat.bullet + "[x]", NoteFormat.bullet + "[X]", NoteFormat.unchecked + "[x]", NoteFormat.unchecked + "[X]":
                return block?.isHeading == true ? nil : .replace(range: typed, text: NoteFormat.checked)
            case "#": return .setBlock(.title, marker: typed)
            case "##": return .setBlock(.heading, marker: typed)
            case "###": return .setBlock(.subheading, marker: typed)
            case ">": return .setBlock(.quote, marker: typed)
            default: return nil
            }

        case "\n" where range.length == 0:
            let content = contentRange(of: paragraph, in: string)
            if let marker, range.location >= markerRange.upperBound {
                // Return on an empty item ends the list; otherwise the next item starts.
                let rest = string.substring(with: NSRange(location: markerRange.upperBound, length: content.upperBound - markerRange.upperBound))
                // An empty indented item comes back one step first.
                if rest.trimmingCharacters(in: .whitespaces).isEmpty { return indent > 0 ? .indent(by: -1) : .replace(range: markerRange, text: "") }
                // The item after one that is done is still to do.
                return .replace(range: range, text: "\n" + ListMarker.text(marker.kind, number: (marker.number ?? 0) + 1))
            }
            // Return on an empty quote line ends the quote.
            if block == .quote, content.length == 0 { return .setBlock(nil, marker: NSRange(location: paragraph.location, length: 0)) }
            return nil

        case "" where range.length == 1 && marker != nil && range.upperBound == markerRange.upperBound:
            return indent > 0 ? .indent(by: -1) : .replace(range: markerRange, text: "")

        case "\t" where marker != nil && range.upperBound <= NSMaxRange(paragraph):
            return .indent(by: 1)

        case "-" where range.length == 0 && block == nil:
            // The third dash of "---", alone on its line.
            let content = contentRange(of: paragraph, in: string)
            guard range.location == content.upperBound, string.substring(with: content) == "--" else { return nil }
            return .divider(range: content)

        case "*" where range.length == 0, "_" where range.length == 0, "=" where range.length == 0, "~" where range.length == 0, "`" where range.length == 0:
            return inline(in: string, paragraph: paragraph, at: range.location, mark: (replacement as NSString).character(at: 0))

        default:
            return nil
        }
    }

    /// The closing mark is being typed at `location`: finds the opening one in the paragraph.
    private static func inline(in string: NSString, paragraph: NSRange, at location: Int, mark: unichar) -> Action? {
        let star: unichar = 42, equals: unichar = 61, tilde: unichar = 126, backtick: unichar = 96
        func char(_ index: Int) -> unichar? { index >= paragraph.location && index < location ? string.character(at: index) : nil }

        // "**bold*" + "*", "==highlight=" + "=", "~~strike~" + "~": the first closing mark is already there.
        if mark == star || mark == equals || mark == tilde, char(location - 1) == mark {
            let end = location - 1
            guard end - 1 >= paragraph.location, !isSpace(char(end - 1)) else { return nil }
            var open = end - 3
            while open >= paragraph.location {
                if char(open) == mark, char(open + 1) == mark, !isSpace(char(open + 2)), char(open + 2) != mark, opens(char(open - 1)) {
                    return .inline(range: NSRange(location: open, length: location - open),
                                   content: NSRange(location: open + 2, length: end - open - 2), style: mark == star ? .bold : mark == tilde ? .strike : .highlight)
                }
                open -= 1
            }
            return nil
        }

        // "*italic" + "*", "_italic" + "_", "`code" + "`". A doubled mark isn't an opening one ("**bold" is on its way to bold).
        // A single "=" is only ever an equals sign, a single "~" a tilde.
        guard mark != equals, mark != tilde, location - 1 >= paragraph.location, !isSpace(char(location - 1)), char(location - 1) != mark else { return nil }
        var open = location - 2
        while open >= paragraph.location {
            if char(open) == mark {
                if char(open - 1) != mark, char(open + 1) != mark, !isSpace(char(open + 1)), opens(char(open - 1)) {
                    return .inline(range: NSRange(location: open, length: location - open),
                                   content: NSRange(location: open + 1, length: location - open - 1), style: mark == backtick ? .code : .italic)
                }
                // The nearest mark doesn't open anything (e.g. "2 * 3"): the text stays as typed.
                return nil
            }
            open -= 1
        }
        return nil
    }

    /// The paragraph without its line break.
    static func contentRange(of paragraph: NSRange, in string: NSString) -> NSRange {
        var length = paragraph.length
        while length > 0, let scalar = Unicode.Scalar(string.character(at: paragraph.location + length - 1)), CharacterSet.newlines.contains(scalar) {
            length -= 1
        }
        return NSRange(location: paragraph.location, length: length)
    }

    private static func isSpace(_ character: unichar?) -> Bool {
        guard let character, let scalar = Unicode.Scalar(character) else { return character == nil }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// An opening mark starts a word: it comes first in the paragraph, or after a space or an
    /// opening punctuation — not in the middle of "snake_case" or "2*3".
    private static func opens(_ before: unichar?) -> Bool {
        guard let before, let scalar = Unicode.Scalar(before) else { return true }
        return CharacterSet.whitespaces.contains(scalar) || "([{«\"'’“—–-:;,".unicodeScalars.contains(scalar)
    }
}
