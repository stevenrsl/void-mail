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
    /// Messages and unread messages of the current account's mailboxes, by path.
    private(set) var counts: [String: IMAPClient.Count] = [:]
    /// Images from the Internet allowed for the open message.
    var showsRemoteImages = false

    /// Search, in every mailbox of the account; empty: the open mailbox.
    var query = "" { didSet { if query != oldValue { Task { await reloadList() } } } }

    private let store = AccountStore.shared
    private let settings = AppSettings.shared
    private let cache = MailCache.shared
    @ObservationIgnored private var sessions: [UUID: AccountSession] = [:]
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var watchers: [UUID: InboxWatcher] = [:]

    /// A gesture (archive, trash) shown done but not yet sent to the server, the time to undo it.
    struct PendingGesture: Identifiable {
        enum Kind: Equatable {
            case move(to: String)
            case delete
        }

        let id = UUID()
        let kind: Kind
        let messages: [MessageSummary]
        /// « Archivé », « Mis à la corbeille »…
        let label: String
        /// The counts before, put back if it is undone.
        let countsBefore: [String: IMAPClient.Count]
    }

    private(set) var pending: PendingGesture?
    /// A message of the trash, waiting for « Supprimer définitivement ».
    var confirmingDeletion: MessageSummary?
    /// Messages moved away whose move hasn't reached the server yet: out of the list meanwhile.
    @ObservationIgnored private var hidden: Set<Int64> = []
    @ObservationIgnored private var pendingTimer: Task<Void, Never>?
    static let undoDelay: Duration = .seconds(5)

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
        if settings.currentAccount != account.id.uuidString { counts = [:] }
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
        await refreshCounts(account)
    }

    /// The counts of every mailbox of the account, after its open mailbox is up to date.
    private func refreshCounts(_ account: MailAccount) async {
        #if DEBUG
        if DebugLaunch.isRequested { return }
        #endif
        let paths = account.mailboxes.filter(\.isSelectable).map(\.path)
        guard let counts = try? await session(for: account).counts(paths), currentAccount?.id == account.id else { return }
        self.counts = counts
    }

    func reloadList() async {
        guard let account = currentAccount else { messages = []; return }
        let query = self.query.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            guard let mailbox = selectedMailbox else { messages = []; return }
            messages = await cache.messages(account: account.id, mailbox: mailbox).filter { !hidden.contains($0.id) }
        } else {
            messages = await cache.search(account: account.id, text: query).filter { !hidden.contains($0.id) }
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
                #if DEBUG
                // Demo messages without a body stay blank: there is no server to ask.
                if raw == nil, DebugLaunch.isRequested { return }
                #endif
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

    /// U: the message given (a row's button) or the open one.
    func toggleSeen(_ given: MessageSummary? = nil) {
        guard let message = given ?? selectedMessage else { return }
        setFlag("\\Seen", on: !message.isSeen, for: message)
    }

    /// At once in the list and the cache, then on the server; put back if the server refuses.
    func setFlag(_ flag: String, on: Bool, for summary: MessageSummary) {
        if let index = messages.firstIndex(where: { $0.id == summary.id }) {
            let had = messages[index].flags.contains(flag)
            if on { messages[index].flags.insert(flag) } else { messages[index].flags.remove(flag) }
            // The unread count follows at once, before the next STATUS.
            if flag == "\\Seen", had != on, var count = counts[summary.mailbox] {
                count.unseen = max(0, count.unseen + (on ? -1 : 1))
                counts[summary.mailbox] = count
            }
        }
        Task {
            await cache.setFlag(flag, on: on, message: summary.id)
            // A pinned message goes to the top of the list, an unpinned one back to its date.
            if flag == "\\Flagged" { await reloadList() }
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

    func togglePinned(_ given: MessageSummary? = nil) {
        guard let message = given ?? selectedMessage else { return }
        setFlag("\\Flagged", on: !message.isFlagged, for: message)
    }

    // MARK: Gestures

    func archivePath(of account: MailAccount) -> String? { account.mailboxes.first { $0.role == .archive }?.path }
    func trashPath(of account: MailAccount) -> String? { account.mailboxes.first { $0.role == .trash }?.path }

    /// E: to the Archives; from the Archives, back to the Inbox.
    func archiveSelected(_ given: MessageSummary? = nil) {
        guard let message = given ?? selectedMessage, let account = store.account(message.account) else { return }
        guard let archive = archivePath(of: account) else { serverError = "Ce compte n'a pas de boîte Archives."; return }
        if message.mailbox == archive {
            perform(.move(to: "INBOX"), on: message, label: "Remis en Réception")
        } else {
            perform(.move(to: archive), on: message, label: "Archivé")
        }
    }

    /// ⌫: to the trash; in the trash (or without one), deleted for good after confirmation.
    func trashSelected(_ given: MessageSummary? = nil) {
        guard let message = given ?? selectedMessage, let account = store.account(message.account) else { return }
        if let trash = trashPath(of: account), message.mailbox != trash {
            perform(.move(to: trash), on: message, label: "Mis à la corbeille")
        } else {
            confirmingDeletion = message
        }
    }

    /// Any mailbox of the account but the one the message is in, for « Déplacer vers ».
    func destinations(for message: MessageSummary) -> [Mailbox] {
        store.account(message.account)?.sortedMailboxes.filter { $0.isSelectable && $0.path != message.mailbox && $0.role != .all } ?? []
    }

    func move(_ message: MessageSummary, to mailbox: Mailbox) {
        perform(.move(to: mailbox.path), on: message, label: "Déplacé vers « \(mailbox.displayName) »")
    }

    func deleteForGood(_ message: MessageSummary) {
        confirmingDeletion = nil
        perform(.delete, on: message, label: "Supprimé", undoable: false)
    }

    /// Done at once in the window — the message leaves the list, the next one opens — and sent
    /// to the server a few seconds later, unless undone meanwhile.
    private func perform(_ kind: PendingGesture.Kind, on message: MessageSummary, label: String, undoable: Bool = true) {
        commitPending()
        let index = messages.firstIndex { $0.id == message.id }
        let next = index.flatMap { $0 + 1 < messages.count ? messages[$0 + 1] : ($0 > 0 ? messages[$0 - 1] : nil) }
        let gesture = PendingGesture(kind: kind, messages: [message], label: label, countsBefore: counts)
        hidden.insert(message.id)
        messages.removeAll { $0.id == message.id }
        adjustCounts(for: message, kind: kind)
        // The open message gone: the next one opens. Another one (a row's button): the open one stays.
        if message.id == selectedMessageID {
            if let next { open(next) } else { closeMessage() }
        }
        if undoable {
            pending = gesture
            pendingTimer = Task {
                try? await Task.sleep(for: Self.undoDelay)
                guard !Task.isCancelled else { return }
                await commit(gesture)
            }
        } else {
            Task { await commit(gesture) }
        }
    }

    private func adjustCounts(for message: MessageSummary, kind: PendingGesture.Kind) {
        let unseen = message.isSeen ? 0 : 1
        if var count = counts[message.mailbox] {
            count.messages = max(0, count.messages - 1)
            count.unseen = max(0, count.unseen - unseen)
            counts[message.mailbox] = count
        }
        if case .move(let destination) = kind, var count = counts[destination] {
            count.messages += 1
            count.unseen += unseen
            counts[destination] = count
        }
    }

    /// ⌘Z, or « Annuler » in the band: the message comes back, open.
    func undo() {
        guard let gesture = pending else { return }
        pendingTimer?.cancel()
        pending = nil
        counts = gesture.countsBefore
        for message in gesture.messages { hidden.remove(message.id) }
        Task {
            await reloadList()
            if let first = gesture.messages.first, let restored = messages.first(where: { $0.id == first.id }) { open(restored) }
        }
    }

    /// The gesture waiting goes now (another gesture, a quit).
    func commitPending() {
        guard let gesture = pending else { return }
        pendingTimer?.cancel()
        pending = nil
        Task { await commit(gesture) }
    }

    func commitPendingNow() async {
        guard let gesture = pending else { return }
        pendingTimer?.cancel()
        pending = nil
        await commit(gesture)
    }

    private func commit(_ gesture: PendingGesture) async {
        if pending?.id == gesture.id { pending = nil }
        guard let first = gesture.messages.first, let account = store.account(first.account) else { return }
        let uids = gesture.messages.map(\.uid)
        let ids = Set(gesture.messages.map(\.id))
        do {
            #if DEBUG
            let offline = DebugLaunch.isRequested
            #else
            let offline = false
            #endif
            if !offline {
                switch gesture.kind {
                case .move(let destination): try await session(for: account).move(uids: uids, from: first.mailbox, to: destination)
                case .delete: try await session(for: account).delete(uids: uids, from: first.mailbox)
                }
            }
            await cache.removeMessages(account: account.id, mailbox: first.mailbox, uids: Set(uids))
            hidden.subtract(ids)
        } catch {
            // Refused: the message comes back where it was.
            hidden.subtract(ids)
            serverError = "« \(gesture.label) » n'a pas abouti : \(Self.describe(error))"
            await reloadList()
        }
        await refreshCounts(account)
    }

    // MARK: New mail

    /// One watcher per account on its Inbox (IDLE); started at launch and when accounts change.
    func watchInboxes() {
        #if DEBUG
        if DebugLaunch.isRequested { return }
        #endif
        let accounts = store.accounts
        for (id, watcher) in watchers where accounts.first(where: { $0.id == id }) != watcher.account {
            Task { await watcher.stop() }
            watchers[id] = nil
        }
        for account in accounts where watchers[account.id] == nil {
            let id = account.id
            let watcher = InboxWatcher(account: account) { await MailModel.shared.inboxChanged(id) }
            watchers[id] = watcher
            Task { await watcher.start() }
        }
    }

    /// Something changed in an account's Inbox: the list if it is the one shown, the counts anyway.
    func inboxChanged(_ id: UUID) async {
        guard let account = currentAccount, account.id == id else { return }
        if selectedMailbox == "INBOX", query.isEmpty {
            await refresh()
        } else {
            await refreshCounts(account)
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
        watchInboxes()
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
        counts = ["INBOX": .init(messages: 1_284, unseen: 2), "Archive": .init(messages: 3_410, unseen: 0), "Junk": .init(messages: 14, unseen: 3),
                  "Factures": .init(messages: 52, unseen: 1)]
        // `-openUID 103`: that message open.
        let uid = UserDefaults.standard.integer(forKey: "openUID")
        if let message = messages.first(where: { $0.uid == uid }) { open(message) }
        // `-gesture archive` (or `trash`, `pin`): that gesture on the open message, for the snapshots.
        switch UserDefaults.standard.string(forKey: "gesture") {
        case "archive": archiveSelected()
        case "trash": trashSelected()
        case "pin": togglePinned()
        default: break
        }
    }
    #endif
}
