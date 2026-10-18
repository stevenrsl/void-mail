import Foundation
import Observation

/// What the window shows: which account, which mailbox, its messages, the one open. The cache
/// answers at once; the server is asked behind it, and the list follows when it has answered.
@MainActor @Observable
final class MailModel {
    static let shared = MailModel()

    var selectedMailbox: String? = "INBOX"
    /// The sheet that adds an account.
    var addingAccount = false

    /// The open mailbox's messages (or the search's), most recent first.
    private(set) var messages: [MessageSummary] = []
    var selectedMessageID: Int64?
    /// The message open, decoded; nil while it loads.
    private(set) var openMessage: MailMessage?
    private(set) var loadingMessage = false
    /// The server is being asked for the open mailbox.
    private(set) var syncing = false
    /// The last thing that went wrong with the server, said plainly.
    var serverError: String?
    /// Images from the Internet allowed for the open message.
    var showsRemoteImages = false

    /// Search, in every mailbox of the account; empty: the open mailbox.
    var query = "" { didSet { if query != oldValue { Task { await reloadList() } } } }

    private let store = AccountStore.shared
    private let settings = AppSettings.shared
    private let cache = MailCache.shared
    @ObservationIgnored private var sessions: [UUID: AccountSession] = [:]
    @ObservationIgnored private var openTask: Task<Void, Never>?

    var currentAccount: MailAccount? {
        store.account(settings.currentAccount.flatMap(UUID.init)) ?? store.accounts.first
    }

    var selectedMessage: MessageSummary? {
        messages.first { $0.id == selectedMessageID }
    }

    var currentMailbox: Mailbox? {
        currentAccount?.mailboxes.first { $0.path == selectedMailbox }
    }

    func select(_ account: MailAccount) {
        settings.currentAccount = account.id.uuidString
        selectMailbox("INBOX")
    }

    func selectMailbox(_ path: String) {
        selectedMailbox = path
        query = ""
        closeMessage()
        messages = []
        Task { await refresh() }
    }

    /// Next or previous account, at the ends going round.
    func cycleAccount(by offset: Int) {
        let accounts = store.accounts
        guard accounts.count > 1, let current = currentAccount, let index = accounts.firstIndex(of: current) else { return }
        select(accounts[(index + offset + accounts.count) % accounts.count])
    }

    /// The cache first, then the server, then the cache again.
    func refresh() async {
        await reloadList()
        guard let account = currentAccount, let mailbox = selectedMailbox, !syncing else { return }
        #if DEBUG
        if DebugLaunch.isRequested { return }
        #endif
        syncing = true
        defer { syncing = false }
        do {
            try await session(for: account).sync(mailbox)
            serverError = nil
        } catch {
            serverError = Self.describe(error)
        }
        await reloadList()
    }

    func reloadList() async {
        guard let account = currentAccount else { messages = []; return }
        let query = self.query.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            guard let mailbox = selectedMailbox else { messages = []; return }
            messages = await cache.messages(account: account.id, mailbox: mailbox)
        } else {
            messages = await cache.search(account: account.id, text: query)
        }
    }

    // MARK: The open message

    func open(_ summary: MessageSummary) {
        guard summary.id != selectedMessageID || openMessage == nil else { return }
        selectedMessageID = summary.id
        openMessage = nil
        showsRemoteImages = false
        loadingMessage = true
        openTask?.cancel()
        openTask = Task {
            defer { if selectedMessageID == summary.id { loadingMessage = false } }
            guard let account = store.account(summary.account) else { return }
            do {
                var raw = await cache.body(message: summary.id)
                if raw == nil {
                    raw = try await session(for: account).body(uid: summary.uid, mailbox: summary.mailbox)
                }
                guard let raw, !Task.isCancelled else { return }
                let message = await Task.detached(priority: .userInitiated) { MailMessage(raw: raw) }.value
                guard selectedMessageID == summary.id else { return }
                openMessage = message
                await cache.storeBody(raw, text: message.searchableText, message: summary.id)
                if !summary.isSeen { setFlag("\\Seen", on: true, for: summary) }
            } catch {
                serverError = Self.describe(error)
            }
        }
    }

    func closeMessage() {
        openTask?.cancel()
        selectedMessageID = nil
        openMessage = nil
        loadingMessage = false
    }

    /// The next (1) or previous (-1) message of the list.
    func move(by offset: Int) {
        guard !messages.isEmpty else { return }
        let index = selectedMessageID.flatMap { id in messages.firstIndex { $0.id == id } }
        let target = index.map { min(max($0 + offset, 0), messages.count - 1) } ?? 0
        open(messages[target])
    }

    func toggleSeen() {
        guard let message = selectedMessage else { return }
        setFlag("\\Seen", on: !message.isSeen, for: message)
    }

    /// At once in the list and the cache, then on the server; put back if the server refuses.
    func setFlag(_ flag: String, on: Bool, for summary: MessageSummary) {
        if let index = messages.firstIndex(where: { $0.id == summary.id }) {
            if on { messages[index].flags.insert(flag) } else { messages[index].flags.remove(flag) }
        }
        Task {
            await cache.setFlag(flag, on: on, message: summary.id)
            #if DEBUG
            if DebugLaunch.isRequested { return }
            #endif
            guard let account = store.account(summary.account) else { return }
            do {
                try await session(for: account).setFlag(flag, on: on, uid: summary.uid, mailbox: summary.mailbox)
            } catch {
                await cache.setFlag(flag, on: !on, message: summary.id)
                serverError = Self.describe(error)
                await reloadList()
            }
        }
    }

    // MARK: Accounts

    func forget(_ account: MailAccount) {
        let session = sessions.removeValue(forKey: account.id)
        Task {
            await session?.close()
            await cache.removeAccount(account.id)
        }
        store.remove(account)
        if settings.currentAccount == account.id.uuidString { settings.currentAccount = nil }
        closeMessage()
        Task { await refresh() }
    }

    private func session(for account: MailAccount) -> AccountSession {
        if let session = sessions[account.id], session.account == account { return session }
        let session = AccountSession(account: account)
        sessions[account.id] = session
        return session
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    #if DEBUG
    /// Sample messages in the cache, for `-demo YES`.
    func loadDemo() async {
        for account in store.accounts {
            await cache.insert(DebugLaunch.demoEnvelopes, account: account.id, mailbox: "INBOX")
            for summary in await cache.messages(account: account.id, mailbox: "INBOX") {
                guard let body = DebugLaunch.demoBodies[summary.uid] else { continue }
                let raw = Data(body.replacingOccurrences(of: "\n", with: "\r\n").utf8)
                await cache.storeBody(raw, text: MailMessage(raw: raw).searchableText, message: summary.id)
            }
        }
        await reloadList()
        // `-openUID 103`: that message open.
        let uid = UserDefaults.standard.integer(forKey: "openUID")
        if let message = messages.first(where: { $0.uid == uid }) { open(message) }
    }
    #endif
}
