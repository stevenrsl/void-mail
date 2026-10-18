import Foundation
import Observation

/// What the window shows: which account, which mailbox. The account comes back at launch.
@MainActor @Observable
final class MailModel {
    static let shared = MailModel()

    var selectedMailbox: String? = "INBOX"
    /// The sheet that adds an account (or reconnects one, when it carries it).
    var addingAccount = false

    private let store = AccountStore.shared
    private let settings = AppSettings.shared

    var currentAccount: MailAccount? {
        store.account(settings.currentAccount.flatMap(UUID.init)) ?? store.accounts.first
    }

    func select(_ account: MailAccount) {
        settings.currentAccount = account.id.uuidString
        selectedMailbox = "INBOX"
    }

    /// Next or previous account, at the ends going round.
    func cycleAccount(by offset: Int) {
        let accounts = store.accounts
        guard accounts.count > 1, let current = currentAccount, let index = accounts.firstIndex(of: current) else { return }
        select(accounts[(index + offset + accounts.count) % accounts.count])
    }
}
