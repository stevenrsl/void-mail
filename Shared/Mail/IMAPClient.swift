import Foundation

/// The beginning of IMAP (RFC 9051, and 3501 for the servers still on it): greeting, STARTTLS,
/// CAPABILITY, sign-in (AUTHENTICATE PLAIN or XOAUTH2, LOGIN as a last resort), LIST, LOGOUT —
/// enough to check an account and find its mailboxes. Fetching messages comes next.
final class IMAPClient {
    private let stream: MailStream
    private var tag = 0
    private(set) var capabilities: Set<String> = []

    var transcript: [String] { stream.transcript }

    private init(stream: MailStream) {
        self.stream = stream
    }

    /// Connected, secured, greeted, capabilities known.
    static func connect(to endpoint: ServerEndpoint) async throws -> IMAPClient {
        let client = IMAPClient(stream: try MailStream(endpoint: endpoint))
        let greeting = try await client.stream.readLine()
        guard greeting.hasPrefix("* OK") || greeting.hasPrefix("* PREAUTH") else { throw MailError.unexpected(greeting) }
        client.capabilities = Self.capabilities(in: greeting)
        if endpoint.security == .startTLS {
            if client.capabilities.isEmpty { try await client.refreshCapabilities() }
            _ = try await client.command("STARTTLS")
            client.stream.startTLS()
            client.capabilities = []
        }
        // Capabilities change once secured; a greeting may not have listed them.
        if client.capabilities.isEmpty { try await client.refreshCapabilities() }
        return client
    }

    func authenticate(user: String, credential: SASL.Credential) async throws {
        let saslIR = capabilities.contains("SASL-IR")
        switch credential {
        case .token(let token):
            let response = SASL.xoauth2(user: user, token: token)
            try await authenticate(mechanism: "XOAUTH2", response: response, initial: saslIR)
        case .password(let password):
            if capabilities.contains("AUTH=PLAIN") {
                try await authenticate(mechanism: "PLAIN", response: SASL.plain(user: user, password: password), initial: saslIR)
            } else if !capabilities.contains("LOGINDISABLED") {
                do {
                    _ = try await command("LOGIN \(Self.quoted(user)) \(Self.quoted(password))", secret: Self.quoted(password))
                } catch MailError.unexpected(let line) {
                    throw MailError.authentication(line)
                }
            } else {
                throw MailError.noSecureLogin
            }
        }
        // Servers often tell more once signed in.
        try await refreshCapabilities()
    }

    /// Every mailbox of the account, special-use attributes included where the server has them.
    func listMailboxes() async throws -> [Mailbox] {
        let specialUse = capabilities.contains("SPECIAL-USE")
        let lines = try await command(specialUse ? "LIST \"\" \"*\" RETURN (SPECIAL-USE)" : "LIST \"\" \"*\"")
        return lines.compactMap { line in
            guard var mailbox = Self.parseList(line) else { return nil }
            if mailbox.role == .other, !specialUse { mailbox.attributes.formUnion(Mailbox.guessedAttributes(for: mailbox.path)) }
            return mailbox
        }
    }

    struct Selection: Equatable {
        var exists = 0
        var uidValidity = 0
        var uidNext: Int?
    }

    /// Opens a mailbox: how many messages, and the numbering of their UIDs.
    func select(_ path: String) async throws -> Selection {
        var selection = Selection()
        for line in try await command("SELECT \(Self.quoted(ModifiedUTF7.encode(path)))") {
            let text = line.text
            let words = text.split(separator: " ")
            if words.count >= 3, words[2].uppercased() == "EXISTS" { selection.exists = Int(words[1]) ?? 0 }
            if let value = Self.code("UIDVALIDITY", in: text) { selection.uidValidity = value }
            if let value = Self.code("UIDNEXT", in: text) { selection.uidNext = value }
        }
        return selection
    }

    static let envelopeItems = "(UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE)"

