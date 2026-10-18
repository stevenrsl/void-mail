import Foundation

/// A message being written: who to, its subject, its text in the editor's format, its files.
struct Draft: Identifiable, Equatable {
    struct File: Equatable, Identifiable {
        var id: String { name }
        var name: String
        var data: Data
        var contentType: String
    }

    let id: UUID
    var account: UUID
    var to: String
    var cc: String
    var bcc: String
    var subject: String
    var content: NoteContent
    /// Files sent along: those dropped in the text are in `content` (an attachment character and
    /// its name, the file in `attachmentsDirectory`); those of a forwarded message are here.
    var forwardedFiles: [File] = []
    var inReplyTo: String?
    var references: [String] = []
    /// A draft continued from Brouillons: that message there, replaced when this one is saved
    /// again or sent.
    var replaces: Origin?

    struct Origin: Equatable {
        var mailbox: String
        var uid: Int
    }
    /// What the window starts with, to tell a draft worth keeping from an untouched one.
    var isEmpty: Bool {
        to.isEmpty && cc.isEmpty && bcc.isEmpty && subject.isEmpty
            && content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(account: UUID, to: String = "", cc: String = "", bcc: String = "", subject: String = "", content: NoteContent = NoteContent()) {
        id = UUID()
        self.account = account
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.content = content
    }

    /// Where the files dropped in the text are kept while it is written.
    var attachmentsDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("drafts/\(id.uuidString)", isDirectory: true)
    }

    var recipients: [MailAddress] {
        [to, cc, bcc].flatMap(MailAddress.parseHeader).filter { $0.address.contains("@") }
    }

    /// Addresses that don't look like addresses, to say before sending.
    var invalidAddresses: [String] {
        [to, cc, bcc].flatMap(MailAddress.parseHeader).map(\.address).filter { address in
            address.range(of: #"^[^@\s<>]+@[^@\s<>]+\.[^@\s<>]+$"#, options: .regularExpression) == nil
        }
    }

    // MARK: Replying and forwarding

    /// « Le 18 oct. 2026 à 15:41, Camille a écrit : » then the original text, quoted.
    static func reply(to message: MailMessage, summary: MessageSummary, account: MailAccount, all: Bool) -> Draft {
        let sender = (message.replyTo.first ?? message.from.first ?? summary.sender)
        var to = [sender]
        var cc: [MailAddress] = []
        if all {
            let me = account.address.lowercased()
            to += message.to.filter { $0.address.lowercased() != me && $0.address.lowercased() != sender.address.lowercased() }
            cc = message.cc.filter { $0.address.lowercased() != me }
        }
        var draft = Draft(account: account.id, to: format(to), cc: format(cc), subject: prefixed("Re", summary.subject))
        let intro = "Le \(introDate(message.date ?? summary.date)), \(sender.display) a écrit :"
        draft.content = quoted(intro: intro, text: message.readableText)
        draft.inReplyTo = message.messageID
        draft.references = message.references + [message.messageID].compactMap { $0 }
        return draft
    }

    /// A message of Brouillons, to be continued: its recipients, subject and fields, its text
    /// back in the editor's format (the plain version is the Markdown it was saved as), its files.
    static func resume(_ message: MailMessage, summary: MessageSummary, account: MailAccount) -> Draft {
        var draft = Draft(account: account.id, to: format(message.to), cc: format(message.cc), bcc: format(message.bcc),
                          subject: message.subject.isEmpty ? summary.subject : message.subject)
        let text = message.plainText.map { $0.replacingOccurrences(of: "\r\n", with: "\n") } ?? message.readableText
        draft.content = NoteMarkdown.content(fromMarkdown: text.trimmingCharacters(in: .newlines))
        draft.forwardedFiles = message.attachments.map { File(name: $0.filename, data: $0.data, contentType: $0.contentType) }
        draft.inReplyTo = message.inReplyTo
        draft.references = message.references
        draft.replaces = Origin(mailbox: summary.mailbox, uid: summary.uid)
        return draft
    }

    static func forward(_ message: MailMessage, summary: MessageSummary, account: MailAccount) -> Draft {
        var draft = Draft(account: account.id, subject: prefixed("Fwd", summary.subject))
        let header = [
            "---------- Message transféré ----------",
            "De : \(format(message.from))",
            "Date : \(introDate(message.date ?? summary.date))",
            "Objet : \(summary.subject)",
            "À : \(format(message.to))",
        ] + (message.cc.isEmpty ? [] : ["Cc : \(format(message.cc))"])
        let text = "\n\n" + header.joined(separator: "\n") + "\n\n" + message.readableText.replacingOccurrences(of: "\r\n", with: "\n")
        draft.content = NoteContent(text: text, runs: [])
        draft.forwardedFiles = message.attachments.map { File(name: $0.filename, data: $0.data, contentType: $0.contentType) }
        draft.references = message.references + [message.messageID].compactMap { $0 }
        return draft
    }

    /// The reply's text: a blank line to write in, the intro, the original as a quote.
    private static func quoted(intro: String, text: String) -> NoteContent {
        // CRLF is one line break, not two.
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        // A long thread: the beginning of it is enough.
        // The editor spaces its paragraphs: the blank lines between them would double it.
        let kept = lines.prefix(400).map { $0.hasPrefix(">") ? String($0.drop { $0 == ">" || $0 == " " }) : $0 }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let head = "\n\n" + intro + "\n"
        let body = kept.joined(separator: "\n")
        let start = (head as NSString).length
        return NoteContent(text: head + body, runs: body.isEmpty ? [] : [StyleRun(start: start, length: (body as NSString).length, block: .quote)])
    }

    private static func prefixed(_ prefix: String, _ subject: String) -> String {
        let lower = subject.lowercased()
        if lower.hasPrefix(prefix.lowercased() + ":") || (prefix == "Re" && lower.hasPrefix("re :")) || (prefix == "Fwd" && (lower.hasPrefix("tr:") || lower.hasPrefix("fw:"))) { return subject }
        return "\(prefix): \(subject)"
    }

    static func format(_ addresses: [MailAddress]) -> String {
        addresses.map { $0.name.isEmpty ? $0.address : "\($0.name) <\($0.address)>" }.joined(separator: ", ")
    }

    private static func introDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.setLocalizedDateFormatFromTemplate("dMMMyHm")
        return formatter.string(from: date)
    }
}

