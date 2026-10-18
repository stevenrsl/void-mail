import Foundation

/// How a connection is secured. Implicit TLS from the first byte (IMAP 993, SMTP 465), or a plain
/// connection upgraded by STARTTLS (IMAP 143, SMTP 587). Never in clear, except to this Mac
/// itself (Proton Mail Bridge listens on 127.0.0.1 and secures nothing).
enum ConnectionSecurity: String, Codable, CaseIterable, Identifiable {
    case tls, startTLS, none
    var id: String { rawValue }

    var label: String {
        switch self {
        case .tls: "TLS"
        case .startTLS: "STARTTLS"
        case .none: "Aucune (ce Mac seulement)"
        }
    }
}

struct ServerEndpoint: Codable, Hashable {
    var host: String
    var port: Int
    var security: ConnectionSecurity

    /// A clear connection is only allowed to this Mac.
    var isAllowed: Bool {
        security != .none || LocalBridgeTrust.localHosts.contains(host.lowercased())
    }
}

/// How an account proves who it is to its servers. The password or the OAuth tokens themselves
/// are never here: they are in the keychain (`Keychain`), under the account's identifier.
enum MailAuth: Codable, Hashable {
    /// An app password (or the account's own, where the host still allows it): SASL PLAIN.
    case password
    /// A token from the provider's sign-in page, refreshed as needed: SASL XOAUTH2.
    case oauth(OAuthProvider)

    var label: String {
        switch self {
        case .password: "Mot de passe d'application"
        case .oauth(let provider): "Connexion \(provider.label)"
        }
    }
}

/// A mailbox on the IMAP server, as LIST gives it: its full path (modified UTF-7 decoded), the
/// delimiter of its hierarchy, and its attributes — the special-use ones (RFC 6154) say which is
/// the archive, the sent messages, the drafts, the trash.
struct Mailbox: Codable, Hashable, Identifiable {
    var path: String
    var delimiter: String?
    var attributes: Set<String>

    var id: String { path }

    enum Role: Int, Codable, CaseIterable, Comparable {
        case inbox, archive, sent, drafts, junk, trash, all, other

        static func < (a: Role, b: Role) -> Bool { a.rawValue < b.rawValue }

        var label: String {
            switch self {
            case .inbox: "Réception"
            case .archive: "Archives"
            case .sent: "Envoyés"
            case .drafts: "Brouillons"
            case .junk: "Indésirables"
            case .trash: "Corbeille"
            case .all: "Tous les messages"
            case .other: ""
            }
        }

        var symbol: String {
            switch self {
            case .inbox: "tray"
            case .archive: "archivebox"
            case .sent: "paperplane"
            case .drafts: "doc"
            case .junk: "xmark.bin"
            case .trash: "trash"
            case .all: "tray.full"
            case .other: "folder"
            }
        }
    }

    var role: Role {
        if path.uppercased() == "INBOX" { return .inbox }
        let lowered = Set(attributes.map { $0.lowercased() })
        if lowered.contains("\\archive") { return .archive }
        // Every message of the account (Gmail's and Proton's « All Mail »): not the archive.
        if lowered.contains("\\all") { return .all }
        if lowered.contains("\\sent") { return .sent }
        if lowered.contains("\\drafts") { return .drafts }
        if lowered.contains("\\junk") { return .junk }
        if lowered.contains("\\trash") { return .trash }
        return .other
    }

    /// Can't be opened (a level of the hierarchy only).
    var isSelectable: Bool {
        !attributes.contains { ["\\noselect", "\\nonexistent"].contains($0.lowercased()) }
    }

    /// The last part of the path, what the sidebar shows for a mailbox of no special role.
    var name: String {
        guard let delimiter, !delimiter.isEmpty else { return path }
        return path.components(separatedBy: delimiter).last ?? path
    }

    /// How deep in the hierarchy (0 at the top).
    var depth: Int {
        guard let delimiter, !delimiter.isEmpty else { return 0 }
        return path.components(separatedBy: delimiter).count - 1
    }

    var displayName: String {
        guard role == .other else { return role.label }
        // Proton Mail Bridge puts folders and labels under two parents of its own, in English.
        if depth == 0 { return ["folders": "Dossiers", "labels": "Libellés"][path.lowercased()] ?? name }
        return name
    }

    /// Servers without SPECIAL-USE (older hosts): the role guessed from the usual names.
    static func guessedAttributes(for path: String) -> Set<String> {
        switch path.lowercased() {
        case "archive", "archives": ["\\Archive"]
        case "all mail", "[gmail]/all mail", "tous les messages": ["\\All"]
        case "sent", "sent messages", "sent items", "envoyés", "éléments envoyés", "[gmail]/sent mail": ["\\Sent"]
        case "drafts", "brouillons", "[gmail]/drafts": ["\\Drafts"]
        case "junk", "spam", "junk e-mail", "courrier indésirable", "[gmail]/spam": ["\\Junk"]
        case "trash", "deleted messages", "deleted items", "corbeille", "éléments supprimés", "[gmail]/trash", "[gmail]/bin": ["\\Trash"]
        default: []
        }
    }
}

/// An account: who, which servers, how to sign in, and the mailboxes found at the last check.
struct MailAccount: Codable, Identifiable, Hashable {
    var id = UUID()
    /// The name the messages are sent under.
    var name: String
    var address: String
    /// The user name for the servers: the address almost everywhere.
    var username: String
    var imap: ServerEndpoint
    var smtp: ServerEndpoint
    var auth: MailAuth
    var mailboxes: [Mailbox] = []
    var created = Date()
    /// Written in Markdown (`**gras**`, `[lien](https://…)`), added under new messages and
    /// replies. Optional: files of before the signatures read as they are.
    var signature: String?

    /// The signature in the editor's format; nil when there is none.
    var signatureContent: NoteContent? {
        guard let signature, !signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return NoteMarkdown.content(fromMarkdown: signature.trimmingCharacters(in: .newlines))
    }

    init(name: String, address: String, preset: ProviderPreset) {
        self.name = name
        self.address = address
        self.username = address
        self.imap = preset.imap
        self.smtp = preset.smtp
        self.auth = preset.preferredAuth
    }

    /// The sidebar's order: the special mailboxes first, in their usual order, then the others
    /// as the server lists them (parents before their children).
    var sortedMailboxes: [Mailbox] {
        let special = Dictionary(mailboxes.filter { $0.role != .other }.map { ($0.role, $0) }, uniquingKeysWith: { first, _ in first })
        let firsts = Mailbox.Role.allCases.compactMap { special[$0] }
        let taken = Set(firsts.map(\.path))
        let others = mailboxes.filter { !taken.contains($0.path) && $0.role != .inbox }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return firsts + others
    }
}
