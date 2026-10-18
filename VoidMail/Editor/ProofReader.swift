import AppKit

/// Spelling and grammar of a note, checked as one writes, as in a word processor: a wavy red line
/// under a misspelled word, a blue one under a grammar mistake. macOS's own checker does the
/// reading (in the language of the text); the text view draws the lines (`NoteTextView.drawProofMarks`)
/// and offers the corrections on a right click. AppKit's own continuous checking stays off: it
/// would draw dotted lines of its own, red and green.
@MainActor
final class ProofReader: NSObject, NSTextStorageDelegate {
    enum Kind { case spelling, grammar }

    struct Mark: Equatable {
        var range: NSRange
        let kind: Kind
        /// What is wrong, for a grammar mistake, as the checker words it.
        let detail: String?
        /// Replacements the checker offers for a grammar mistake (a misspelled word's are asked
        /// for when the menu opens).
        let corrections: [String]
    }

    private(set) var marks: [Mark] = [] {
        didSet { if marks != oldValue { onChange?() } }
    }

    var checksSpelling = false { didSet { if checksSpelling != oldValue { settingsChanged() } } }
    var checksGrammar = false { didSet { if checksGrammar != oldValue { settingsChanged() } } }
    var isEnabled: Bool { checksSpelling || checksGrammar }

    /// The marks changed: they are to be drawn again.
    var onChange: (() -> Void)?
    /// What is not to be checked: links, the "Source :" line.
    var skips: ((NSRange) -> Bool)?

    /// macOS checks grammar for the apps: not every version does (macOS 27 finds no mistake in
    /// "This are a good idea."). Asked once; without it, Réglages and the Edit menu don't offer it.
    static let grammarIsAvailable: Bool = {
        let probe = "This are a good idea."
        let results = NSSpellChecker.shared.check(probe, range: NSRange(location: 0, length: (probe as NSString).length),
                                                  types: NSTextCheckingResult.CheckingType.grammar.rawValue, options: nil,
                                                  inSpellDocumentWithTag: 0, orthography: nil, wordCount: nil)
        return results.contains { $0.resultType == .grammar }
    }()

    /// Seconds of quiet after a change before the text is read again.
    static let delay = 0.4

    /// The note, for the checker: words ignored in it stay ignored while it is shown.
    let tag = NSSpellChecker.uniqueSpellDocumentTag()
    private weak var storage: NSTextStorage?
    /// Changes at each edit: a reading of an older text is thrown away.
    private var generation = 0

    init(storage: NSTextStorage) {
        self.storage = storage
        super.init()
        storage.delegate = self
    }

    deinit {
        let tag = tag
        Task { @MainActor in NSSpellChecker.shared.closeSpellDocument(withTag: tag) }
    }

    /// The mark on the character at `index`, if any.
    func mark(at index: Int) -> Mark? {
        marks.first { NSLocationInRange(index, $0.range) }
    }

    // MARK: Following the text

