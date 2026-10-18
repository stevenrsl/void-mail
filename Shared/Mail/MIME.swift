import Foundation

/// Header values (RFC 5322, 2047, 2231): unfolding, encoded words, parameters, dates.
enum MIMEHeader {
    /// `=?utf-8?Q?Caf=C3=A9?= =?utf-8?B?…?=` → text; words side by side join without their space.
    static func decodeWords(_ text: String) -> String {
        guard text.contains("=?") else { return text }
        let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let source = text as NSString
        var result = ""
        var cursor = 0
        var lastWasEncoded = false
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let between = source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            if !(lastWasEncoded && between.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { result += between }
            let charset = source.substring(with: match.range(at: 1)).split(separator: "*").first.map(String.init) ?? "utf-8"
            let encoding = source.substring(with: match.range(at: 2)).uppercased()
            let payload = source.substring(with: match.range(at: 3))
            let bytes: Data? = encoding == "B"
                ? Data(base64Encoded: padded(payload))
                : quotedPrintable(Data(payload.replacingOccurrences(of: "_", with: " ").utf8), header: true)
            if let bytes, let decoded = MIMECharset.string(bytes, charset: charset) {
                result += decoded
            } else {
                result += source.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
            lastWasEncoded = true
        }
        result += source.substring(from: cursor)
        return result
    }

    /// `text/plain; charset="utf-8"; format=flowed` → ("text/plain", [charset: utf-8, format: flowed]),
    /// RFC 2231's `name*=utf-8''…` and `name*0*=…` continuations joined and decoded.
    static func parameters(_ value: String) -> (String, [String: String]) {
        var parts: [String] = []
        var current = "", quoted = false
        for character in value {
            if character == "\"" { quoted.toggle() }
            if character == ";", !quoted { parts.append(current); current = "" } else { current.append(character) }
        }
        parts.append(current)
        let main = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        var plain: [String: String] = [:]
        var extended: [String: [(Int, String, Bool)]] = [:]
        for part in parts.dropFirst() {
            guard let equals = part.firstIndex(of: "=") else { continue }
            var key = part[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var raw = part[part.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 { raw = String(raw.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"") }
            guard key.contains("*") else { plain[key] = decodeWords(raw); continue }
            let encoded = key.hasSuffix("*")
            if encoded { key.removeLast() }
            let pieces = key.split(separator: "*")
            let name = String(pieces.first ?? "")
            let order = pieces.count > 1 ? Int(pieces[1]) ?? 0 : 0
            extended[name, default: []].append((order, raw, encoded))
        }
        for (name, pieces) in extended {
            let sorted = pieces.sorted { $0.0 < $1.0 }
            var charset = "utf-8"
            var bytes = Data()
            for (index, piece) in sorted.enumerated() {
                var text = piece.1
                if piece.2 {
                    if index == 0 {
                        let fields = text.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                        if fields.count == 3 { charset = String(fields[0]).isEmpty ? charset : String(fields[0]); text = String(fields[2]) }
                    }
                    bytes.append(percentDecoded(text))
                } else {
                    bytes.append(Data(text.utf8))
                }
            }
            plain[name] = MIMECharset.string(bytes, charset: charset) ?? plain[name]
        }
        return (main, plain)
    }

    static func date(_ text: String) -> Date? {
        var cleaned = text.trimmingCharacters(in: .whitespaces)
        if let comment = cleaned.firstIndex(of: "(") { cleaned = cleaned[..<comment].trimmingCharacters(in: .whitespaces) }
        for formatter in dateFormatters {
            if let date = formatter.date(from: cleaned) { return date }
        }
        return nil
    }

    private static let dateFormatters: [DateFormatter] = ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yyyy HH:mm:ss zzz"].map {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = $0
        return formatter
    }

    static func quotedPrintable(_ data: Data, header: Bool = false) -> Data {
        let bytes = [UInt8](data)
        var result = Data(capacity: bytes.count)
        var index = 0
        func hex(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x30...0x39: byte - 0x30
            case 0x41...0x46: byte - 0x37
            case 0x61...0x66: byte - 0x57
            default: nil
            }
        }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x3D { // =
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A { index += 2; continue } // soft break (LF)
                if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A { index += 3; continue } // soft break (CRLF)
                if index + 2 < bytes.count, let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) {
                    result.append(high << 4 | low)
                    index += 3
                    continue
                }
            }
            result.append(byte)
            index += 1
        }
        return result
    }

    static func padded(_ base64: String) -> String {
        let cleaned = base64.filter { !$0.isWhitespace }
        return cleaned + String(repeating: "=", count: (4 - cleaned.count % 4) % 4)
    }

    private static func percentDecoded(_ text: String) -> Data {
        var result = Data()
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "%", let end = text.index(index, offsetBy: 3, limitedBy: text.endIndex),
               let byte = UInt8(text[text.index(after: index)..<end], radix: 16) {
                result.append(byte)
                index = end
            } else {
                result.append(contentsOf: Array(String(text[index]).utf8))
                index = text.index(after: index)
            }
        }
        return result
    }
}