    /// Envelopes by UID range (`123:*`), or the last `count` messages by position (first visit).
    func fetchEnvelopes(uidsFrom first: Int) async throws -> [MessageEnvelope] {
        try await command("UID FETCH \(first):* \(Self.envelopeItems)").compactMap(MessageEnvelope.init(fetch:))
            .filter { $0.uid >= first }
    }

    func fetchLatestEnvelopes(count: Int, exists: Int) async throws -> [MessageEnvelope] {
        guard exists > 0 else { return [] }
        return try await command("FETCH \(max(1, exists - count + 1)):* \(Self.envelopeItems)").compactMap(MessageEnvelope.init(fetch:))
    }

    /// The flags of every message from a UID on: those absent are gone from the server.
    func fetchFlags(uidsFrom first: Int) async throws -> [Int: Set<String>] {
        var result: [Int: Set<String>] = [:]
        for line in try await command("UID FETCH \(first):* (UID FLAGS)") {
            let values = line.values
            guard values.count >= 4 else { continue }
            let items = values[3].pairs
            if let uid = items["UID"]?.number, uid >= first { result[uid] = Set((items["FLAGS"]?.list ?? []).compactMap(\.text)) }
        }
        return result
    }

    /// The whole message, as it is on the server, without marking it read.
    func fetchBody(uid: Int) async throws -> Data? {
        for line in try await command("UID FETCH \(uid) (UID BODY.PEEK[])") {
            let values = line.values
            guard values.count >= 4 else { continue }
            let items = values[3].pairs
            if items["UID"]?.number == uid, let body = items["BODY[]"]?.data { return body }
        }
        return nil
    }

    func store(uid: Int, flag: String, on: Bool) async throws {
        try await command("UID STORE \(uid) \(on ? "+" : "-")FLAGS.SILENT (\(flag))")
    }

    /// `* OK [UIDVALIDITY 3857529045] …` → 3857529045.
    static func code(_ name: String, in text: String) -> Int? {
        guard let range = text.range(of: "[\(name) ", options: .caseInsensitive) else { return nil }
        return Int(text[range.upperBound...].prefix { $0.isNumber })
    }

    func logout() async {
        _ = try? await command("LOGOUT")
        stream.close()
    }

    // MARK: Commands

    private func refreshCapabilities() async throws {
        let lines = try await command("CAPABILITY")
        capabilities = lines.reduce(into: []) { $0.formUnion(Self.capabilities(in: $1.text)) }
    }

    private func authenticate(mechanism: String, response: String, initial: Bool) async throws {
        tag += 1
        let label = "v\(tag)"
        if initial {
            try await stream.send("\(label) AUTHENTICATE \(mechanism) \(response)", secret: response)
        } else {
            try await stream.send("\(label) AUTHENTICATE \(mechanism)")
            let prompt = try await stream.readLine()
            guard prompt.hasPrefix("+") else { throw MailError.authentication(prompt) }
            try await stream.send(response, secret: response)
        }
        while true {
            let line = try await stream.readLine()
            if line.hasPrefix("+") {
                // XOAUTH2's error details: an empty answer ends the exchange, then comes the NO.
                try await stream.send("")
                continue
            }
            if line.hasPrefix(label + " ") {
                guard line.dropFirst(label.count + 1).hasPrefix("OK") else { throw MailError.authentication(String(line.dropFirst(label.count + 1))) }
                return
            }
        }
    }

    /// Sends a tagged command; returns the untagged lines (their literals in place), throws on
    /// NO or BAD.
    @discardableResult
    private func command(_ text: String, secret: String? = nil) async throws -> [IMAPLine] {
        tag += 1
        let label = "v\(tag)"
        try await stream.send("\(label) \(text)", secret: secret)
        var lines: [IMAPLine] = []
        while true {
            let line = try await readResponse()
            if line.data.starts(with: Data((label + " ").utf8)) {
                let status = String(line.text.dropFirst(label.count + 1))
                guard status.uppercased().hasPrefix("OK") else { throw MailError.unexpected(status) }
                return lines
            }
            if line.data.starts(with: Data("* ".utf8)) { lines.append(line) }
        }
    }