    /// Marks after a change move with the text; those it touches go, until the next reading.
    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated { edited(editedRange, delta: delta) }
    }

    private func edited(_ range: NSRange, delta: Int) {
        generation += 1
        let old = NSRange(location: range.location, length: max(range.length - delta, 0))
        var kept: [Mark] = []
        for var mark in marks {
            if mark.range.upperBound < old.location {
                kept.append(mark)
            } else if mark.range.location > old.upperBound {
                mark.range.location += delta
                kept.append(mark)
            }
            // A word being typed, or just cut: read again in a moment.
        }
        marks = kept
        checkSoon()
    }

    private func settingsChanged() {
        generation += 1
        // What is no longer checked goes at once; the rest is read again.
        marks.removeAll { $0.kind == .spelling ? !checksSpelling : !checksGrammar }
        if isEnabled { check() }
    }

    func checkSoon() {
        guard isEnabled else { return }
        let request = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay) { [weak self] in
            guard let self, self.generation == request else { return }
            self.check()
        }
    }

    /// Reads the whole text (a note is short; the checker works off the main thread).
    func check() {
        guard isEnabled, let storage, storage.length > 0 else {
            marks = []
            return
        }
        let text = storage.string
        let request = generation
        var types: NSTextCheckingTypes = 0
        if checksSpelling { types |= NSTextCheckingResult.CheckingType.spelling.rawValue }
        if checksGrammar { types |= NSTextCheckingResult.CheckingType.grammar.rawValue }
        NSSpellChecker.shared.requestChecking(of: text, range: NSRange(location: 0, length: (text as NSString).length), types: types,
                                              options: nil, inSpellDocumentWithTag: tag) { [weak self] _, results, _, _ in
            let found = Self.marks(from: results)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == request else { return }
                self.marks = found.filter { !(self.skips?($0.range) ?? false) }
            }
        }
    }

    /// The same, at once: for the self-test.
    func checkNow() {
        guard isEnabled, let storage, storage.length > 0 else { return marks = [] }
        var types: NSTextCheckingTypes = 0
        if checksSpelling { types |= NSTextCheckingResult.CheckingType.spelling.rawValue }
        if checksGrammar { types |= NSTextCheckingResult.CheckingType.grammar.rawValue }
        let results = NSSpellChecker.shared.check(storage.string, range: NSRange(location: 0, length: storage.length), types: types,
                                                  options: nil, inSpellDocumentWithTag: tag, orthography: nil, wordCount: nil)
        marks = Self.marks(from: results).filter { !(skips?($0.range) ?? false) }
    }

    nonisolated private static func marks(from results: [NSTextCheckingResult]) -> [Mark] {
        var marks: [Mark] = []
        for result in results {
            switch result.resultType {
            case .spelling:
                marks.append(Mark(range: result.range, kind: .spelling, detail: nil, corrections: []))
            case .grammar:
                // One result may hold several mistakes, each with its range in the sentence.
                for detail in result.grammarDetails ?? [] {
                    guard let inner = (detail[NSGrammarRange] as? NSValue)?.rangeValue else { continue }
                    let range = NSRange(location: result.range.location + inner.location, length: inner.length)
                    marks.append(Mark(range: range, kind: .grammar, detail: detail[NSGrammarUserDescription] as? String,
                                      corrections: detail[NSGrammarCorrections] as? [String] ?? []))
                }
            default:
                break
            }
        }
        return marks
    }

    // MARK: Corrections

    /// Replacements for the misspelled word or the mistake of `mark`, best first.
    func corrections(for mark: Mark) -> [String] {
        guard let storage else { return [] }
        switch mark.kind {
        case .grammar: return Array(mark.corrections.prefix(5))
        case .spelling:
            return Array((NSSpellChecker.shared.guesses(forWordRange: mark.range, in: storage.string, language: nil, inSpellDocumentWithTag: tag) ?? []).prefix(5))
        }
    }

    /// The word of `mark` is right in this note (until it is closed).
    func ignore(_ mark: Mark) {
        guard let storage, mark.range.upperBound <= storage.length else { return }
        if mark.kind == .spelling {
            let word = (storage.string as NSString).substring(with: mark.range)
            NSSpellChecker.shared.ignoreWord(word, inSpellDocumentWithTag: tag)
            marks.removeAll { $0.kind == .spelling && (storage.string as NSString).substring(with: $0.range) == word }
        } else {
            marks.removeAll { $0 == mark }
        }
    }

    /// The word of `mark` is right everywhere, from now on (the user's dictionary).
    func learn(_ mark: Mark) {
        guard let storage, mark.kind == .spelling, mark.range.upperBound <= storage.length else { return }
        let word = (storage.string as NSString).substring(with: mark.range)
        NSSpellChecker.shared.learnWord(word)
        marks.removeAll { $0.kind == .spelling && (storage.string as NSString).substring(with: $0.range) == word }
    }
}
