import Foundation

/// A message written with the editor, as the HTML that is sent: plain tags (titles, lists, quotes,
/// rules, bold, italic, highlight, struck, code, links), a few inline styles that every mail app
/// keeps, no font and no color imposed — the reader's app shows it in its own.
enum NoteHTML {
    static func html(from content: NoteContent) -> String {
        let text = NoteMarkdown.semantic(content)
        let string = text.string as NSString
        var out = ""
        /// The lists open, innermost last: their tag and depth.
        var lists: [(tag: String, depth: Int)] = []
        var inQuote = false

        func closeLists(to depth: Int) {
            while let last = lists.last, last.depth > depth {
                out += "</li></\(last.tag)>"
                lists.removeLast()
            }
        }

        var paragraph = string.paragraphRange(for: NSRange(location: 0, length: 0))
        while paragraph.length > 0 || paragraph.location < string.length {
            let range = TypingRules.contentRange(of: paragraph, in: string)
            let attributes = range.length > 0 ? text.attributes(at: range.location, effectiveRange: nil) : [:]
            let block = NoteFormat.block(in: attributes)
            let marker = range.length > 0 ? ListMarker.marker(in: string, paragraph: range) : nil

            if block == .quote, !inQuote { closeLists(to: 0); out += "<blockquote style=\"margin:0 0 0 2px;padding-left:12px;border-left:3px solid #c8c8d0;color:#55555c\">"; inQuote = true }
            if block != .quote, inQuote { closeLists(to: 0); out += "</blockquote>"; inQuote = false }

            if let marker {
                let depth = NoteFormat.indent(in: attributes) + 1
                let tag = marker.kind == .numbered ? "ol" : "ul"
                let body = NSRange(location: range.location + marker.text.utf16.count, length: range.length - marker.text.utf16.count)
                if let last = lists.last, last.depth == depth, last.tag != tag { closeLists(to: depth - 1) }
                if let last = lists.last, last.depth >= depth {
                    closeLists(to: depth)
                    out += "</li>"
                }
                while (lists.last?.depth ?? 0) < depth {
                    let style = marker.kind == .checklist ? " style=\"list-style:none;padding-left:4px\"" : ""
                    let start = lists.count + 1 == depth && marker.kind == .numbered && (marker.number ?? 1) != 1 ? " start=\"\(marker.number ?? 1)\"" : ""
                    out += "<\(tag)\(style)\(start)>"
                    lists.append((tag, lists.count + 1))
                }
                let box = marker.checked.map { $0 ? "☑ " : "☐ " } ?? ""
                let inner = box + inline(body, in: text)
                out += "<li>" + (marker.checked == true ? "<s>\(inner)</s>" : inner)
            } else {
                closeLists(to: 0)
                let inner = inline(range, in: text)
                switch block {
                case .title: out += "<h1 style=\"font-size:1.6em;margin:0.6em 0 0.3em\">\(inner)</h1>"
                case .heading: out += "<h2 style=\"font-size:1.3em;margin:0.6em 0 0.3em\">\(inner)</h2>"
                case .subheading: out += "<h3 style=\"font-size:1.1em;margin:0.6em 0 0.3em\">\(inner)</h3>"
                case .divider: out += "<hr style=\"border:none;border-top:1px solid #d0d0d6;margin:1em 0\">"
                default: out += range.length == 0 ? "<div><br></div>" : "<div>\(inner)</div>"
                }
            }
            if paragraph.upperBound >= string.length { break }
            paragraph = string.paragraphRange(for: NSRange(location: paragraph.upperBound, length: 0))
        }
        closeLists(to: 0)
        if inQuote { out += "</blockquote>" }
        return "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body>" + out + "</body></html>"
    }

    /// The text of a range, escaped, each run in its tags.
    private static func inline(_ range: NSRange, in text: NSAttributedString) -> String {
        var out = ""
        text.enumerateAttributes(in: range) { attributes, run, _ in
            var piece = escape((text.string as NSString).substring(with: run).filter { $0 != NoteText.attachmentCharacter })
            guard !piece.isEmpty else { return }
            if attributes[NoteFormat.codeKey] != nil { piece = "<code style=\"font-family:ui-monospace,Menlo,monospace;font-size:0.92em;background:#f0f0f3;padding:0 3px;border-radius:3px\">\(piece)</code>" }
            if attributes[NoteFormat.strikeKey] != nil { piece = "<s>\(piece)</s>" }
            if attributes[NoteFormat.highlightKey] != nil { piece = "<mark style=\"background:#ffe14d\">\(piece)</mark>" }
            if attributes[NoteFormat.italicKey] != nil { piece = "<i>\(piece)</i>" }
            if attributes[NoteFormat.boldKey] != nil { piece = "<b>\(piece)</b>" }
            if let link = attributes[NoteFormat.linkKey] as? String { piece = "<a href=\"\(escape(link))\">\(piece)</a>" }
            out += piece
        }
        return out
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
