import Foundation

/// One IMAP connection per account, kept open while the app is, and used one command at a
/// time. A connection that dropped (sleep, network change, server timeout) is opened again,
/// once, before giving up.
actor AccountSession {
    let account: MailAccount
    private let cache: MailCache
    private var client: IMAPClient?
    private var selected: String?

    /// The first visit of a mailbox brings its latest messages; older ones come later.
    static let firstFetch = 300

    init(account: MailAccount, cache: MailCache = .shared) {
        self.account = account
        self.cache = cache
    }

    /// Brings the cache up to date with the mailbox: new messages, changed flags, messages gone.
    func sync(_ mailbox: String) async throws {
        try await withConnection { client in
            let selection = try await self.open(mailbox, client)
            await self.cache.checkValidity(account: self.account.id, mailbox: mailbox, validity: selection.uidValidity)
            let highest = await self.cache.highestUID(account: self.account.id, mailbox: mailbox)
            let envelopes: [MessageEnvelope]
            if let highest {
                envelopes = try await client.fetchEnvelopes(uidsFrom: highest + 1)
            } else {
                envelopes = try await client.fetchLatestEnvelopes(count: Self.firstFetch, exists: selection.exists)
            }
            await self.cache.insert(envelopes, account: self.account.id, mailbox: mailbox)
            // Flags of what was already known, and what is no longer on the server.
            if let highest, let lowest = await self.cache.lowestUID(account: self.account.id, mailbox: mailbox) {
                let flags = try await client.fetchFlags(uidsFrom: lowest)
                let known = await self.cache.uids(account: self.account.id, mailbox: mailbox)
                let gone = known.filter { $0 <= highest && flags[$0] == nil }
                await self.cache.removeMessages(account: self.account.id, mailbox: mailbox, uids: gone)
                await self.cache.updateFlags(flags.filter { known.contains($0.key) }, account: self.account.id, mailbox: mailbox)
            }
        }
    }

    /// The `count` messages before the oldest one known, into the cache; how many came (0: the
    /// beginning of the mailbox is reached).
    func fetchOlder(_ mailbox: String, count: Int = 200) async throws -> Int {
        try await withConnection { client in
            let selection = try await self.open(mailbox, client)
            await self.cache.checkValidity(account: self.account.id, mailbox: mailbox, validity: selection.uidValidity)
            guard let lowest = await self.cache.lowestUID(account: self.account.id, mailbox: mailbox) else { return 0 }
            let older = try await client.uids(below: lowest).suffix(count)
            let envelopes = try await client.fetchEnvelopes(uids: Array(older))
            await self.cache.insert(envelopes, account: self.account.id, mailbox: mailbox)
            return envelopes.count
        }
    }

    /// A message's raw bytes, from the server (the caller keeps them in the cache).
    func body(uid: Int, mailbox: String) async throws -> Data? {
        try await withConnection { client in
            _ = try await self.open(mailbox, client)
            return try await client.fetchBody(uid: uid)
        }
    }

    func setFlag(_ flag: String, on: Bool, uid: Int, mailbox: String) async throws {
        try await withConnection { client in
            _ = try await self.open(mailbox, client)
            try await client.store(uid: uid, flag: flag, on: on)
        }
    }

    func move(uids: [Int], from mailbox: String, to destination: String) async throws {
        try await withConnection { client in
            _ = try await self.open(mailbox, client)
            try await client.move(uids: uids, to: destination)
        }
    }

    func delete(uids: [Int], from mailbox: String) async throws {
        try await withConnection { client in
            _ = try await self.open(mailbox, client)
            try await client.delete(uids: uids)
        }
    }

    /// A message with that Message-ID is in the mailbox.
    func contains(messageID: String, in mailbox: String) async throws -> Bool {
        try await withConnection { client in
            _ = try await self.open(mailbox, client)
            return try await !client.search(messageID: messageID).isEmpty
        }
    }

    func append(_ data: Data, to mailbox: String, flags: [String]) async throws {
        try await withConnection { client in
            try await client.append(data, to: mailbox, flags: flags)
        }
    }

    /// The counts of the mailboxes that can be opened, one STATUS each; a mailbox that refuses
    /// is left out.
    func counts(_ paths: [String]) async throws -> [String: IMAPClient.Count] {
        try await withConnection { client in
            var result: [String: IMAPClient.Count] = [:]
            for path in paths {
                do {
                    if let count = try await client.status(path) { result[path] = count }
                } catch MailError.unexpected {
                    continue
                }
            }
            return result
        }
    }

    func close() async {
        await client?.logout()
        client = nil
        selected = nil
    }

    // MARK: Connection

    private func open(_ mailbox: String, _ client: IMAPClient) async throws -> IMAPClient.Selection {
        let selection = try await client.select(mailbox)
        selected = mailbox
        return selection
    }

    private func withConnection<T>(_ work: (IMAPClient) async throws -> T) async throws -> T {
        do {
            return try await work(try await connection())
        } catch let error as MailError {
            // Signed in but refused, or a server's answer: no point trying again.
            if case .authentication = error { throw error }
            if case .unexpected = error { throw error }
            client = nil
            selected = nil
            return try await work(try await connection())
        }
    }

    private func connection() async throws -> IMAPClient {
        if let client { return client }
        let credential = try await SASL.credential(for: account)
        let client = try await IMAPClient.connect(to: account.imap)
        try await client.authenticate(user: account.username, credential: credential)
        self.client = client
        return client
    }
}

/// A second connection per account, that does nothing but wait in IDLE on the Inbox and say
/// when something changed there. Without IDLE on the server, it asks again every five minutes.
/// After an error (sleep, network gone), it tries again later, waiting longer each time.
actor InboxWatcher {
    let account: MailAccount
    private let onChange: @Sendable () async -> Void
    private var task: Task<Void, Never>?

    init(account: MailAccount, onChange: @escaping @Sendable () async -> Void) {
        self.account = account
        self.onChange = onChange
    }

    func start() {
        guard task == nil else { return }
        task = Task { await self.run() }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func run() async {
        var pause: Duration = .seconds(30)
        while !Task.isCancelled {
            do {
                let credential = try await SASL.credential(for: account)
                let client = try await IMAPClient.connect(to: account.imap)
                try await client.authenticate(user: account.username, credential: credential)
                _ = try await client.select("INBOX")
                pause = .seconds(30)
                while !Task.isCancelled {
                    if client.supportsIdle {
                        if try await client.idle() { await onChange() }
                    } else {
                        try await Task.sleep(for: .seconds(5 * 60))
                        await onChange()
                    }
                }
                await client.logout()
            } catch {
                if Task.isCancelled { return }
                try? await Task.sleep(for: pause)
                pause = min(pause * 2, .seconds(10 * 60))
            }
        }
    }
}