    /// A response, its `{n}` literals read and kept in place, as bytes.
    private func readResponse() async throws -> IMAPLine {
        var line = IMAPLine(data: try await stream.readLineData())
        while let count = Self.literalLength(at: line.data) {
            line.literalStarts.insert(line.data.count)
            line.data.append(try await stream.read(count: count))
            line.data.append(try await stream.readLineData())
        }
        return line
    }

    /// `… {123}` (or `{123+}`) at the end of the bytes read so far.
    private static func literalLength(at data: Data) -> Int? {
        guard data.last == 0x7D, let open = data.lastIndex(of: 0x7B) else { return nil }
        let digits = data[(open + 1)..<(data.endIndex - 1)].filter { $0 != 0x2B }
        guard !digits.isEmpty, digits.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        return Int(String(decoding: digits, as: UTF8.self))
    }

    // MARK: Parsing

    static func capabilities(in line: String) -> Set<String> {
        let upper = line.uppercased()
        let body: Substring
        if let range = upper.range(of: "[CAPABILITY ") {
            body = upper[range.upperBound...].prefix { $0 != "]" }
        } else if upper.hasPrefix("* CAPABILITY ") {
            body = upper.dropFirst("* CAPABILITY ".count)
        } else {
            return []
        }
        return Set(body.split(separator: " ").map(String.init))
    }

    /// `* LIST (\HasNoChildren \Sent) "/" "Sent Messages"` → a mailbox.
    static func parseList(_ line: IMAPLine) -> Mailbox? {
        let values = line.values
        guard values.count >= 5, values[0].text == "*", ["LIST", "XLIST"].contains(values[1].text?.uppercased() ?? ""),
              let flags = values[2].list, let name = values[4].text else { return nil }
        return Mailbox(path: ModifiedUTF7.decode(name), delimiter: values[3].text,
                       attributes: Set(flags.compactMap(\.text)))
    }

    static func parseList(_ line: String) -> Mailbox? { parseList(IMAPLine(line)) }

    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// IMAP's mailbox names (RFC 3501 §5.1.3): `&` opens a run of UTF-16 in a modified base64
/// (`,` for `/`), `-` closes it; `&-` is `&`.
enum ModifiedUTF7 {
    static func decode(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            guard let dash = after.firstIndex(of: "-") else { result += rest[amp...]; return result }
            let encoded = after[..<dash]
            if encoded.isEmpty {
                result += "&"
            } else {
                var base64 = encoded.replacingOccurrences(of: ",", with: "/")
                while base64.count % 4 != 0 { base64 += "=" }
                if let data = Data(base64Encoded: base64), let decoded = String(data: data, encoding: .utf16BigEndian) {
                    result += decoded
                } else {
                    result += rest[amp...dash]
                }
            }
            rest = after[after.index(after: dash)...]
        }
        return result + rest
    }

    static func encode(_ text: String) -> String {
        var result = ""
        var pending: [UInt16] = []
        func flush() {
            guard !pending.isEmpty else { return }
            let data = pending.reduce(into: Data()) { $0.append(contentsOf: [UInt8($1 >> 8), UInt8($1 & 0xFF)]) }
            result += "&" + data.base64EncodedString().replacingOccurrences(of: "/", with: ",").replacingOccurrences(of: "=", with: "") + "-"
            pending = []
        }
        for scalar in text.unicodeScalars {
            if scalar.value >= 0x20 && scalar.value <= 0x7E {
                flush()
                result += scalar == "&" ? "&-" : String(scalar)
            } else {
                pending.append(contentsOf: Array(String(scalar).utf16))
            }
        }
        flush()
        return result
    }
}
