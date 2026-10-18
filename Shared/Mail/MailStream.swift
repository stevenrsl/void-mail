import Foundation

/// A line-oriented connection to a mail server, for IMAP and SMTP alike. Foundation's stream
/// task rather than Network.framework: it can upgrade a connection already open to TLS
/// (`startSecureConnection`), which STARTTLS needs — iCloud's and Microsoft's SMTP offer nothing
/// else — and it checks the server's certificate as every URLSession does.
final class MailStream {
    private let task: URLSessionStreamTask
    private var buffer = Data()
    private let timeout: TimeInterval
    /// How long a read waits: longer while IDLE waits for the server to speak.
    var readTimeout: TimeInterval
    private(set) var isSecure = false
    /// What was said, for the account's check (passwords and tokens never: see `send(_:secret:)`).
    private(set) var transcript: [String] = []

    init(endpoint: ServerEndpoint, timeout: TimeInterval = 20) throws {
        guard endpoint.isAllowed else { throw MailError.insecure }
        guard !endpoint.host.isEmpty, (1...65535).contains(endpoint.port) else { throw MailError.badServer }
        self.timeout = timeout
        readTimeout = timeout
        task = LocalBridgeTrust.session.streamTask(withHostName: endpoint.host, port: endpoint.port)
        task.resume()
        if endpoint.security == .tls { startTLS() }
    }

    deinit { task.cancel() }

    func startTLS() {
        task.startSecureConnection()
        isSecure = true
    }

    func close() {
        task.closeWrite()
        task.cancel()
    }

    /// One line, without its CRLF.
    func readLine() async throws -> String {
        String(decoding: try await readLineData(), as: UTF8.self)
    }

    /// One line as it came, without its CRLF: message headers and bodies aren't always UTF-8.
    func readLineData() async throws -> Data {
        while true {
            if let range = buffer.firstRange(of: Data([0x0D, 0x0A])) {
                let line = Data(buffer[buffer.startIndex..<range.lowerBound])
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                log("S: " + String(decoding: line.prefix(200), as: UTF8.self))
                return line
            }
            try await fill()
        }
    }

    /// The transcript keeps the beginning of each line, and the last lines only: a long session
    /// fetches whole messages.
    private func log(_ line: String) {
        transcript.append(line)
        if transcript.count > 400 { transcript.removeFirst(transcript.count - 300) }
    }

    /// Exactly `count` bytes (an IMAP literal).
    func read(count: Int) async throws -> Data {
        while buffer.count < count { try await fill() }
        let data = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(data)
    }

    /// Sends a line; with `secret`, what is logged stops at it.
    func send(_ line: String, secret: String? = nil) async throws {
        log("C: " + (secret.map { line.replacingOccurrences(of: $0, with: "•••") } ?? line))
        do {
            try await task.write(Data((line + "\r\n").utf8), timeout: timeout)
        } catch {
            throw MailError.connection(error)
        }
    }

    /// Writes raw bytes (a message's DATA, an APPEND literal), logged as their size only.
    func sendData(_ data: Data) async throws {
        log("C: <\(data.count) octets>")
        do {
            try await task.write(data, timeout: max(timeout, Double(data.count) / 50_000))
        } catch {
            throw MailError.connection(error)
        }
    }

    /// Writes a line without logging it: what ends IDLE, sent while a read waits.
    func sendQuietly(_ line: String) async throws {
        do {
            try await task.write(Data((line + "\r\n").utf8), timeout: timeout)
        } catch {
            throw MailError.connection(error)
        }
    }

    private func fill() async throws {
        let data: Data?, atEOF: Bool
        do {
            (data, atEOF) = try await task.readData(ofMinLength: 1, maxLength: 64 * 1024, timeout: readTimeout)
        } catch {
            throw MailError.connection(error)
        }
        if let data, !data.isEmpty { buffer.append(data); return }
        if atEOF { throw MailError.closed }
    }
}

