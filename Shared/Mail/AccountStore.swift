import Foundation
import Observation

/// The accounts, in `accounts.json` next to the cache (servers, sign-in method, mailboxes found;
/// no password, no token: those are in the keychain). Written whole, atomically, at each change.
@MainActor @Observable
final class AccountStore {
    static let shared = AccountStore()

    private(set) var accounts: [MailAccount] = []
    var errorMessage: String?

    @ObservationIgnored let directory: URL?

    private init() {
        #if DEBUG
        if DebugLaunch.isRequested {
            directory = nil
            accounts = DebugLaunch.demoAccounts
            return
        }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        directory = support?.appendingPathComponent("Void Mail", isDirectory: true)
        load()
    }

    private var fileURL: URL? { directory?.appendingPathComponent("accounts.json") }

    func account(_ id: UUID?) -> MailAccount? {
        accounts.first { $0.id == id }
    }

    /// Adds the account, or replaces the one with its identifier.
    func save(_ account: MailAccount) {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        write()
    }

    func remove(_ account: MailAccount) {
        accounts.removeAll { $0.id == account.id }
        Keychain.delete(for: account.id)
        write()
    }

    // MARK: Disk

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        do {
            accounts = try Self.decoder.decode([MailAccount].self, from: data)
        } catch {
            // Never written over: put aside, the list starts empty, and the window says so.
            let aside = fileURL.deletingLastPathComponent().appendingPathComponent("accounts.unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            errorMessage = "La liste des comptes était illisible ; elle a été mise de côté (\(aside.lastPathComponent))."
        }
    }

    private func write() {
        guard let directory, let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.encoder.encode(accounts).write(to: fileURL, options: .atomic)
        } catch {
            errorMessage = "Les comptes n'ont pas pu être enregistrés : \(error.localizedDescription)"
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Adding an account: both servers reached and signed in to, the mailboxes listed. Nothing is
/// kept if a step fails, and the step says what went wrong.
@MainActor
enum AccountCheck {
    enum Step: Equatable {
        case signingIn, imap, smtp, done
        var label: String {
            switch self {
            case .signingIn: "Connexion au fournisseur…"
            case .imap: "Réception (IMAP)…"
            case .smtp: "Envoi (SMTP)…"
            case .done: "Compte prêt"
            }
        }
    }

    /// Checks the account with its credential already in the keychain; returns it with its mailboxes.
    static func run(_ account: MailAccount, progress: (Step) -> Void) async throws -> MailAccount {
        var account = account
        if case .oauth(let provider) = account.auth, Keychain.read(for: account.id, kind: .oauth) == nil {
            progress(.signingIn)
            try await OAuthClient.signIn(provider, address: account.address, account: account.id)
        }
        let credential = try await SASL.credential(for: account)

        progress(.imap)
        let imap = try await IMAPClient.connect(to: account.imap)
        try await imap.authenticate(user: account.username, credential: credential)
        account.mailboxes = try await imap.listMailboxes()
        await imap.logout()

        progress(.smtp)
        let smtp = try await SMTPClient.connect(to: account.smtp)
        try await smtp.authenticate(user: account.username, credential: credential)
        await smtp.quit()

        progress(.done)
        return account
    }
}
