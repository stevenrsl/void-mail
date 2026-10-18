import Foundation

/// A server's response line as it came, its literals (`{n}` then n bytes) kept in place, raw:
/// a message's headers and body are bytes in their own charset, not UTF-8.
struct IMAPLine {
    var data: Data
    /// Offsets in `data` where a literal's bytes begin (right after its `{n}`).
    var literalStarts: Set<Int> = []

    init(data: Data, literalStarts: Set<Int> = []) {
        self.data = data
        self.literalStarts = literalStarts
    }

    init(_ text: String) {
        data = Data(text.utf8)
    }

    var text: String { String(decoding: data, as: UTF8.self) }

    var values: [IMAPValue] {
        var parser = IMAPParser(bytes: [UInt8](data), literalStarts: literalStarts)
        return parser.parseAll()
    }
}

/// What an IMAP response is made of (RFC 9051 §4): atoms and numbers, strings (quoted or
/// literal, kept as bytes), parenthesized lists, NIL.
indirect enum IMAPValue: Equatable {
    case atom(String)
    case string(Data)
    case list([IMAPValue])
    case nilValue

    /// An atom's or a string's text (UTF-8, Latin-1 if it isn't); nil for NIL and lists.
    var text: String? {
        switch self {
        case .atom(let atom): atom
        case .string(let data): String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        default: nil
        }
    }

    var data: Data? {
        switch self {
        case .string(let data): data
        case .atom(let atom): Data(atom.utf8)
        default: nil
        }
    }

    var list: [IMAPValue]? {
        if case .list(let items) = self { return items }
        return nil
    }

    var number: Int? { text.flatMap { Int($0) } }

    /// A FETCH item list `(UID 4 FLAGS (\Seen) …)` as a dictionary, its keys uppercased.
    var pairs: [String: IMAPValue] {
        guard let items = list else { return [:] }
        var result: [String: IMAPValue] = [:]
        var index = 0
        while index + 1 < items.count {
            if let key = items[index].text { result[key.uppercased()] = items[index + 1] }
            index += 2
        }
        return result
    }
}

struct IMAPParser {
    let bytes: [UInt8]
    let literalStarts: Set<Int>
    var index = 0

    init(bytes: [UInt8], literalStarts: Set<Int>) {
        self.bytes = bytes
        self.literalStarts = literalStarts
    }

    mutating func parseAll() -> [IMAPValue] {
        var values: [IMAPValue] = []
        while let value = next() { values.append(value) }
        return values
    }

    private mutating func skipSpaces() {
        while index < bytes.count, bytes[index] == 0x20 { index += 1 }
    }

    /// The next value; nil at the end, or at the `)` closing the list being read.
    private mutating func next() -> IMAPValue? {
        skipSpaces()
        guard index < bytes.count else { return nil }
        switch bytes[index] {
        case 0x28: // (
            index += 1
            var items: [IMAPValue] = []
            while true {
                skipSpaces()
                guard index < bytes.count else { return .list(items) }
                if bytes[index] == 0x29 { index += 1; return .list(items) }
                guard let item = next() else { return .list(items) }
                items.append(item)
            }
        case 0x29: // ) where no list is open: ignored
            index += 1
            return next()
        case 0x22: // "
            index += 1
            var result: [UInt8] = []
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x5C, index + 1 < bytes.count { // \
                    result.append(bytes[index + 1])
                    index += 2
                } else if byte == 0x22 {
                    index += 1
                    break
                } else {
                    result.append(byte)
                    index += 1
                }
            }
            return .string(Data(result))
        case 0x7B: // {n} followed by its literal
            if let close = bytes[index...].firstIndex(of: 0x7D) {
                let digits = bytes[(index + 1)..<close].filter { $0 != 0x2B } // `{n+}`
                if let count = Int(String(decoding: digits, as: UTF8.self)), literalStarts.contains(close + 1) {
                    let end = min(bytes.count, close + 1 + count)
                    index = end
                    return .string(Data(bytes[(close + 1)..<end]))
                }
            }
            return atom()
        default:
            return atom()
        }
    }

    /// An atom: up to a space or a parenthesis, `[…]` included whole (`BODY[HEADER.FIELDS (DATE)]`).
    private mutating func atom() -> IMAPValue {
        let start = index
        var depth = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x5B { depth += 1 } else if byte == 0x5D { depth -= 1 }
            if depth <= 0, byte == 0x20 || byte == 0x28 || byte == 0x29 { break }
            index += 1
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        return text.uppercased() == "NIL" ? .nilValue : .atom(text)
    }
}

