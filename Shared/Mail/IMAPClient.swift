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

    func logout() async {
        _ = try? await command("LOGOUT")
        stream.close()
    }

    // MARK: Commands

    private func refreshCapabilities() async throws {
        let lines = try await command("CAPABILITY")
        capabilities = lines.reduce(into: []) { $0.formUnion(Self.capabilities(in: $1)) }
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

    /// Sends a tagged command; returns the untagged lines (literals spliced in, quoted), throws
    /// on NO or BAD.
    @discardableResult
    private func command(_ text: String, secret: String? = nil) async throws -> [String] {
        tag += 1
        let label = "v\(tag)"
        try await stream.send("\(label) \(text)", secret: secret)
        var lines: [String] = []
        while true {
            let line = try await readResponseLine()
            if line.hasPrefix(label + " ") {
                let status = line.dropFirst(label.count + 1)
                guard status.hasPrefix("OK") else { throw MailError.unexpected(String(status)) }
                return lines
            }
            if line.hasPrefix("* ") { lines.append(line) }
        }
    }

    /// A response line, with any `{n}` literal read and put back in as a quoted string.
    private func readResponseLine() async throws -> String {
        var line = try await stream.readLine()
        while let match = line.range(of: #"\{(\d+)\+?\}$"#, options: .regularExpression) {
            let count = Int(line[match].filter(\.isNumber)) ?? 0
            let literal = String(decoding: try await stream.read(count: count), as: UTF8.self)
            line = String(line[..<match.lowerBound]) + Self.quoted(literal) + (try await stream.readLine())
        }
        return line
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
    static func parseList(_ line: String) -> Mailbox? {
        guard line.hasPrefix("* LIST ") || line.hasPrefix("* XLIST ") else { return nil }
        var scanner = Substring(line.drop { $0 != "(" })
        guard scanner.first == "(", let close = scanner.firstIndex(of: ")") else { return nil }
        let attributes = Set(scanner[scanner.index(after: scanner.startIndex)..<close].split(separator: " ").map(String.init))
        scanner = scanner[scanner.index(after: close)...].drop { $0 == " " }
        guard let delimiter = readAString(&scanner) else { return nil }
        scanner = scanner.drop { $0 == " " }
        guard let name = readAString(&scanner) else { return nil }
        return Mailbox(path: ModifiedUTF7.decode(name), delimiter: delimiter == "NIL" ? nil : delimiter, attributes: attributes)
    }

    /// A quoted string (with `\"` and `\\`), NIL, or an atom.
    private static func readAString(_ scanner: inout Substring) -> String? {
        guard let first = scanner.first else { return nil }
        if first == "\"" {
            var result = ""
            var index = scanner.index(after: scanner.startIndex)
            while index < scanner.endIndex {
                let character = scanner[index]
                if character == "\\" {
                    index = scanner.index(after: index)
                    guard index < scanner.endIndex else { return nil }
                    result.append(scanner[index])
                } else if character == "\"" {
                    scanner = scanner[scanner.index(after: index)...]
                    return result
                } else {
                    result.append(character)
                }
                index = scanner.index(after: index)
            }
            return nil
        }
        let atom = scanner.prefix { $0 != " " }
        scanner = scanner[atom.endIndex...]
        return String(atom)
    }

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
