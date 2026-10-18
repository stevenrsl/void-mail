import Foundation
import SQLite3

/// A message in the list: what the cache keeps of its envelope.
struct MessageSummary: Identifiable, Equatable {
    var id: Int64
    var account: UUID
    var mailbox: String
    var uid: Int
    var date: Date
    var subject: String
    var sender: MailAddress
    var recipients: String
    var flags: Set<String>
    var size: Int

    var isSeen: Bool { flags.contains("\\Seen") }
    var isFlagged: Bool { flags.contains("\\Flagged") }
}

/// The local cache: `mail.sqlite` next to `accounts.json` (in memory for debug launches). The
/// server stays the truth; the cache is what the window shows at once, before the server answers,
/// and what the search reads. Envelopes of the mailboxes opened, bodies of the messages read,
/// and an FTS5 index of subject, sender and text, accents ignored.
actor MailCache {
    static let shared = MailCache()

    private var db: OpaquePointer?

    init(path: String? = nil) {
        let location: String
        if let path {
            location = path
        } else {
            #if DEBUG
            let debug = DebugLaunch.isRequested
            #else
            let debug = false
            #endif
            if debug {
                location = ":memory:"
            } else {
                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Void Mail", isDirectory: true)
                try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
                location = support.appendingPathComponent("mail.sqlite").path
            }
        }
        var handle: OpaquePointer?
        if sqlite3_open(location, &handle) == SQLITE_OK { db = handle }
        for statement in Self.schema { Self.exec(handle, statement) }
    }

    private static let schema = [
        "PRAGMA journal_mode = WAL",
        "PRAGMA foreign_keys = ON",
        """
        CREATE TABLE IF NOT EXISTS mailboxes (account TEXT NOT NULL, mailbox TEXT NOT NULL, uidvalidity INTEGER NOT NULL,
            PRIMARY KEY (account, mailbox))
        """,
        """
        CREATE TABLE IF NOT EXISTS messages (id INTEGER PRIMARY KEY, account TEXT NOT NULL, mailbox TEXT NOT NULL,
            uid INTEGER NOT NULL, date REAL NOT NULL, subject TEXT NOT NULL, sender_name TEXT NOT NULL,
            sender_address TEXT NOT NULL, recipients TEXT NOT NULL, flags TEXT NOT NULL, size INTEGER NOT NULL,
            message_id TEXT, UNIQUE (account, mailbox, uid))
        """,
        "CREATE INDEX IF NOT EXISTS messages_by_date ON messages (account, mailbox, date DESC)",
        "CREATE TABLE IF NOT EXISTS bodies (message INTEGER PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE, raw BLOB NOT NULL)",
        "CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(subject, sender, body, tokenize = 'unicode61 remove_diacritics 2')",
    ]

    // MARK: Mailboxes

    /// The UIDVALIDITY last seen; a different one means the server renumbered the mailbox: what
    /// the cache knew of it is thrown away.
    func checkValidity(account: UUID, mailbox: String, validity: Int) {
        let known = query("SELECT uidvalidity FROM mailboxes WHERE account = ? AND mailbox = ?", [account.uuidString, mailbox]) { Int(sqlite3_column_int64($0, 0)) }.first
        if let known, known == validity { return }
        if known != nil { removeMessages(account: account, mailbox: mailbox, uids: nil) }
        run("INSERT OR REPLACE INTO mailboxes (account, mailbox, uidvalidity) VALUES (?, ?, ?)", [account.uuidString, mailbox, validity])
    }

    func highestUID(account: UUID, mailbox: String) -> Int? {
        query("SELECT MAX(uid) FROM messages WHERE account = ? AND mailbox = ?", [account.uuidString, mailbox]) { statement -> Int? in
            sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 0))
        }.first ?? nil
    }

    func lowestUID(account: UUID, mailbox: String) -> Int? {
        query("SELECT MIN(uid) FROM messages WHERE account = ? AND mailbox = ?", [account.uuidString, mailbox]) { statement -> Int? in
            sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 0))
        }.first ?? nil
    }

    func uids(account: UUID, mailbox: String) -> Set<Int> {
        Set(query("SELECT uid FROM messages WHERE account = ? AND mailbox = ?", [account.uuidString, mailbox]) { Int(sqlite3_column_int64($0, 0)) })
    }

    // MARK: Messages

    func insert(_ envelopes: [MessageEnvelope], account: UUID, mailbox: String) {
        guard !envelopes.isEmpty else { return }
        run("BEGIN", [])
        for envelope in envelopes {
            let sender = envelope.from.first ?? MailAddress(name: "", address: "")
            let recipients = (envelope.to + envelope.cc).map(\.display).joined(separator: ", ")
            run("""
                INSERT INTO messages (account, mailbox, uid, date, subject, sender_name, sender_address, recipients, flags, size, message_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (account, mailbox, uid) DO UPDATE SET flags = excluded.flags
                """, [account.uuidString, mailbox, envelope.uid, envelope.date.timeIntervalSince1970, envelope.subject,
                      sender.name, sender.address, recipients, envelope.flags.sorted().joined(separator: " "), envelope.size, envelope.messageID])
            let id = query("SELECT id FROM messages WHERE account = ? AND mailbox = ? AND uid = ?", [account.uuidString, mailbox, envelope.uid]) { sqlite3_column_int64($0, 0) }.first
            if let id, query("SELECT rowid FROM search WHERE rowid = ?", [id]) { $0 }.isEmpty {
                run("INSERT INTO search (rowid, subject, sender, body) VALUES (?, ?, ?, '')", [id, envelope.subject, "\(sender.name) \(sender.address)"])
            }
        }
        run("COMMIT", [])
    }

    func updateFlags(_ flags: [Int: Set<String>], account: UUID, mailbox: String) {
        guard !flags.isEmpty else { return }
        run("BEGIN", [])
        for (uid, set) in flags {
            run("UPDATE messages SET flags = ? WHERE account = ? AND mailbox = ? AND uid = ?", [set.sorted().joined(separator: " "), account.uuidString, mailbox, uid])
        }
        run("COMMIT", [])
    }

    /// Messages gone from the server (or all of the mailbox's, `uids` nil).
    func removeMessages(account: UUID, mailbox: String, uids: Set<Int>?) {
        let rows = query("SELECT id, uid FROM messages WHERE account = ? AND mailbox = ?", [account.uuidString, mailbox]) { (sqlite3_column_int64($0, 0), Int(sqlite3_column_int64($0, 1))) }
            .filter { uids?.contains($0.1) ?? true }
        guard !rows.isEmpty else { return }
        run("BEGIN", [])
        for (id, _) in rows {
            run("DELETE FROM search WHERE rowid = ?", [id])
            run("DELETE FROM messages WHERE id = ?", [id])
        }
        run("COMMIT", [])
    }

    func removeAccount(_ account: UUID) {
        let ids = query("SELECT id FROM messages WHERE account = ?", [account.uuidString]) { sqlite3_column_int64($0, 0) }
        run("BEGIN", [])
        for id in ids { run("DELETE FROM search WHERE rowid = ?", [id]) }
        run("DELETE FROM messages WHERE account = ?", [account.uuidString])
        run("DELETE FROM mailboxes WHERE account = ?", [account.uuidString])
        run("COMMIT", [])
    }

    func messages(account: UUID, mailbox: String, limit: Int = 500) -> [MessageSummary] {
        // Pinned messages first.
        query("\(Self.summaryColumns) WHERE account = ? AND mailbox = ? ORDER BY instr(flags, '\\Flagged') > 0 DESC, date DESC LIMIT ?", [account.uuidString, mailbox, limit], Self.summary)
    }

    /// Every word typed, as the start of a word, accents ignored; the most recent first.
    func search(account: UUID, text: String, limit: Int = 200) -> [MessageSummary] {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0 == "\"" }).map { "\"\($0)\"*" }
        guard !words.isEmpty else { return [] }
        return query("\(Self.summaryColumns) WHERE account = ? AND id IN (SELECT rowid FROM search WHERE search MATCH ?) ORDER BY date DESC LIMIT ?",
                     [account.uuidString, words.joined(separator: " "), limit], Self.summary)
    }

    func setFlag(_ flag: String, on: Bool, message id: Int64) {
        guard var flags = query("SELECT flags FROM messages WHERE id = ?", [id], { Self.text($0, 0) }).first.map({ Set($0.split(separator: " ").map(String.init)) }) else { return }
        if on { flags.insert(flag) } else { flags.remove(flag) }
        run("UPDATE messages SET flags = ? WHERE id = ?", [flags.sorted().joined(separator: " "), id])
    }

    /// Who wrote to the account, for the address fields: those whose name or address starts
    /// with what is typed (or a word of the name does), the most frequent first.
    func contacts(account: UUID, matching text: String, limit: Int = 6) -> [MailAddress] {
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return [] }
        let sql = """
            SELECT sender_name, sender_address, COUNT(*) AS seen FROM messages
            WHERE account = ? AND sender_address <> '' AND (sender_address LIKE ? OR sender_name LIKE ? OR sender_name LIKE ?)
            GROUP BY lower(sender_address) ORDER BY seen DESC LIMIT ?
            """
        return query(sql, [account.uuidString, typed + "%", typed + "%", "% " + typed + "%", limit]) {
            MailAddress(name: Self.text($0, 0), address: Self.text($0, 1))
        }
    }

    // MARK: Bodies

    func body(message id: Int64) -> Data? {
        query("SELECT raw FROM bodies WHERE message = ?", [id]) { statement -> Data in
            let count = Int(sqlite3_column_bytes(statement, 0))
            guard count > 0, let bytes = sqlite3_column_blob(statement, 0) else { return Data() }
            return Data(bytes: bytes, count: count)
        }.first
    }

    /// The raw message, kept; its text goes into the search index.
    func storeBody(_ raw: Data, text: String, message id: Int64) {
        run("INSERT OR REPLACE INTO bodies (message, raw) VALUES (?, ?)", [id, raw])
        let row = query("SELECT subject, sender FROM search WHERE rowid = ?", [id]) { (Self.text($0, 0), Self.text($0, 1)) }.first
        run("DELETE FROM search WHERE rowid = ?", [id])
        run("INSERT INTO search (rowid, subject, sender, body) VALUES (?, ?, ?, ?)", [id, row?.0 ?? "", row?.1 ?? "", String(text.prefix(200_000))])
    }

    // MARK: SQLite

    private static let summaryColumns = "SELECT id, account, mailbox, uid, date, subject, sender_name, sender_address, recipients, flags, size FROM messages"

    private static func summary(_ statement: OpaquePointer) -> MessageSummary {
        MessageSummary(id: sqlite3_column_int64(statement, 0),
                       account: UUID(uuidString: text(statement, 1)) ?? UUID(),
                       mailbox: text(statement, 2),
                       uid: Int(sqlite3_column_int64(statement, 3)),
                       date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                       subject: text(statement, 5),
                       sender: MailAddress(name: text(statement, 6), address: text(statement, 7)),
                       recipients: text(statement, 8),
                       flags: Set(text(statement, 9).split(separator: " ").map(String.init)),
                       size: Int(sqlite3_column_int64(statement, 10)))
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func exec(_ db: OpaquePointer?, _ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func prepare(_ sql: String, _ arguments: [Any?]) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        for (offset, argument) in arguments.enumerated() {
            let index = Int32(offset + 1)
            switch argument {
            case let value as Int: sqlite3_bind_int64(statement, index, Int64(value))
            case let value as Int64: sqlite3_bind_int64(statement, index, value)
            case let value as Double: sqlite3_bind_double(statement, index, value)
            case let value as String: sqlite3_bind_text(statement, index, value, -1, Self.transient)
            case let value as Data: _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), Self.transient) }
            default: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    private func run(_ sql: String, _ arguments: [Any?]) {
        guard let statement = prepare(sql, arguments) else { return }
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    private func query<T>(_ sql: String, _ arguments: [Any?], _ row: (OpaquePointer) -> T) -> [T] {
        guard let statement = prepare(sql, arguments) else { return [] }
        defer { sqlite3_finalize(statement) }
        var results: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW { results.append(row(statement)) }
        return results
    }
}