/// The session of every mail connection: the system's certificate checks, except for a server on
/// this Mac itself — Proton Mail Bridge secures its connections with a certificate it made, that
/// no authority signed. Accepting it there is no weaker than a clear connection to this Mac,
/// which is allowed: nothing of it leaves the machine.
final class LocalBridgeTrust: NSObject, URLSessionTaskDelegate {
    static let session = URLSession(configuration: .ephemeral, delegate: LocalBridgeTrust(), delegateQueue: nil)
    static let localHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        decide(challenge, completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        decide(challenge, completionHandler)
    }

    private func decide(_ challenge: URLAuthenticationChallenge, _ completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust, Self.localHosts.contains(space.host.lowercased()),
           let trust = space.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

enum MailError: LocalizedError {
    case insecure
    case badServer
    case connection(Error)
    case closed
    case unexpected(String)
    case authentication(String)
    case noSecureLogin

    var errorDescription: String? {
        switch self {
        case .insecure: "Une connexion sans chiffrement n'est permise que vers ce Mac."
        case .badServer: "L'adresse ou le port du serveur est incomplet."
        case .connection(let error): Self.describe(error)
        case .closed: "Le serveur a fermé la connexion."
        case .unexpected(let line): "Réponse inattendue du serveur : « \(line.prefix(160)) »"
        case .authentication(let line):
            "Adresse ou mot de passe refusé par le serveur." + (line.isEmpty ? "" : " (« \(line.prefix(160)) »)")
        case .noSecureLogin: "Le serveur ne propose aucune façon de se connecter que Void Mail connaisse."
        }
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        switch (nsError.domain, nsError.code) {
        case (NSURLErrorDomain, NSURLErrorTimedOut): return "Le serveur ne répond pas."
        case (NSURLErrorDomain, NSURLErrorCannotFindHost), (NSURLErrorDomain, NSURLErrorDNSLookupFailed): return "Serveur introuvable : vérifiez son adresse."
        case (NSURLErrorDomain, NSURLErrorCannotConnectToHost): return "Connexion refusée : vérifiez le port et le chiffrement."
        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet): return "Pas de connexion à Internet."
        case (NSURLErrorDomain, NSURLErrorSecureConnectionFailed), (NSURLErrorDomain, NSURLErrorServerCertificateUntrusted),
             (NSURLErrorDomain, NSURLErrorServerCertificateHasBadDate), (NSURLErrorDomain, NSURLErrorServerCertificateHasUnknownRoot):
            return "La connexion sécurisée a échoué (certificat du serveur ou chiffrement choisi)."
        case (NSPOSIXErrorDomain, Int(ETIMEDOUT)): return "Le serveur ne répond pas : vérifiez le port et le chiffrement."
        case (NSPOSIXErrorDomain, Int(ECONNREFUSED)): return "Connexion refusée : vérifiez le port et le chiffrement."
        default: return nsError.localizedDescription
        }
    }
}

/// The SASL mechanisms Void Mail speaks: PLAIN for a password, XOAUTH2 for a token — the same
/// strings for IMAP and SMTP.
enum SASL {
    enum Credential {
        case password(String)
        case token(String)
    }

    static func plain(user: String, password: String) -> String {
        Data("\0\(user)\0\(password)".utf8).base64EncodedString()
    }

    static func xoauth2(user: String, token: String) -> String {
        Data("user=\(user)\u{1}auth=Bearer \(token)\u{1}\u{1}".utf8).base64EncodedString()
    }

    /// The account's credential, from the keychain; an OAuth token refreshed if need be.
    @MainActor
    static func credential(for account: MailAccount) async throws -> Credential {
        switch account.auth {
        case .password:
            guard let password = Keychain.password(for: account.id) else { throw MailError.authentication("") }
            return .password(password)
        case .oauth(let provider):
            return .token(try await OAuthClient.accessToken(provider, account: account.id))
        }
    }
}