/// A draft made into a message (RFC 5322 and MIME): headers, the text in two versions — plain
/// (Markdown, readable as is) and HTML —, the files. What SMTP sends and IMAP keeps.
enum MessageComposer {
    struct Built {
        var data: Data
        var messageID: String
        var envelopeFrom: String
        var recipients: [String]
    }

    /// `asDraft`: the Bcc are kept in a header, for the draft to be continued with them.
    static func build(_ draft: Draft, from account: MailAccount, files: [Draft.File], date: Date = Date(), boundarySeed: String = UUID().uuidString,
                      asDraft: Bool = false) -> Built {
        let domain = account.address.split(separator: "@").last.map(String.init) ?? "void.mail"
        let messageID = "<\(UUID().uuidString.lowercased())@\(domain)>"
        var headers: [(String, String)] = [
            ("From", address(MailAddress(name: account.name, address: account.address))),
        ]
        let to = MailAddress.parseHeader(draft.to), cc = MailAddress.parseHeader(draft.cc)
        if !to.isEmpty { headers.append(("To", to.map(address).joined(separator: ", "))) }
        if !cc.isEmpty { headers.append(("Cc", cc.map(address).joined(separator: ", "))) }
        let bcc = MailAddress.parseHeader(draft.bcc)
        if asDraft, !bcc.isEmpty { headers.append(("Bcc", bcc.map(address).joined(separator: ", "))) }
        headers += [
            ("Subject", encodeWord(draft.subject)),
            ("Date", dateFormatter.string(from: date)),
            ("Message-ID", messageID),
        ]
        if let inReplyTo = draft.inReplyTo { headers.append(("In-Reply-To", inReplyTo)) }
        if !draft.references.isEmpty { headers.append(("References", draft.references.suffix(20).joined(separator: " "))) }
        headers += [("MIME-Version", "1.0"), ("User-Agent", "Void Mail")]

        let plain = NoteMarkdown.markdown(from: draft.content)
            .replacingOccurrences(of: String(NoteText.attachmentCharacter), with: "")
        let html = NoteHTML.html(from: draft.content)
        let seed = boundarySeed.replacingOccurrences(of: "-", with: "").prefix(24)
        let alternative = "alt-\(seed)", mixed = "mix-\(seed)"

        var body = ""
        let textParts = """
        --\(alternative)\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        \(quotedPrintable(plain))\r
        --\(alternative)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        \(quotedPrintable(html))\r
        --\(alternative)--\r

        """
        if files.isEmpty {
            headers.append(("Content-Type", "multipart/alternative; boundary=\"\(alternative)\""))
            body = textParts
        } else {
            headers.append(("Content-Type", "multipart/mixed; boundary=\"\(mixed)\""))
            body = "--\(mixed)\r\nContent-Type: multipart/alternative; boundary=\"\(alternative)\"\r\n\r\n" + textParts
            for file in files {
                let name = parameter(file.name)
                body += "--\(mixed)\r\nContent-Type: \(file.contentType); name=\(name)\r\nContent-Disposition: attachment; filename=\(name)\r\nContent-Transfer-Encoding: base64\r\n\r\n"
                body += file.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]) + "\r\n"
            }
            body += "--\(mixed)--\r\n"
        }
        let head = headers.map { "\($0.0): \(fold($0.1))" }.joined(separator: "\r\n")
        let recipients = draft.recipients.map(\.address)
        return Built(data: Data((head + "\r\n\r\n" + body).utf8), messageID: messageID, envelopeFrom: account.address, recipients: Array(NSOrderedSet(array: recipients)) as? [String] ?? recipients)
    }

    // MARK: Encodings

    /// `Camille Moreau <camille@exemple.fr>`, the name encoded or quoted as needed.
    static func address(_ address: MailAddress) -> String {
        guard !address.name.isEmpty else { return address.address }
        let name: String
        if address.name.unicodeScalars.contains(where: { !$0.isASCII }) {
            name = encodeWord(address.name)
        } else if address.name.rangeOfCharacter(from: CharacterSet(charactersIn: "()<>[]:;@\\,.\"")) != nil {
            name = "\"" + address.name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        } else {
            name = address.name
        }
        return "\(name) <\(address.address)>"
    }

    /// Non-ASCII header text as RFC 2047 words (UTF-8, base64), cut so none passes 75 characters.
    static func encodeWord(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { !$0.isASCII }) else { return text }
        var words: [String] = []
        var chunk = ""
        for character in text {
            if Data((chunk + String(character)).utf8).count > 45 {
                words.append("=?utf-8?B?\(Data(chunk.utf8).base64EncodedString())?=")
                chunk = ""
            }
            chunk.append(character)
        }
        if !chunk.isEmpty { words.append("=?utf-8?B?\(Data(chunk.utf8).base64EncodedString())?=") }
        return words.joined(separator: " ")
    }

    /// A file name as a MIME parameter: quoted, encoded when it isn't ASCII.
    static func parameter(_ value: String) -> String {
        guard value.unicodeScalars.contains(where: { !$0.isASCII }) else {
            return "\"" + value.replacingOccurrences(of: "\"", with: "'") + "\""
        }
        // Encoded words, which every mail app reads in a file name, rather than RFC 2231, which some don't.
        return "\"\(encodeWord(value))\""
    }

    /// Long headers folded at spaces, under 78 characters a line.
    static func fold(_ value: String) -> String {
        guard value.count > 76 else { return value }
        var lines: [String] = []
        var line = ""
        for word in value.split(separator: " ", omittingEmptySubsequences: false) {
            if !line.isEmpty, line.count + word.count + 1 > 76 {
                lines.append(line)
                line = String(word)
            } else {
                line += (line.isEmpty ? "" : " ") + word
            }
        }
        lines.append(line)
        return lines.joined(separator: "\r\n ")
    }

    /// Quoted-printable (RFC 2045): lines of at most 76 characters, `=` and non-ASCII bytes as
    /// `=XX`, trailing spaces protected, CRLF line breaks.
    static func quotedPrintable(_ text: String) -> String {
        var out: [String] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            var encoded = ""
            var length = 0
            let bytes = Array(line.utf8)
            for (index, byte) in bytes.enumerated() {
                let isLast = index == bytes.count - 1
                let piece: String
                if (byte >= 33 && byte <= 126 && byte != 61) || (byte == 32 && !isLast) || (byte == 9 && !isLast) {
                    piece = String(UnicodeScalar(byte))
                } else {
                    piece = String(format: "=%02X", byte)
                }
                if length + piece.count > 75 {
                    encoded += "=\r\n"
                    length = 0
                }
                encoded += piece
                length += piece.count
            }
            out.append(encoded)
        }
        return out.joined(separator: "\r\n")
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return formatter
    }()

    /// The files a draft sends: those dropped in its text (from its folder), then those forwarded.
    static func files(of draft: Draft) -> [Draft.File] {
        var files: [Draft.File] = []
        for run in draft.content.runs {
            guard let name = run.attachment,
                  let data = try? Data(contentsOf: draft.attachmentsDirectory.appendingPathComponent(name)) else { continue }
            files.append(Draft.File(name: name, data: data, contentType: contentType(for: name)))
        }
        return files + draft.forwardedFiles
    }

    static func contentType(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": "application/pdf"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "heic": "image/heic"
        case "txt", "md": "text/plain"
        case "zip": "application/zip"
        case "doc": "application/msword"
        case "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "ics": "text/calendar"
        default: "application/octet-stream"
        }
    }
}
