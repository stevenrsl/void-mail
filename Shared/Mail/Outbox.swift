import Foundation
import Observation

/// The messages being written, and the one about to go. « Envoyer » closes the window at once;
/// the message leaves 10 seconds later, the time to take it back (« Annuler » reopens it). A window
/// closed without sending keeps what was written in Brouillons.
@MainActor @Observable
final class Outbox {
    static let shared = Outbox()

    private(set) var drafts: [UUID: Draft] = [:]
    /// The message about to leave, and when.
    private(set) var sending: Draft?
    /// What went wrong with the last send, said plainly.
    var sendError: String?
    /// A draft to show again in its window (an undone send, a failed one): the main window opens it.
    var reopen: UUID?
    /// Drafts whose window was closed by « Envoyer » or « Supprimer » rather than by its close button.
    @ObservationIgnored private var settled: Set<UUID> = []
    @ObservationIgnored private var sendTask: Task<Void, Never>?

    static let sendDelay: Duration = .seconds(10)

    private let store = AccountStore.shared
    private let cache = MailCache.shared

    // MARK: Drafts

    func newDraft(account: MailAccount?, to: String = "", subject: String = "", body: String = "") -> UUID? {
        guard let account = account ?? store.accounts.first else { return nil }
        return add(Draft(account: account.id, to: to, subject: subject, content: NoteContent(text: body, runs: [])))
    }

    func add(_ draft: Draft) -> UUID {
        drafts[draft.id] = draft
        try? FileManager.default.createDirectory(at: draft.attachmentsDirectory, withIntermediateDirectories: true)
        return draft.id
    }

    func update(_ id: UUID, _ change: (inout Draft) -> Void) {
        guard var draft = drafts[id] else { return }
        change(&draft)
        drafts[id] = draft
    }

    /// `mailto:a@b.fr?subject=…&body=…&cc=…`: a new message with them.
    func draft(fromMailto url: URL, account: MailAccount?) -> UUID? {
        guard url.scheme?.lowercased() == "mailto" else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let to = (components?.path ?? "").removingPercentEncoding ?? ""
        func value(_ name: String) -> String { components?.queryItems?.first { $0.name.lowercased() == name }?.value ?? "" }
        guard let id = newDraft(account: account, to: [to, value("to")].filter { !$0.isEmpty }.joined(separator: ", "),
                                subject: value("subject"), body: value("body")) else { return nil }
        update(id) { $0.cc = value("cc"); $0.bcc = value("bcc") }
        return id
    }

    /// The window of a draft closes. Sent or thrown away: nothing more. Otherwise, what was written
    /// goes to Brouillons (an untouched draft is simply forgotten).
    func windowClosed(_ id: UUID) {
        if settled.remove(id) != nil { return }
        guard let draft = drafts[id] else { return }
        drafts[id] = nil
        guard !draft.isEmpty, let account = store.account(draft.account) else { cleanUp(draft); return }
        Task {
            do {
                try await saveToDrafts(draft, account: account)
            } catch {
                sendError = "Le brouillon n'a pas pu être enregistré : \(Self.describe(error))"
                drafts[id] = draft
                reopen = id
                return
            }
            cleanUp(draft)
        }
    }

    func discard(_ id: UUID) {
        guard let draft = drafts.removeValue(forKey: id) else { return }
        settled.insert(id)
        cleanUp(draft)
    }

    // MARK: Sending

    /// What stops a draft from leaving, said plainly; nil: it can go.
    func problem(with draft: Draft) -> String? {
        if draft.recipients.isEmpty { return "Ajoutez au moins un destinataire." }
        if let wrong = draft.invalidAddresses.first { return "« \(wrong) » n'est pas une adresse." }
        return nil
    }

    /// « Envoyer »: the window goes, the message waits `sendDelay`, then leaves.
    func send(_ id: UUID) {
        guard let draft = drafts[id], problem(with: draft) == nil else { return }
        flushSending()
        settled.insert(id)
        drafts[id] = nil
        sending = draft
        sendTask = Task {
            try? await Task.sleep(for: Self.sendDelay)
            guard !Task.isCancelled else { return }
            await deliver(draft)
        }
    }

    /// « Annuler » in the band: the message comes back in its window.
    func undoSend() {
        guard let draft = sending else { return }
        sendTask?.cancel()
        sending = nil
        drafts[draft.id] = draft
        reopen = draft.id
    }

    /// The message waiting goes now (another one is sent, the app quits).
    func flushSending() {
        guard let draft = sending else { return }
        sendTask?.cancel()
        Task { await deliver(draft) }
    }

    func flushSendingNow() async {
        guard let draft = sending else { return }
        sendTask?.cancel()
        await deliver(draft)
    }

    private func deliver(_ draft: Draft) async {
        if sending?.id == draft.id { sending = nil }
        guard let account = store.account(draft.account) else { return }
        do {
            let built = MessageComposer.build(draft, from: account, files: MessageComposer.files(of: draft))
            #if DEBUG
            if DebugLaunch.isRequested { cleanUp(draft); return }
            #endif
            let credential = try await SASL.credential(for: account)
            let smtp = try await SMTPClient.connect(to: account.smtp)
            try await smtp.authenticate(user: account.username, credential: credential)
            try await smtp.send(from: built.envelopeFrom, to: built.recipients, data: built.data)
            await smtp.quit()
            // The copy in Envoyés, where the server doesn't keep one itself. Sent already: a
            // failure here is said, not undone.
            if !ProviderDirectory.keepsSentCopy(account), let sent = account.mailboxes.first(where: { $0.role == .sent }) {
                do {
                    try await AccountSession(account: account).append(built.data, to: sent.path, flags: ["\\Seen"])
                } catch {
                    sendError = "Message envoyé, mais sa copie n'a pas pu être rangée dans Envoyés : \(Self.describe(error))"
                }
            }
            cleanUp(draft)
        } catch {
            // Nothing left: the message comes back in its window, to try again.
            sendError = "Le message n'est pas parti : \(Self.describe(error))"
            drafts[draft.id] = draft
            reopen = draft.id
        }
    }

    private func saveToDrafts(_ draft: Draft, account: MailAccount) async throws {
        #if DEBUG
        if DebugLaunch.isRequested { return }
        #endif
        guard let mailbox = account.mailboxes.first(where: { $0.role == .drafts }) else { return }
        let built = MessageComposer.build(draft, from: account, files: MessageComposer.files(of: draft))
        try await AccountSession(account: account).append(built.data, to: mailbox.path, flags: ["\\Draft", "\\Seen"])
    }

    private func cleanUp(_ draft: Draft) {
        try? FileManager.default.removeItem(at: draft.attachmentsDirectory)
    }

    // MARK: Addresses

    func suggestions(account: UUID, for field: String) async -> [MailAddress] {
        // What is typed after the last comma.
        let typed = field.split(separator: ",", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        return await cache.contacts(account: account, matching: typed)
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
