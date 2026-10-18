import Foundation

// The editor's format, from Void Notes (Shared/Notes/Note.swift): a message is written with the
// same paragraphs, weights and runs as a note.

/// Kind of paragraph. A paragraph without one is plain body text.
enum NoteBlock: String, Codable, CaseIterable {
    case title, heading, subheading, quote
    /// A horizontal rule: a paragraph whose text is "---", shown as a line.
    case divider
    /// Where a note sent by another app comes from ("Source : https://…"): small and
    /// monospaced, like the dates under the title.
    case source

    var isHeading: Bool { self == .title || self == .heading || self == .subheading }
    /// A title, a heading or a divider is one line: Return at its end goes back to body text
    /// (a quote goes on).
    var isSingleLine: Bool { self != .quote }
}

/// Weight of a stretch of text, when it isn't the one its paragraph has by itself.
enum NoteWeight: String, Codable, CaseIterable {
    case light, medium, semibold, bold
}

/// Formatting of a stretch of text, in UTF-16 units (the units of NSString and of the editor).
/// Only what the stretch has is written: a bold word is `{"start": 4, "length": 5, "bold": true}`.
struct StyleRun: Codable, Equatable {
    var start: Int
    var length: Int
    var block: NoteBlock?
    var bold: Bool?
    var italic: Bool?
    /// A weight other than bold (bold stays `bold`, as in the first version of the format).
    var weight: NoteWeight?
    var highlight: Bool?
    /// A file joined to the note, shown where its character is (U+FFFC, one per file): its name
    /// in the note's attachments folder.
    var attachment: String?
    /// A link: the address the stretch opens (`https://…`, `mailto:…`).
    var link: String?
    /// Struck through (`~~texte~~`), apart from the done items of a checklist, which are by themselves.
    var strike: Bool?
    /// Inline code (`` `texte` ``): monospaced, on a light background.
    var code: Bool?
    /// Of a list item: how many steps it is indented (Tab), 1 to `NoteFormat.maxIndent`.
    var indent: Int?
}

/// What a note holds: its text as plain text (list markers "• ", "1. ", "☐ " and "☑ " included,
/// so the file reads on its own), and the formatting laid over it. No font, no color: those are worked out
/// when the note is shown, from the theme.
struct NoteContent: Codable, Equatable {
    var text = ""
    var runs: [StyleRun] = []
}

/// What the editor needs of a note's helpers.
enum NoteText {
    /// The character an attachment stands for in the text.
    static let attachmentCharacter: Character = "\u{FFFC}"

    /// Where the words of a search are in `text`, whatever the case and the accents: what the
    /// note shows on a soft background while the search lasts.
    static func found(_ words: [String], in text: String) -> [NSRange] {
        let string = text as NSString
        var ranges: [NSRange] = []
        for word in words where !word.isEmpty {
            var start = 0
            while start < string.length {
                let range = string.range(of: word, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: start, length: string.length - start))
                guard range.location != NSNotFound, range.length > 0 else { break }
                ranges.append(range)
                start = range.upperBound
            }
        }
        return ranges.sorted { $0.location < $1.location }
    }

}
