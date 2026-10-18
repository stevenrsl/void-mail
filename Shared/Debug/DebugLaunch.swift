#if DEBUG
import Foundation

/// Debug builds only. Launch arguments that never touch the real accounts or preferences:
/// `-selfTest YES` runs the checks and quits, `-demo YES` shows sample accounts kept in memory.
/// `-snapshot YES` prints a picture of the window and quits. `-theme`, `-accent` and
/// `-tint` choose the look.
enum DebugLaunch {
    static var isDemo: Bool { UserDefaults.standard.bool(forKey: "demo") }
    static var isSelfTest: Bool { UserDefaults.standard.bool(forKey: "selfTest") }
    static var isRequested: Bool { isDemo || isSelfTest || UserDefaults.standard.bool(forKey: "snapshot") }

    /// Two accounts, as if added and checked: their mailboxes show in the sidebar.
    static var demoAccounts: [MailAccount] {
        guard isDemo else { return [] }
        var personal = MailAccount(name: "Steven", address: "steven@icloud.com", preset: ProviderDirectory.preset(for: "steven@icloud.com"))
        personal.mailboxes = ["INBOX", "Archive", "Sent Messages", "Drafts", "Deleted Messages", "Junk", "Factures", "Voyages", "Voyages/Portugal"]
            .map { Mailbox(path: $0, delimiter: "/", attributes: Mailbox.guessedAttributes(for: $0)) }
        var work = MailAccount(name: "Studio", address: "hello@studio.test", preset: ProviderDirectory.preset(for: "hello@studio.test"))
        work.mailboxes = ["INBOX", "Archives", "Sent", "Drafts", "Trash"]
            .map { Mailbox(path: $0, delimiter: ".", attributes: Mailbox.guessedAttributes(for: $0)) }
        return [personal, work]
    }
}
#endif
