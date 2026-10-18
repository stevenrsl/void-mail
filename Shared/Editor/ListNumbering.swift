import Foundation

/// A numbered list keeps counting 1, 2, 3… whatever is inserted, removed or indented in it: its
/// numbers are characters of the note, written again where they no longer follow. Each step of
/// indentation counts on its own; a list starts at the number its first item has.
enum ListNumbering {
    /// A marker to write again: its place in the text, and what it becomes.
    struct Fix: Equatable {
        let range: NSRange
        let marker: String
    }

    /// The numbers to write again in the list around `range` (the lines just changed), last
    /// first: each fix leaves the places of those before it as they are.
    static func fixes(in text: NSAttributedString, around range: NSRange) -> [Fix] {
        let string = text.string as NSString
        guard string.length > 0 else { return [] }
        let location = min(range.location, string.length)
        var span = string.paragraphRange(for: NSRange(location: location, length: min(range.length, string.length - location)))
        func isItem(_ paragraph: NSRange) -> Bool { paragraph.length > 0 && ListMarker.marker(in: string, paragraph: paragraph) != nil }
        // The items before and after the change are part of its list: a line that isn't an
        // item ends it.
        while span.location > 0, case let previous = string.paragraphRange(for: NSRange(location: span.location - 1, length: 0)), isItem(previous) {
            span = NSUnionRange(previous, span)
        }
        while span.upperBound < string.length, case let next = string.paragraphRange(for: NSRange(location: span.upperBound, length: 0)), isItem(next) {
            span = NSUnionRange(span, next)
        }

        var fixes: [Fix] = []
        // The last number written at each step of indentation; nil: no list counting there.
        var counters = [Int?](repeating: nil, count: NoteFormat.maxIndent + 1)
        var first = true
        var next = span.location
        while next < span.upperBound {
            let paragraph = string.paragraphRange(for: NSRange(location: next, length: 0))
            guard paragraph.length > 0 else { break }
            next = paragraph.upperBound
            guard let marker = ListMarker.marker(in: string, paragraph: paragraph) else {
                counters = counters.map { _ in nil }
                first = true
                continue
            }
            let level = NoteFormat.indent(at: paragraph.location, in: text)
            for deeper in (level + 1)..<counters.count { counters[deeper] = nil }
            if let number = marker.number {
                // A list starts at its first number ("3. " typed on its own keeps 3); a list
                // that starts after other items (a sub-list, say) starts at 1.
                let expected = counters[level].map { $0 + 1 } ?? (first ? number : 1)
                if number != expected {
                    fixes.append(Fix(range: NSRange(location: paragraph.location, length: marker.text.utf16.count), marker: ListMarker.text(.numbered, number: expected)))
                }
                counters[level] = expected
            } else {
                counters[level] = nil
            }
            first = false
        }
        return fixes.reversed()
    }

    /// Where a location of the text is once `fix` is written: after it, it moves with the text.
    static func moved(_ location: Int, by fix: Fix) -> Int {
        let delta = fix.marker.utf16.count - fix.range.length
        if location >= fix.range.upperBound { return location + delta }
        if location > fix.range.location { return min(location, fix.range.location + fix.marker.utf16.count) }
        return location
    }
}