enum MIMECharset {
    /// Bytes in a named charset; UTF-8, then Windows-1252, when the name is unknown or wrong.
    static func string(_ data: Data, charset: String?) -> String? {
        if let charset {
            let name = charset.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).lowercased()
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let text = String(data: data, encoding: encoding) { return text }
            }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1)
    }
}

/// One part of a message: its headers and decoded body, its children for a multipart.
struct MIMEPart {
    var headers: [(String, String)]
    var contentType: String
    var parameters: [String: String]
    var body: Data
    var parts: [MIMEPart]

    func header(_ name: String) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }

    var disposition: (String, [String: String])? {
        header("Content-Disposition").map(MIMEHeader.parameters)
    }

    var filename: String? {
        disposition?.1["filename"] ?? parameters["name"]
    }

    var contentID: String? {
        header("Content-ID")?.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
    }

    var isAttachment: Bool {
        if disposition?.0 == "attachment" { return true }
        if contentType.hasPrefix("text/plain") || contentType.hasPrefix("text/html") { return filename != nil && disposition?.0 != "inline" }
        return !contentType.hasPrefix("multipart/")
    }

    var text: String? { MIMECharset.string(body, charset: parameters["charset"]) }

    /// A whole message or part, as bytes: headers, blank line, body.
    init(raw: Data, defaultType: String = "text/plain") {
        let bytes = [UInt8](raw)
        let (headerEnd, bodyStart) = Self.headerBoundary(bytes)
        let headerText = MIMECharset.string(Data(bytes[0..<headerEnd]), charset: "utf-8") ?? ""
        headers = Self.unfold(headerText)
        let typeHeader = headers.first { $0.0.caseInsensitiveCompare("Content-Type") == .orderedSame }?.1
        (contentType, parameters) = typeHeader.map(MIMEHeader.parameters) ?? (defaultType, [:])
        if contentType.isEmpty { contentType = defaultType }
        let rawBody = Data(bytes[bodyStart...])
        if contentType.hasPrefix("multipart/"), let boundary = parameters["boundary"] {
            let childType = contentType == "multipart/digest" ? "message/rfc822" : "text/plain"
            parts = Self.split(rawBody, boundary: boundary).map { MIMEPart(raw: $0, defaultType: childType) }
            body = Data()
        } else {
            parts = []
            let encoding = headers.first { $0.0.caseInsensitiveCompare("Content-Transfer-Encoding") == .orderedSame }?.1
                .trimmingCharacters(in: .whitespaces).lowercased()
            switch encoding {
            case "base64": body = Data(base64Encoded: MIMEHeader.padded(String(decoding: rawBody, as: UTF8.self))) ?? Data()
            case "quoted-printable": body = MIMEHeader.quotedPrintable(rawBody)
            default: body = rawBody
            }
        }
    }

    /// Where the headers end and the body begins: the first blank line (CRLF or LF alone).
    private static func headerBoundary(_ bytes: [UInt8]) -> (Int, Int) {
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x0A {
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A { return (index, index + 2) }
                if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A { return (index, index + 3) }
            }
            index += 1
        }
        return (bytes.count, bytes.count)
    }

    private static func unfold(_ text: String) -> [(String, String)] {
        var result: [(String, String)] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if let first = line.first, first == " " || first == "\t", !result.isEmpty {
                result[result.count - 1].1 += " " + line.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let colon = line.firstIndex(of: ":") {
                // A lone CR (the one before the blank line) is no part of the value.
                result.append((String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines),
                               String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        return result
    }

    /// The parts between `--boundary` lines, up to `--boundary--`.
    private static func split(_ body: Data, boundary: String) -> [Data] {
        let delimiter = Data(("--" + boundary).utf8)
        var parts: [Data] = []
        var searchStart = body.startIndex
        var partStart: Data.Index?
        while let range = body.range(of: delimiter, in: searchStart..<body.endIndex) {
            // A delimiter starts a line.
            let atLineStart = range.lowerBound == body.startIndex || body[range.lowerBound - 1] == 0x0A
            guard atLineStart else { searchStart = range.upperBound; continue }
            if let start = partStart {
                var end = range.lowerBound
                if end > start, body[end - 1] == 0x0A { end -= 1 }
                if end > start, body[end - 1] == 0x0D { end -= 1 }
                parts.append(Data(body[start..<end]))
            }
            let after = range.upperBound
            if after + 1 < body.endIndex, body[after] == 0x2D, body[after + 1] == 0x2D { return parts }
            // The rest of the delimiter line is ignored.
            guard let newline = body[after...].firstIndex(of: 0x0A) else { return parts }
            partStart = newline + 1
            searchStart = newline + 1
        }
        if let start = partStart, start < body.endIndex { parts.append(Data(body[start...])) }
        return parts
    }
}

/// What the message pane shows of a message: its headers, its text, its HTML (inline images
/// turned into `data:` addresses), its attachments.
struct MailMessage {
    struct Attachment: Identifiable {
        var id: Int
        var filename: String
        var contentType: String
        var data: Data
    }

    var subject: String
    var from: [MailAddress]
    var replyTo: [MailAddress]
    var to: [MailAddress]
    var cc: [MailAddress]
    /// Only in a draft (a sent message has none).
    var bcc: [MailAddress]
    var date: Date?
    var messageID: String?
    var inReplyTo: String?
    /// The thread it answers, oldest first (its References header).
    var references: [String]
    var plainText: String?
    var html: String?
    var attachments: [Attachment]

    init(raw: Data) {
        let root = MIMEPart(raw: raw)
        subject = root.header("Subject").map(MIMEHeader.decodeWords) ?? ""
        from = root.header("From").map(MailAddress.parseHeader) ?? []
        to = root.header("To").map(MailAddress.parseHeader) ?? []
        cc = root.header("Cc").map(MailAddress.parseHeader) ?? []
        replyTo = root.header("Reply-To").map(MailAddress.parseHeader) ?? []
        bcc = root.header("Bcc").map(MailAddress.parseHeader) ?? []
        inReplyTo = root.header("In-Reply-To")?.trimmingCharacters(in: .whitespaces)
        date = root.header("Date").flatMap(MIMEHeader.date)
        messageID = root.header("Message-ID")?.trimmingCharacters(in: .whitespaces)
        references = (root.header("References") ?? "").split(whereSeparator: \.isWhitespace).map(String.init).filter { $0.hasPrefix("<") }
        var plain: String?, html: String?
        var attachments: [Attachment] = []
        var inline: [String: (String, Data)] = [:]

        func walk(_ part: MIMEPart) {
            if part.contentType == "multipart/alternative" {
                // The richest version the app can show: the last one, HTML before text.
                for child in part.parts where child.contentType == "text/html" && html == nil { html = child.text }
                for child in part.parts where child.contentType == "text/plain" && plain == nil { plain = child.text }
                for child in part.parts where child.contentType.hasPrefix("multipart/") { walk(child) }
                return
            }
            if part.contentType.hasPrefix("multipart/") { part.parts.forEach(walk); return }
            if let id = part.contentID, part.contentType.hasPrefix("image/") {
                inline[id] = (part.contentType, part.body)
                if part.disposition?.0 != "attachment" { return }
            }
            if part.isAttachment {
                let name = part.filename ?? (part.contentType == "message/rfc822" ? "message.eml" : "pièce jointe")
                attachments.append(Attachment(id: attachments.count, filename: name, contentType: part.contentType, data: part.body))
            } else if part.contentType == "text/html", html == nil {
                html = part.text
            } else if part.contentType.hasPrefix("text/"), plain == nil {
                plain = part.text
            }
        }
        walk(root)
        if var page = html {
            for (id, image) in inline {
                page = page.replacingOccurrences(of: "cid:\(id)", with: "data:\(image.0);base64,\(image.1.base64EncodedString())")
            }
            html = page
        }
        self.plainText = plain
        self.html = html
        self.attachments = attachments
    }

    /// The text for the search index: the plain text, else the HTML without its tags.
    var searchableText: String {
        if let plainText { return plainText }
        guard let html else { return "" }
        return html.replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    /// The text to quote in a reply or a forward: the plain version, else the HTML read as text,
    /// its paragraphs and line breaks kept.
    var readableText: String {
        if let plainText { return plainText }
        guard let html else { return "" }
        var text = html.replacingOccurrences(of: "<(style|script|head)[^>]*>[\\s\\S]*?</\\1>", with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</(p|div|li|h[1-6]|tr|blockquote)>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, character) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&rsquo;": "’", "&eacute;": "é", "&egrave;": "è", "&agrave;": "à"] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n").replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The HTML loads images from the Internet (pixels that tell the sender the message was read).
    var hasRemoteImages: Bool {
        guard let html else { return false }
        return html.range(of: #"(src|background)\s*=\s*["']?https?://"#, options: [.regularExpression, .caseInsensitive]) != nil
            || html.range(of: #"url\(\s*["']?https?://"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