/// An address of an ENVELOPE: `("Camille" NIL "camille" "exemple.fr")`.
struct MailAddress: Codable, Hashable {
    var name: String
    var address: String

    /// The name if there is one, else the address.
    var display: String { name.isEmpty ? address : name }

    static func list(from value: IMAPValue) -> [MailAddress] {
        (value.list ?? []).compactMap { entry in
            guard let parts = entry.list, parts.count >= 4 else { return nil }
            let name = parts[0].text.map(MIMEHeader.decodeWords) ?? ""
            guard let mailbox = parts[2].text else { return nil }
            let address = parts[3].text.map { "\(mailbox)@\($0)" } ?? mailbox
            return MailAddress(name: name, address: address)
        }
    }

    /// `Camille <camille@exemple.fr>, b@c.fr` (a To or Cc header) → addresses.
    static func parseHeader(_ text: String) -> [MailAddress] {
        var results: [MailAddress] = []
        var current = "", quoted = false, angle = 0
        for character in text {
            if character == "\"" { quoted.toggle() }
            if !quoted, character == "<" { angle += 1 }
            if !quoted, character == ">" { angle -= 1 }
            if character == ",", !quoted, angle == 0 {
                results.append(contentsOf: single(current))
                current = ""
            } else {
                current.append(character)
            }
        }
        results.append(contentsOf: single(current))
        return results
    }

    private static func single(_ text: String) -> [MailAddress] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        if let open = trimmed.lastIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close {
            let name = trimmed[..<open].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return [MailAddress(name: MIMEHeader.decodeWords(name), address: String(trimmed[trimmed.index(after: open)..<close]))]
        }
        return [MailAddress(name: "", address: trimmed)]
    }
}

/// A message as the list shows it: what FETCH ENVELOPE gives, without its body.
struct MessageEnvelope: Equatable {
    var uid: Int
    var flags: Set<String>
    var date: Date
    var size: Int
    var subject: String
    var from: [MailAddress]
    var to: [MailAddress]
    var cc: [MailAddress]
    var messageID: String?

    /// `* 12 FETCH (UID 345 FLAGS (\Seen) INTERNALDATE "…" RFC822.SIZE 1234 ENVELOPE (…))`.
    init?(fetch line: IMAPLine) {
        let values = line.values
        guard values.count >= 4, values[2].text?.uppercased() == "FETCH" else { return nil }
        let items = values[3].pairs
        guard let uid = items["UID"]?.number else { return nil }
        self.uid = uid
        flags = Set((items["FLAGS"]?.list ?? []).compactMap(\.text))
        size = items["RFC822.SIZE"]?.number ?? 0
        let envelope = items["ENVELOPE"]?.list ?? []
        func field(_ index: Int) -> IMAPValue { index < envelope.count ? envelope[index] : .nilValue }
        subject = field(1).text.map(MIMEHeader.decodeWords) ?? ""
        from = MailAddress.list(from: field(2))
        to = MailAddress.list(from: field(5))
        cc = MailAddress.list(from: field(6))
        messageID = field(9).text
        // The server's arrival date: it doesn't lie about the year, as a sender's Date header can.
        date = items["INTERNALDATE"]?.text.flatMap(Self.internalDate)
            ?? field(0).text.flatMap(MIMEHeader.date) ?? Date(timeIntervalSince1970: 0)
    }

    init(uid: Int, flags: Set<String>, date: Date, size: Int, subject: String, from: [MailAddress], to: [MailAddress], cc: [MailAddress], messageID: String?) {
        self.uid = uid
        self.flags = flags
        self.date = date
        self.size = size
        self.subject = subject
        self.from = from
        self.to = to
        self.cc = cc
        self.messageID = messageID
    }

    static func internalDate(_ text: String) -> Date? {
        internalFormatter.date(from: text.trimmingCharacters(in: .whitespaces))
    }

    private static let internalFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        return formatter
    }()
}
