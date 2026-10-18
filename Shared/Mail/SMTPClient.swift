import Foundation

/// The beginning of SMTP submission (RFC 6409): greeting, EHLO, STARTTLS, AUTH PLAIN or XOAUTH2,
/// QUIT — enough to check that the account may send. Sending a message comes next.
final class SMTPClient {
    private let stream: MailStream
    private(set) var extensions: Set<String> = []

    var transcript: [String] { stream.transcript }

    private init(stream: MailStream) {
        self.stream = stream
    }

    static func connect(to endpoint: ServerEndpoint) async throws -> SMTPClient {
        let client = SMTPClient(stream: try MailStream(endpoint: endpoint))
        let (code, lines) = try await client.readReply()
        guard code == 220 else { throw MailError.unexpected(lines.last ?? "") }
        try await client.hello()
        if endpoint.security == .startTLS {
            guard client.extensions.contains("STARTTLS") else { throw MailError.unexpected("STARTTLS absent") }
            try await client.expect(220, after: "STARTTLS")
            client.stream.startTLS()
            // Everything learnt before the upgrade is forgotten (RFC 3207).
            try await client.hello()
        }
        return client
    }

    func authenticate(user: String, credential: SASL.Credential) async throws {
        let mechanisms = extensions.first { $0.hasPrefix("AUTH ") }.map { Set($0.dropFirst(5).split(separator: " ").map(String.init)) } ?? []
        let (mechanism, response): (String, String)
        switch credential {
        case .password(let password):
            guard mechanisms.contains("PLAIN") || mechanisms.isEmpty else { throw MailError.noSecureLogin }
            (mechanism, response) = ("PLAIN", SASL.plain(user: user, password: password))
        case .token(let token):
            (mechanism, response) = ("XOAUTH2", SASL.xoauth2(user: user, token: token))
        }
        try await stream.send("AUTH \(mechanism) \(response)", secret: response)
        var (code, lines) = try await readReply()
        if code == 334 {
            // XOAUTH2's error details: an empty answer ends the exchange.
            try await stream.send("")
            (code, lines) = try await readReply()
        }
        guard code == 235 else { throw MailError.authentication(lines.last ?? "") }
    }

    /// Sends a message: MAIL FROM, one RCPT TO per recipient, DATA with its lines starting with a
    /// dot doubled (RFC 5321 §4.5.2). A recipient refused stops everything: nobody gets half a send.
    func send(from: String, to recipients: [String], data: Data) async throws {
        try await expect(250, after: "MAIL FROM:<\(from)>")
        for recipient in recipients {
            try await stream.send("RCPT TO:<\(recipient)>")
            let (code, lines) = try await readReply()
            guard code == 250 || code == 251 else {
                throw MailError.unexpected("\(recipient) refusé : \(lines.last ?? "")")
            }
        }
        try await expect(354, after: "DATA")
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix(".") { text = "." + text }
        text = text.replacingOccurrences(of: "\r\n.", with: "\r\n..")
        if !text.hasSuffix("\r\n") { text += "\r\n" }
        try await stream.sendData(Data((text + ".\r\n").utf8))
        let (code, lines) = try await readReply()
        guard code == 250 else { throw MailError.unexpected(lines.last ?? "") }
    }

    func quit() async {
        try? await stream.send("QUIT")
        _ = try? await readReply()
        stream.close()
    }

    // MARK: Replies

    private func hello() async throws {
        try await stream.send("EHLO \(Self.clientName)")
        let (code, lines) = try await readReply()
        guard code == 250 else { throw MailError.unexpected(lines.last ?? "") }
        extensions = Set(lines.dropFirst().map { $0.uppercased() })
    }

    private func expect(_ expected: Int, after command: String) async throws {
        try await stream.send(command)
        let (code, lines) = try await readReply()
        guard code == expected else { throw MailError.unexpected(lines.last ?? "") }
    }

    /// A reply, its lines without their codes: `250-a`, `250-b`, `250 c` → (250, [a, b, c]).
    private func readReply() async throws -> (Int, [String]) {
        var lines: [String] = []
        while true {
            let line = try await stream.readLine()
            guard line.count >= 3, let code = Int(line.prefix(3)) else { throw MailError.unexpected(line) }
            lines.append(String(line.dropFirst(4)))
            if line.count == 3 || line[line.index(line.startIndex, offsetBy: 3)] == " " { return (code, lines) }
        }
    }

    /// The name given in EHLO: nothing that tells who or where (RFC 5321 allows an address literal).
    static let clientName = "[127.0.0.1]"
}
